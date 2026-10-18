// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SemicolynKit

/// Usage statistics gathered from tldr example lines: how often each tool, subcommand path,
/// flag (per path) and pipe target appears.
///
/// Fed with ``ingest(page:examples:)``, tool and pipe-target counts measure use across pages
/// (see that method); fed with ``ingest(example:)``, every count is per example.
public struct CommandUsage {
    public var toolCounts: [String: Int] = [:]
    public var pathCounts: [[String]: Int] = [:]
    public var flagCounts: [[String]: [String: Int]] = [:]
    public var pipeTargetCounts: [String: Int] = [:]

    /// Page stems already credited per tool (cross-family use) and per pipe target.
    private var toolPages: Set<[String]> = []
    private var pipePages: Set<[String]> = []
    /// Stems of ingested pages, tools used as a segment command, tools given the own-page bonus.
    private var ownPages: Set<String> = []
    private var usedTools: Set<String> = []
    private var ownPageCredited: Set<String> = []

    public init() {}

    /// Counts every command segment of `example`, one count per occurrence for tools and pipe
    /// targets as well as paths and flags. See ``countSegments(of:)`` for the parsing rules.
    public mutating func ingest(example: String) {
        for use in countSegments(of: example) {
            toolCounts[use.tool, default: 0] += 1
            if use.afterPipe { pipeTargetCounts[use.tool, default: 0] += 1 }
        }
    }

    /// Counts the examples of the tldr page `page` (its file stem). Paths and flags count per
    /// example. A tool counts once per distinct page outside its own family (stem equal to the
    /// tool or starting with `tool-`), plus 1 once if the tool has its own page; a pipe target
    /// counts once per distinct page that pipes into it. So a tool's own many examples do not
    /// make it popular; use by other pages does.
    public mutating func ingest(page: String, examples: [String]) {
        var touched: Set<String> = []
        if isCommandName(page) {
            ownPages.insert(page)
            touched.insert(page)
        }
        for example in examples {
            for use in countSegments(of: example) {
                usedTools.insert(use.tool)
                touched.insert(use.tool)
                let ownFamily = page == use.tool || page.hasPrefix(use.tool + "-")
                if !ownFamily, toolPages.insert([use.tool, page]).inserted {
                    toolCounts[use.tool, default: 0] += 1
                }
                if use.afterPipe, pipePages.insert([use.tool, page]).inserted {
                    pipeTargetCounts[use.tool, default: 0] += 1
                }
            }
        }
        // Own-page bonus once both facts are known, whichever page arrives first.
        for tool in touched where ownPages.contains(tool) && usedTools.contains(tool) {
            if ownPageCredited.insert(tool).inserted { toolCounts[tool, default: 0] += 1 }
        }
    }

    /// Records path and flag counts for each command segment of `example` and returns the
    /// segment commands. Each `{{...}}` placeholder (which may hold spaces and `|` alternatives)
    /// is first collapsed to one opaque word, so its contents never become words, segments or
    /// pipe targets. An example whose command is `tldr` itself (the stock "View documentation"
    /// line of alias pages) is dropped. Wrappers (`sudo`, ...) are stripped. The path grows by
    /// non-flag words in the second and third positions; the first flag or placeholder ends it.
    /// Flags are cut at `=` or a glued `{{` and counted against the path so far. A segment whose
    /// first word cannot be a command name (see ``isCommandName(_:)``) is skipped.
    private mutating func countSegments(of example: String) -> [(tool: String, afterPipe: Bool)] {
        let segments = commandSegments(of: collapsingPlaceholders(example))
        if let first = segments.first, strippingWrappers(first.words).first == "tldr" { return [] }
        var uses: [(tool: String, afterPipe: Bool)] = []
        for segment in segments {
            let words = strippingWrappers(segment.words)
            guard let tool = words.first, isCommandName(tool) else { continue }
            uses.append((tool, segment.afterPipe))

            var path = [tool]
            var extending = true
            for (index, word) in words.enumerated().dropFirst() {
                if word.hasPrefix("-") {
                    extending = false
                    // Flag name: cut at `=` and at a glued placeholder (`-n{{5}}`).
                    var end = word.endIndex
                    for marker in ["=", "{{"] {
                        if let r = word.range(of: marker), r.lowerBound < end { end = r.lowerBound }
                    }
                    let flag = String(word[..<end])
                    guard flag.count > 1, flag != "--" else { continue }
                    flagCounts[path, default: [:]][flag, default: 0] += 1
                    continue
                }
                if word.contains("{{") {
                    extending = false
                    continue
                }
                guard extending, index <= 2 else {
                    extending = false
                    continue
                }
                path.append(word)
                pathCounts[path, default: 0] += 1
            }
        }
        return uses
    }
}

/// The placeholder word every `{{...}}` span collapses to.
private let placeholderWord = "{{}}"

/// `line` with each `{{...}}` span (up to the first following `}}`, across spaces and `|`)
/// replaced by ``placeholderWord``. An unterminated `{{` is left as is.
private func collapsingPlaceholders(_ line: String) -> String {
    var out = ""
    var rest = Substring(line)
    while let open = rest.range(of: "{{") {
        guard let close = rest[open.upperBound...].range(of: "}}") else { break }
        out += rest[..<open.lowerBound]
        out += placeholderWord
        rest = rest[close.upperBound...]
    }
    out += rest
    return out
}

/// Whether `word` can name a command: ASCII letters, digits and `.`, `_`, `+`, `-` only, at
/// least one letter, not starting with `-` or `.`. Rejects placeholders, paths, variables
/// (`$X`), assignments (`a=b`), redirection numbers (`2`) and punctuation (`...`).
public func isCommandName(_ word: String) -> Bool {
    guard let first = word.unicodeScalars.first, first != "-", first != "." else { return false }
    var sawLetter = false
    for scalar in word.unicodeScalars {
        switch scalar {
        case "a"..."z", "A"..."Z": sawLetter = true
        case "0"..."9", ".", "_", "+", "-": continue
        default: return false
        }
    }
    return sawLetter
}
