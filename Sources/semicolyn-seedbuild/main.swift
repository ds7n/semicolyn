// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SeedKit
import SemicolynKit

/// Thin build-time driver: ingest one or more CLI corpora into the predictor seed
/// blobs. All real logic lives in ``SeedKit``; this is argument parsing, directory
/// walking, and file I/O. See `2026-06-21-predictor-seed-ingestion-design` and
/// `2026-06-21-predictor-fig-ingestion-design`.
///
/// Usage: `semicolyn-seedbuild --out <dir> [--tldr <dir>] [--fig <dir>] [--combined <file>]`
/// At least one source is required. Writes `seed_unigram_v1.sketch` and
/// `seed_bigram_v1.sketch` into the out directory. `--combined <file>` additionally
/// writes the single seed_pinned-format blob the app installs directly.
///
/// `--dev <dir>`, `--tech <dir>`, `--prompt <dir>` ingest running-text prose corpora
/// (one directory of `.txt` files per layer) through `LayeredSeedBuilder`, blending
/// the layers with default weights (dev 1.5, tech 1.5, prompt 2.0). `--prose-combined
/// <file>` writes that blended layer set as its own combined seed_pinned-format blob,
/// independent of the tldr/fig combined output above. See
/// `2026-08-11-context-aware-prediction-plan-B-corpus`.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

let usage = "usage: semicolyn-seedbuild --out <dir> [--tldr <dir>] [--fig <dir>] [--combined <file>]"
    + " [--dev <dir>] [--tech <dir>] [--prompt <dir>] [--prose-combined <file>] [--blocklist <file>]"
let knownFlags: Set<String> = [
    "--out", "--tldr", "--fig", "--combined", "--dev", "--tech", "--prompt", "--prose-combined",
    "--blocklist",
]

/// Parse `--flag value` options into a dictionary. An unknown flag, a valueless
/// flag, or a non-flag argument is a usage error, never a silent skip.
func parseOptions(_ args: [String]) -> [String: String] {
    var options: [String: String] = [:]
    var i = 0
    while i < args.count {
        let arg = args[i]
        guard knownFlags.contains(arg), i + 1 < args.count else {
            fail(usage)
        }
        options[arg] = args[i + 1]
        i += 2
    }
    return options
}

/// Ingest every file with `ext` under `dir`, parsing each with `parse` (given the
/// file text and its URL, Fig needs the stem for the command) and folding the
/// result into `builder`. Returns the count of files successfully read. Warns
/// (never silently drops) on an unreadable file. `recursive: false` walks only the
/// directory's immediate children, Fig's nested `src/<tool>/*.ts` are
/// subcommand *fragments* whose stems (`s3`, `3.0.0`) are not real commands, so
/// only top-level `src/*.ts` specs are ingested.
func ingestDirectory(_ dir: URL, ext: String, recursive: Bool, into builder: inout SeedBuilder,
                     parse: (String, URL) -> [[String]]) -> Int {
    let fm = FileManager.default
    let options: FileManager.DirectoryEnumerationOptions = recursive ? [] : [.skipsSubdirectoryDescendants]
    guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: options) else {
        fail("cannot read directory: \(dir.path)")
    }
    var count = 0
    for case let url as URL in walker where url.pathExtension == ext {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            for sequence in parse(text, url) { builder.ingest(sequence) }
            count += 1
        } catch {
            warn("warning: skipped \(url.path): \(error)")
        }
    }
    return count
}

let options = parseOptions(Array(CommandLine.arguments.dropFirst()))
guard let outPath = options["--out"] else {
    fail("usage: semicolyn-seedbuild --out <dir> [--tldr <dir>] [--fig <dir>]")
}
let hasProseSource = options["--dev"] != nil || options["--tech"] != nil || options["--prompt"] != nil
guard options["--tldr"] != nil || options["--fig"] != nil || hasProseSource else {
    fail(
        "at least one source required: --tldr <dir>, --fig <dir>, "
            + "and/or --dev/--tech/--prompt <dir>")
}

var builder = SeedBuilder()
var totalFiles = 0

if let tldrPath = options["--tldr"] {
    let dir = URL(fileURLWithPath: tldrPath, isDirectory: true)
    let n = ingestDirectory(dir, ext: "md", recursive: true, into: &builder) { text, _ in
        TldrParser.invocations(fromPage: text)
    }
    print("tldr: ingested \(n) pages")
    totalFiles += n
}

if let figPath = options["--fig"] {
    let dir = URL(fileURLWithPath: figPath, isDirectory: true)
    let n = ingestDirectory(dir, ext: "ts", recursive: false, into: &builder) { source, url in
        // The command is the spec file's stem (git.ts → "git"); reliable only for
        // the top-level src/*.ts specs, hence the non-recursive walk above.
        let command = url.deletingPathExtension().lastPathComponent
        return FigSpecParser.invocations(fromSpec: source, command: command)
    }
    print("fig: ingested \(n) specs")
    totalFiles += n
}

// Empty corpus is almost always a wrong directory, not intent; fail loudly rather
// than write a useless valid-but-empty blob and exit 0. A prose-only invocation
// (no --tldr/--fig) legitimately has zero tldr/fig files, so it skips this check;
// its own ingestion below still fails loudly on an empty prose corpus.
guard totalFiles > 0 || hasProseSource else {
    fail("no source files found, wrong directory?")
}

let blobs = builder.blobs()
let outDir = URL(fileURLWithPath: outPath, isDirectory: true)
do {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    try Data(blobs.unigram).write(to: outDir.appendingPathComponent("seed_unigram_v1.sketch"))
    try Data(blobs.bigram).write(to: outDir.appendingPathComponent("seed_bigram_v1.sketch"))
} catch {
    fail("write failed: \(error)")
}

print("seed built from \(totalFiles) files → \(outDir.path)")
print("  unigram blob: \(blobs.unigram.count) bytes")
print("  bigram blob:  \(blobs.bigram.count) bytes")

if let combinedPath = options["--combined"] {
    let combined = combinedSeedBlob(version: 1, unigram: blobs.unigram, bigram: blobs.bigram)
    let url = URL(fileURLWithPath: combinedPath)
    do {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(combined).write(to: url)
    } catch { fail("combined write failed: \(error)") }
    print("  combined seed: \(combined.count) bytes → \(url.path)")
}

/// Read every `.txt` file directly under `dir` (non-recursive, running text has
/// no meaningful subcommand-fragment nesting like Fig) and tokenize each into
/// per-sentence token sequences via `ProseCorpusParser`.
func readTextFiles(_ dir: URL) -> [[String]] {
    var out: [[String]] = []
    let files = (try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants])) ?? []
    for f in files where f.pathExtension == "txt" {
        guard let text = try? String(contentsOf: f, encoding: .utf8) else {
            warn("warning: skipped \(f.path)")
            continue
        }
        out.append(contentsOf: ProseCorpusParser.sentences(fromText: text))
    }
    return out
}

if hasProseSource {
    var proseFilter: TokenFilter?
    if let blocklistPath = options["--blocklist"] {
        let text = (try? String(contentsOf: URL(fileURLWithPath: blocklistPath), encoding: .utf8)) ?? ""
        let words = Set(text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
        if !words.isEmpty {
            proseFilter = TokenFilter(patterns: TokenFilter.defaultPatterns + [.blocklist(words)])
        }
        print("blocklist: loaded \(words.count) words")
    }
    var proseBuilder = LayeredSeedBuilder(filter: proseFilter)
    var totalProseSentences = 0
    let layerDefs: [(flag: String, key: String, config: LayerConfig)] = [
        ("--dev", "dev", LayerConfig(weight: 1.5, bigramCapPerLayer: 500, bigramFloor: 2)),
        ("--tech", "tech", LayerConfig(weight: 1.5, bigramCapPerLayer: 500, bigramFloor: 2)),
        ("--prompt", "prompt", LayerConfig(weight: 2.0, bigramCapPerLayer: 500, bigramFloor: 2)),
    ]
    for (flag, key, config) in layerDefs {
        guard let path = options[flag] else { continue }
        let sentences = readTextFiles(URL(fileURLWithPath: path, isDirectory: true))
        proseBuilder.addLayer(key, config: config, sentences: sentences)
        print("\(key): ingested \(sentences.count) sentences")
        totalProseSentences += sentences.count
    }

    // Same rationale as the tldr/fig guard above: an empty or misspelled
    // --dev/--tech/--prompt directory must not silently produce a valid-but-empty
    // blob. Check runs before any prose output is written.
    guard totalProseSentences > 0 else {
        fail(
            "no prose sentences found in --dev/--tech/--prompt directories "
                + "(check the paths contain .txt files)")
    }

    if let proseCombinedPath = options["--prose-combined"] {
        let proseBlobs = proseBuilder.blobs()
        let combined = combinedSeedBlob(
            version: 1, unigram: proseBlobs.unigram, bigram: proseBlobs.bigram)
        let url = URL(fileURLWithPath: proseCombinedPath)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(combined).write(to: url)
        } catch { fail("prose combined write failed: \(error)") }
        print("  prose combined seed: \(combined.count) bytes → \(url.path)")
    }
}
