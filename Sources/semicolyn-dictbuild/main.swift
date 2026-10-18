// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SeedKit
import SemicolynKit

/// Dictionary build driver. All logic lives in ``SeedKit``; this is argument parsing and I/O.
///
///     semicolyn-dictbuild ngram-filter -y 1990 -c N [-v vocab.txt] < ngrams > out.tsv
///     semicolyn-dictbuild english -u unigrams/ -b bigrams/ -w wordfreq.tsv -s scowl.txt -t titles.txt -l block.txt -o out.gdic

let usage = """
usage:
  semicolyn-dictbuild ngram-filter -y|--min-year <year> -c|--min-count <n> [-v|--vocab <file>]
      stdin: Google Books n-gram v3 lines; stdout: ngram<TAB>count (count >= n, years >= year).
      --vocab: one folded word per line; keep a line only if every token, lowercased, is listed.
  semicolyn-dictbuild english -u|--unigrams <dir> -b|--bigrams <dir> -w|--wordfreq <tsv> -s|--scowl <file>
      -t|--titles <file> -l|--blocklist <file> -o|--out <file>
      [--max-words <n>] [--successor-words <n>] [--successors-per-word <n>]
      Reads ngram-filter output (*.tsv in each dir), wordfreq (word<TAB>freq), SCOWL / blocklist
      (one word per line), titles (one cased title per line); writes a WordDictionary blob.
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

func readLines(_ path: String) -> [Substring] {
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read file: \(path)") }
    return String(decoding: data, as: UTF8.self).split(whereSeparator: { $0 == "\n" || $0 == "\r" })
}

/// `*.tsv` files in `dir`, sorted by name.
func tsvFiles(in dir: String) -> [String] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
        fail("cannot read directory: \(dir)")
    }
    let files = names.filter { $0.hasSuffix(".tsv") }.sorted().map { dir + "/" + $0 }
    if files.isEmpty { FileHandle.standardError.write(Data("warning: no *.tsv files in \(dir)\n".utf8)) }
    return files
}

/// Splits `text<TAB>number` into its parts, or nil for a malformed line.
func splitTSV(_ line: Substring) -> (Substring, Substring)? {
    let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
    return parts.count == 2 ? (parts[0], parts[1]) : nil
}

func runEnglish(_ args: [String]) {
    let aliases = ["-u": "unigrams", "--unigrams": "unigrams", "-b": "bigrams", "--bigrams": "bigrams",
                   "-w": "wordfreq", "--wordfreq": "wordfreq", "-s": "scowl", "--scowl": "scowl",
                   "-t": "titles", "--titles": "titles", "-l": "blocklist", "--blocklist": "blocklist",
                   "-o": "out", "--out": "out", "--max-words": "max-words",
                   "--successor-words": "successor-words", "--successors-per-word": "successors-per-word"]
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
    func required(_ name: String) -> String {
        guard let value = values[name] else { fail("missing --\(name)\n\(usage)") }
        return value
    }
    var config = EnglishBuildConfig()
    for (name, apply) in [("max-words", { config.maxWords = $0 }),
                          ("successor-words", { config.successorWords = $0 }),
                          ("successors-per-word", { config.successorsPerWord = $0 })] as [(String, (Int) -> Void)] {
        guard let text = values[name] else { continue }
        guard let n = Int(text), n >= 0 else { fail("invalid --\(name): \(text)") }
        apply(n)
    }

    var books: [String: UInt64] = [:]
    for file in tsvFiles(in: required("unigrams")) {
        for line in readLines(file) {
            guard let (word, count) = splitTSV(line), let n = UInt64(count) else { continue }
            books[String(word), default: 0] &+= n
        }
    }
    var wordfreq: [String: Double] = [:]
    for line in readLines(required("wordfreq")) {
        guard let (word, freq) = splitTSV(line), let f = Double(freq), f > 0 else { continue }
        wordfreq[String(word).lowercased()] = f
    }
    let sources = EnglishSources(
        books: books, wordfreq: wordfreq,
        realWords: Set(readLines(required("scowl")).map { String($0).lowercased() }),
        titleWords: Set(readLines(required("titles")).filter { !$0.contains(" ") }.map(String.init)),
        blocklist: Set(readLines(required("blocklist")).map { String($0).lowercased() }))
    let entries = buildEnglishEntries(sources, config: config)

    let index = SuccessorIndex(entries: entries, config: config)
    var packed: [UInt64: UInt64] = [:]
    for file in tsvFiles(in: required("bigrams")) {
        for line in readLines(file) {
            guard let (gram, count) = splitTSV(line), let n = UInt64(count) else { continue }
            let tokens = gram.split(separator: " ", omittingEmptySubsequences: true)
            guard tokens.count == 2, let key = index.pack(prev: String(tokens[0]), next: String(tokens[1])) else { continue }
            packed[key, default: 0] &+= n
        }
    }
    let successors = index.successors(from: packed, config: config)

    let blob: [UInt8]
    do {
        blob = try WordDictionary(entries: entries, successors: successors).serialize()
    } catch {
        fail("cannot build dictionary: \(error)")
    }
    let outPath = required("out")
    guard FileManager.default.createFile(atPath: outPath, contents: Data(blob)) else {
        fail("cannot write file: \(outPath)")
    }
    print("words: \(entries.count)\npairs: \(packed.count)\nsuccessor keys: \(successors.count)\nbytes: \(blob.count)")
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail(usage) }
switch command {
case "-h", "--help", "help":
    print(usage)
case "ngram-filter":
    runNgramFilter(Array(args.dropFirst()))
case "english":
    runEnglish(Array(args.dropFirst()))
default:
    fail("unknown command: \(command)\n\(usage)")
}
