// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SemicolynKit

/// Usage statistics gathered from tldr example lines: how often each tool, subcommand path,
/// flag (per path) and pipe target appears.
public struct CommandUsage {
    public var toolCounts: [String: Int] = [:]
    public var pathCounts: [[String]: Int] = [:]
    public var flagCounts: [[String]: [String: Int]] = [:]
    public var pipeTargetCounts: [String: Int] = [:]

    public init() {}

    /// Counts every command segment of `example`. Each `{{...}}` placeholder (which may hold
    /// spaces and `|` alternatives) is first collapsed to one opaque word, so its contents never
    /// become words, segments or pipe targets. Wrappers (`sudo`, ...) are stripped next.
    /// The path grows by non-flag words in the second and third positions; the first flag or
    /// placeholder ends it. Flags are cut at `=` or a glued `{{` and counted against the path so far.
    /// A segment whose first word cannot be a command name (see ``isCommandName(_:)``) is skipped.
    public mutating func ingest(example: String) {
        for segment in commandSegments(of: collapsingPlaceholders(example)) {
            let words = strippingWrappers(segment.words)
            guard let tool = words.first, isCommandName(tool) else { continue }
            toolCounts[tool, default: 0] += 1
            if segment.afterPipe { pipeTargetCounts[tool, default: 0] += 1 }

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
