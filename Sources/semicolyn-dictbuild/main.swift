// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SeedKit

/// Dictionary build driver. All logic lives in ``SeedKit``; this is argument parsing and I/O.
///
///     semicolyn-dictbuild ngram-filter -y 1990 -c N [-v vocab.txt] < ngrams > out.tsv

let usage = """
usage:
  semicolyn-dictbuild ngram-filter -y|--min-year <year> -c|--min-count <n> [-v|--vocab <file>]
      stdin: Google Books n-gram v3 lines; stdout: ngram<TAB>count (count >= n, years >= year).
      --vocab: one folded word per line; keep a line only if every token, lowercased, is listed.
  -h, --help   show this help
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func runNgramFilter(_ args: [String]) {
    let aliases = ["-y": "min-year", "--min-year": "min-year", "-c": "min-count",
                   "--min-count": "min-count", "-v": "vocab", "--vocab": "vocab"]
    if args.contains("-h") || args.contains("--help") {
        print(usage)
        exit(0)
    }
    var values: [String: String] = [:]
    var i = 0
    while i < args.count {
        guard let name = aliases[args[i]], i + 1 < args.count else {
            fail("unknown or incomplete option: \(args[i])\n\(usage)")
        }
        values[name] = args[i + 1]
        i += 2
    }
    guard let yearText = values["min-year"], let minYear = Int(yearText) else {
        fail("missing or invalid --min-year\n\(usage)")
    }
    guard minYear >= 0 else { fail("--min-year must be non-negative, got \(minYear)") }
    guard let countText = values["min-count"], let minCount = UInt64(countText) else {
        fail("missing or invalid --min-count\n\(usage)")
    }
    var vocab: Set<String>?
    if let path = values["vocab"] {
        guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read file: \(path)") }
        let text = String(decoding: data, as: UTF8.self)
        vocab = Set(text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init))
        if vocab?.isEmpty ?? true {
            FileHandle.standardError.write(Data("warning: vocab file loaded zero words: \(path)\n".utf8))
        }
    }

    var filter = NgramStreamFilter(minYear: minYear, minCount: minCount, vocab: vocab)
    let chunkSize = 1 << 20
    var buffer = [UInt8](repeating: 0, count: chunkSize)
    var out: [UInt8] = []
    out.reserveCapacity(chunkSize)

    func flush() {
        guard !out.isEmpty else { return }
        out.withUnsafeBufferPointer { ptr in
            var offset = 0
            while offset < ptr.count {
                let written = write(1, ptr.baseAddress! + offset, ptr.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    fail("write failed: errno \(errno)")
                }
                offset += written
            }
        }
        out.removeAll(keepingCapacity: true)
    }

    while true {
        let n = buffer.withUnsafeMutableBytes { read(0, $0.baseAddress, chunkSize) }
        if n < 0 {
            if errno == EINTR { continue }
            fail("read failed: errno \(errno)")
        }
        if n == 0 { break }
        filter.feed(Array(buffer[0..<n]), into: &out)
        if out.count >= chunkSize { flush() }
    }
    filter.finish(into: &out)
    flush()
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail(usage) }
switch command {
case "-h", "--help", "help":
    print(usage)
case "ngram-filter":
    runNgramFilter(Array(args.dropFirst()))
default:
    fail("unknown command: \(command)\n\(usage)")
}
