// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SeedKit
import SemicolynKit

/// Predictor evaluation driver. All logic lives in ``SeedKit``; this is argument parsing
/// and file I/O.
///
///     semicolyn-predeval replay -e legacy|v2 -t <file> [-l] [-n 5] [--cli-seed f] [--prose-seed f]
///                               [--english f] [--commands f]
///     semicolyn-predeval tldr-eval -p <tldr pages dir> -o <out file>

let usage = """
usage:
  semicolyn-predeval replay -e|--engine legacy|v2 -t|--text <file> [-l|--learn] [-n|--slots 5]
                            [--cli-seed <file>] [--prose-seed <file>] [--english <file>] [--commands <file>]
  semicolyn-predeval tldr-eval -p|--pages <tldr pages dir> -o|--out <file>
  -h, --help   show this help
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

struct Options {
    var values: [String: String] = [:]
    var flags: Set<String> = []
}

/// Parses `args` against canonical names: `valued` take an argument, `switches` do not.
/// `aliases` maps short/long spellings to the canonical name. Anything else is a usage error.
func parse(_ args: [String], valued: Set<String>, switches: Set<String>,
           aliases: [String: String]) -> Options {
    var opts = Options()
    var i = 0
    while i < args.count {
        let name = aliases[args[i]] ?? args[i]
        if switches.contains(name) {
            opts.flags.insert(name)
            i += 1
        } else if valued.contains(name), i + 1 < args.count {
            opts.values[name] = args[i + 1]
            i += 2
        } else {
            fail("unknown or incomplete option: \(args[i])\n\(usage)")
        }
    }
    return opts
}

func readBytes(_ path: String) -> [UInt8] {
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read file: \(path)") }
    return [UInt8](data)
}

func readSeed(_ path: String?) -> [UInt8]? {
    guard let path else { return nil }
    let bytes = readBytes(path)
    guard LegacyReplay.loadSeed(bytes) != nil else { fail("not a valid combined seed blob: \(path)") }
    return bytes
}

func runReplay(_ args: [String]) {
    let opts = parse(
        args,
        valued: ["engine", "text", "slots", "cli-seed", "prose-seed", "english", "commands"],
        switches: ["learn"],
        aliases: ["-e": "engine", "--engine": "engine", "-t": "text", "--text": "text",
                  "-l": "learn", "--learn": "learn", "-n": "slots", "--slots": "slots",
                  "--cli-seed": "cli-seed", "--prose-seed": "prose-seed",
                  "--english": "english", "--commands": "commands"])
    guard let engine = opts.values["engine"] else { fail("missing --engine\n\(usage)") }
    guard let textPath = opts.values["text"] else { fail("missing --text\n\(usage)") }
    let slots = opts.values["slots"].flatMap { Int($0) } ?? 5
    guard slots >= 1 else { fail("--slots must be a positive integer") }
    guard let text = String(data: Data(readBytes(textPath)), encoding: .utf8) else {
        fail("not valid UTF-8: \(textPath)")
    }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
        .filter { !$0.isEmpty }
    let config = ReplayConfig(visibleSlots: slots, learn: opts.flags.contains("learn"))

    let report: ReplayReport
    switch engine {
    case "legacy":
        var predictor = LegacyReplay(cliSeed: readSeed(opts.values["cli-seed"]),
                                     proseSeed: readSeed(opts.values["prose-seed"]))
        report = replay(lines: lines, predictor: &predictor, config: config)
    case "v2":
        fail("engine v2 is not available yet")
    default:
        fail("unknown engine: \(engine) (expected legacy or v2)")
    }
    print(String(format: "saved/100=%.2f zero=%.1f%% lookups=%d hits=%@ p95ms=%.3f",
                 report.savedPer100, report.zeroRate * 100, report.lookups,
                 "\(report.hitsBySlot)", report.p95LatencyMs))
}

func runTldrEval(_ args: [String]) {
    let opts = parse(args, valued: ["pages", "out"], switches: [],
                     aliases: ["-p": "pages", "--pages": "pages", "-o": "out", "--out": "out"])
    guard let pagesPath = opts.values["pages"] else { fail("missing --pages\n\(usage)") }
    guard let outPath = opts.values["out"] else { fail("missing --out\n\(usage)") }
    let fm = FileManager.default
    var lines: [String] = []
    var pageCount = 0
    for platform in ["common", "linux", "osx"] {
        let dir = URL(fileURLWithPath: pagesPath, isDirectory: true).appendingPathComponent(platform)
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else {
            fail("cannot read directory: \(dir.path)")
        }
        for name in names.sorted() where name.hasSuffix(".md") {
            let stem = String(name.dropLast(3))
            guard TldrHoldout.isHeldOut(pageStem: stem) else { continue }
            let file = dir.appendingPathComponent(name)
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                fail("cannot read page: \(file.path)")
            }
            pageCount += 1
            lines += TldrParser.invocations(fromPage: text).map { $0.joined(separator: " ") }
        }
    }
    guard !lines.isEmpty else { fail("no held-out invocations found, wrong directory?") }
    do {
        try (lines.joined(separator: "\n") + "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
    } catch {
        fail("cannot write \(outPath): \(error)")
    }
    print("tldr-eval: \(pageCount) held-out pages, \(lines.count) invocations -> \(outPath)")
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail(usage) }
switch command {
case "-h", "--help", "help":
    print(usage)
case "replay":
    runReplay(Array(args.dropFirst()))
case "tldr-eval":
    runTldrEval(Array(args.dropFirst()))
default:
    fail("unknown command: \(command)\n\(usage)")
}
