// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SeedKit

/// Thin build-time driver: ingest a directory of tldr-pages `.md` files into the
/// seed blobs. All real logic lives in ``SeedKit``; this is directory walking and
/// file I/O. See `2026-06-21-predictor-seed-ingestion-design`.
///
/// Usage: `glymr-seedbuild <pages-dir> <out-dir>`
/// Writes `seed_unigram_v1.sketch` and `seed_bigram_v1.sketch` into `out-dir`.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 3 else {
    fail("usage: glymr-seedbuild <pages-dir> <out-dir>")
}
let pagesDir = URL(fileURLWithPath: args[1], isDirectory: true)
let outDir = URL(fileURLWithPath: args[2], isDirectory: true)

let fm = FileManager.default
guard let walker = fm.enumerator(at: pagesDir, includingPropertiesForKeys: nil) else {
    fail("cannot read pages directory: \(pagesDir.path)")
}

var builder = SeedBuilder()
var pageCount = 0
for case let url as URL in walker where url.pathExtension == "md" {
    do {
        let markdown = try String(contentsOf: url, encoding: .utf8)
        for sequence in TldrParser.invocations(fromPage: markdown) {
            builder.ingest(sequence)
        }
        pageCount += 1
    } catch {
        // Don't kill the whole build for one bad page, but never drop it silently
        // — a corrupt corpus must leave a trail, not look like a clean run.
        FileHandle.standardError.write(Data("warning: skipped \(url.path): \(error)\n".utf8))
    }
}

// Empty seed from an empty corpus is almost always a wrong pages-dir, not intent;
// fail loudly rather than write a useless valid-but-empty blob and exit 0.
guard pageCount > 0 else {
    fail("no .md pages found under \(pagesDir.path) — wrong directory?")
}

let blobs = builder.blobs()
do {
    try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
    try Data(blobs.unigram).write(to: outDir.appendingPathComponent("seed_unigram_v1.sketch"))
    try Data(blobs.bigram).write(to: outDir.appendingPathComponent("seed_bigram_v1.sketch"))
} catch {
    fail("write failed: \(error)")
}

print("seed built from \(pageCount) pages → \(outDir.path)")
print("  unigram blob: \(blobs.unigram.count) bytes")
print("  bigram blob:  \(blobs.bigram.count) bytes")
