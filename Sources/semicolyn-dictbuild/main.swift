// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SeedKit
import SemicolynKit

/// Dictionary build driver. All logic lives in ``SeedKit``; this is argument parsing and I/O.
///
///     semicolyn-dictbuild ngram-filter -y 1990 -c N [-v vocab.txt] < ngrams > out.tsv
///     semicolyn-dictbuild english -u unigrams/ -b bigrams/ -w wordfreq.tsv -s scowl.txt -t titles.txt -l block.txt -o out.gdic
///     semicolyn-dictbuild commands -t tldr/pages -f autocomplete/src -o out.gcmt
///     semicolyn-dictbuild inspect out.gdic

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
  semicolyn-dictbuild english --vocab-out <file> -u ... -w ... -s ... -t ... -l ...
      Vocabulary pass: writes the sorted folded forms of the admitted words (one per line, the
      input for ngram-filter --vocab) instead of a blob; --bigrams and --out are not needed.
  semicolyn-dictbuild commands -t|--tldr <pages dir> -f|--fig <src dir> -o|--out <file>
      Reads tldr pages (common, linux, osx; held-out pages skipped) and top-level Fig specs
      (<src dir>/*.ts); writes a CommandTree blob. Exits nonzero if no pages or no specs parse.
  semicolyn-dictbuild inspect <file>
      Detects GDIC / GCMT by magic and prints counts plus fixed completion/candidate probes.
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

/// Streams `path` line by line, exiting with a message if it cannot be read.
func streamLines(_ path: String, _ body: (Substring) -> Void) {
    do {
        try forEachLine(inFile: path, body)
    } catch {
        fail("cannot read file: \(path)")
    }
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

/// Per-input line accounting, printed to stderr; `dropped` counts well-formed lines that
/// contributed nothing (e.g. a bigram whose words have no kept form).
struct InputStats {
    let kind: String
    var parsed = 0
    var skipped = 0
    var dropped = 0

    func report() {
        FileHandle.standardError.write(Data("\(kind): parsed \(parsed), skipped \(skipped), dropped \(dropped)\n".utf8))
    }

    func requireParsed() {
        if parsed == 0 { fail("no \(kind) lines parsed (\(skipped) malformed); check the input path and format") }
    }
}

func runEnglish(_ args: [String]) {
    let aliases = ["-u": "unigrams", "--unigrams": "unigrams", "-b": "bigrams", "--bigrams": "bigrams",
                   "-w": "wordfreq", "--wordfreq": "wordfreq", "-s": "scowl", "--scowl": "scowl",
                   "-t": "titles", "--titles": "titles", "-l": "blocklist", "--blocklist": "blocklist",
                   "-o": "out", "--out": "out", "--max-words": "max-words",
                   "--successor-words": "successor-words", "--successors-per-word": "successors-per-word",
                   "--vocab-out": "vocab-out"]
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

    var unigramStats = InputStats(kind: "unigrams")
    var books: [String: UInt64] = [:]
    for file in tsvFiles(in: required("unigrams")) {
        streamLines(file) { line in
            guard let (word, count) = splitTSV(line), let n = UInt64(count) else { unigramStats.skipped += 1; return }
            unigramStats.parsed += 1
            books[String(word), default: 0] &+= n
        }
    }
    unigramStats.report()
    unigramStats.requireParsed()

    var wordfreqStats = InputStats(kind: "wordfreq")
    var wordfreq: [String: Double] = [:]
    streamLines(required("wordfreq")) { line in
        guard let (word, freq) = splitTSV(line), let f = Double(freq), f > 0, f.isFinite else { wordfreqStats.skipped += 1; return }
        wordfreqStats.parsed += 1
        wordfreq[String(word).lowercased(), default: 0] += f
    }
    wordfreqStats.report()
    wordfreqStats.requireParsed()

    var realWords = Set<String>()
    streamLines(required("scowl")) { realWords.insert(String($0).lowercased()) }
    var blocklist = Set<String>()
    streamLines(required("blocklist")) { blocklist.insert(String($0).lowercased()) }
    var titleWords = Set<String>()
    streamLines(required("titles")) { line in
        let title = line.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        if !title.isEmpty, !title.contains(" ") { titleWords.insert(title) }
    }
    FileHandle.standardError.write(Data("side files: scowl \(realWords.count), titles \(titleWords.count), blocklist \(blocklist.count)\n".utf8))

    let sources = EnglishSources(books: books, wordfreq: wordfreq, realWords: realWords,
                                 titleWords: titleWords, blocklist: blocklist)
    let entries = buildEnglishEntries(sources, config: config)

    if let vocabPath = values["vocab-out"] {
        let folds = Set(entries.map { $0.text.lowercased() }).sorted()
        let text = folds.joined(separator: "\n") + (folds.isEmpty ? "" : "\n")
        guard FileManager.default.createFile(atPath: vocabPath, contents: Data(text.utf8)) else {
            fail("cannot write file: \(vocabPath)")
        }
        print("words: \(entries.count)\nvocab: \(folds.count)")
        return
    }

    let index = SuccessorIndex(entries: entries, config: config)
    var bigramStats = InputStats(kind: "bigrams")
    var packed: [UInt64: UInt64] = [:]
    for file in tsvFiles(in: required("bigrams")) {
        streamLines(file) { line in
            guard let (gram, count) = splitTSV(line), let n = UInt64(count) else { bigramStats.skipped += 1; return }
            let tokens = gram.split(separator: " ", omittingEmptySubsequences: true)
            guard tokens.count == 2 else { bigramStats.skipped += 1; return }
            bigramStats.parsed += 1
            guard let key = index.pack(prev: String(tokens[0]), next: String(tokens[1])) else { bigramStats.dropped += 1; return }
            packed[key, default: 0] &+= n
        }
    }
    bigramStats.report()
    bigramStats.requireParsed()
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

func runCommands(_ args: [String]) {
    let aliases = ["-t": "tldr", "--tldr": "tldr", "-f": "fig", "--fig": "fig", "-o": "out", "--out": "out"]
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
    let fm = FileManager.default

    var observed = CommandUsage()
    var pageNames: Set<String> = []
    var pagesRead = 0
    var heldOut = 0
    for platform in ["common", "linux", "osx"] {
        let dir = required("tldr") + "/" + platform
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else {
            FileHandle.standardError.write(Data("warning: cannot read directory: \(dir)\n".utf8))
            continue
        }
        for name in names.sorted() where name.hasSuffix(".md") {
            if TldrHoldout.isHeldOut(pageStem: String(name.dropLast(3))) { heldOut += 1; continue }
            guard let data = fm.contents(atPath: dir + "/" + name) else { fail("cannot read file: \(dir)/\(name)") }
            pagesRead += 1
            pageNames.insert(String(name.dropLast(3)))
            for span in TldrParser.exampleCommands(fromPage: String(decoding: data, as: UTF8.self)) {
                observed.ingest(example: span)
            }
        }
    }
    guard pagesRead > 0 else { fail("no tldr pages read under \(required("tldr")); check the path") }

    let figDir = required("fig")
    guard let figNames = try? fm.contentsOfDirectory(atPath: figDir) else { fail("cannot read directory: \(figDir)") }
    var specs: [FigCommandSpec] = []
    for name in figNames.sorted() where name.hasSuffix(".ts") && !name.hasSuffix(".d.ts") {
        guard let data = fm.contents(atPath: figDir + "/" + name) else { fail("cannot read file: \(figDir)/\(name)") }
        let spec = FigSpecParser.spec(fromSource: String(decoding: data, as: UTF8.self),
                                      command: String(name.dropLast(3)))
        if !spec.subcommands.isEmpty || !spec.options.isEmpty { specs.append(spec) }
    }
    guard !specs.isEmpty else { fail("no Fig specs parsed under \(figDir); check the path") }

    let parts = buildCommandTreeParts(specs: specs, usage: observed, pages: pageNames)
    let blob = CommandTree(tools: parts.tools, pipeTargets: parts.pipeTargets).serialize()
    let outPath = required("out")
    guard fm.createFile(atPath: outPath, contents: Data(blob)) else { fail("cannot write file: \(outPath)") }
    print("""
        pages read: \(pagesRead)
        held out skipped: \(heldOut)
        specs parsed: \(specs.count)
        tools kept: \(parts.tools.count)
        total nodes: \(countNodes(parts.tools))
        pipe targets: \(parts.pipeTargets.count)
        bytes: \(blob.count)
        """)
}

func runInspect(_ args: [String]) {
    if args.contains("-h") || args.contains("--help") {
        print(usage)
        exit(0)
    }
    guard args.count == 1, let path = args.first else { fail("usage: semicolyn-dictbuild inspect <file>") }
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read file: \(path)") }
    do {
        print(try inspectDictionary([UInt8](data)))
    } catch DictionaryInspectError.unknownFormat {
        fail("unknown dictionary format (magic is neither GDIC nor GCMT): \(path)")
    } catch DictionaryInspectError.corrupt(let format) {
        fail("\(format) blob failed to load: \(path)")
    } catch {
        fail("cannot inspect \(path): \(error)")
    }
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
case "commands":
    runCommands(Array(args.dropFirst()))
case "inspect":
    runInspect(Array(args.dropFirst()))
default:
    fail("unknown command: \(command)\n\(usage)")
}
