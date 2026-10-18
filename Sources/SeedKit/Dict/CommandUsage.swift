// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
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
    /// Tools named by a tldr page of their own (``tldrPageToolName(stem:markdown:)``), recorded
    /// by ``ingest(page:markdown:)`` for held-out pages too; the tree admits each even with no
    /// usage and no Fig spec.
    public var pageTools: Set<String> = []

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

    /// Counts the tldr page `page` (file stem) from its markdown. A held-out page
    /// (``TldrHoldout``) still exists: it gives its tool the own-page credit and its name (see
    /// ``pageTools``), but its examples are not read, so evaluation pages never feed paths,
    /// flags or tool use.
    public mutating func ingest(page: String, markdown: String) {
        if let name = tldrPageToolName(stem: page, markdown: markdown) { pageTools.insert(name) }
        let examples = TldrHoldout.isHeldOut(pageStem: page) ? [] : TldrParser.exampleCommands(fromPage: markdown)
        ingest(page: page, examples: examples)
    }

    /// Records path and flag counts for each command segment of `example` and returns the
    /// segment commands. Each `{{...}}` placeholder (which may hold spaces and `|` alternatives)
    /// is first collapsed to one opaque word, so its contents never become words, segments or
    /// pipe targets. An example whose command is `tldr` itself (the stock "View documentation"
    /// line of alias pages) is dropped. Wrappers (`sudo`, ...) are stripped. The path grows by
    /// non-flag words in the second and third positions; the first flag or placeholder ends it.
    /// Flags are cut at `=` or a glued `{{` and counted against the path so far. Each removed
    /// wrapper (`sudo`, `xargs`, ...) is itself a use, and a pipe target when it is the first
    /// word after `|` (the wrapped command then counts as a tool only). Only words that can be command names (see
    /// ``isCommandName(_:)``) are used; a segment whose command cannot be one adds no path.
    private mutating func countSegments(of example: String) -> [(tool: String, afterPipe: Bool)] {
        let segments = commandSegments(of: collapsingPlaceholders(example))
        if let first = segments.first, strippingWrappers(first.words).first == "tldr" { return [] }
        var uses: [(tool: String, afterPipe: Bool)] = []
        for segment in segments {
            let words = strippingWrappers(segment.words)
            // The removed prefix is wrappers plus their options and assignments.
            let removed = segment.words.prefix(segment.words.count - words.count)
            for (position, word) in removed.enumerated()
            where !word.hasPrefix("-") && !word.contains("=") && isCommandName(word) {
                uses.append((word, segment.afterPipe && position == 0))
            }
            guard let tool = words.first, isCommandName(tool) else { continue }
            // Only the first word after `|` is a pipe target: a wrapper there takes that role.
            uses.append((tool, segment.afterPipe && removed.isEmpty))

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

/// The tool a tldr page documents: its stem, when the page title (the first line, `# title`)
/// equals the stem ignoring case and the stem is a command name (``isCommandName(_:)``).
/// Subcommand pages (`adb-connect`, titled `adb connect`) and concept pages (`!`, titled
/// `Exclamation mark`) name no tool. Only the title line is read, never the examples.
public func tldrPageToolName(stem: String, markdown: String) -> String? {
    guard isCommandName(stem) else { return nil }
    let firstLine = markdown.prefix { !$0.isNewline }
    guard firstLine.hasPrefix("# ") else { return nil }
    let title = firstLine.dropFirst(2).trimmingCharacters(in: .whitespaces)
    return title.lowercased() == stem.lowercased() ? stem : nil
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

/// Shell reserved words: syntax, not commands.
private let shellReservedWords: Set<String> = [
    "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac",
    "function", "select", "in", "{", "}",
]

/// Whether `word` can name a command: at least two characters, ASCII letters, digits and `.`,
/// `_`, `+`, `-` only, at least one letter, not starting with `-` or `.`, and not a shell
/// reserved word. Rejects placeholders, paths, variables (`$X`), assignments (`a=b`),
/// redirection numbers (`2`), punctuation (`...`), keystrokes (`q`) and `while`/`do`/...
/// Builtins people type (`cd`, `export`, `source`) are names.
public func isCommandName(_ word: String) -> Bool {
    guard word.unicodeScalars.count >= 2, !shellReservedWords.contains(word) else { return false }
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
