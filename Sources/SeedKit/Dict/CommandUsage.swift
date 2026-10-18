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

    /// Counts every command segment of `example`. Wrappers (`sudo`, ...) are stripped first.
    /// The path grows by non-flag words in the second and third positions; the first flag or
    /// placeholder ends it. Flags are cut at `=` or a glued `{{` and counted against the path so far.
    public mutating func ingest(example: String) {
        for segment in commandSegments(of: example) {
            let words = strippingWrappers(segment.words)
            guard let tool = words.first, Self.isCountable(tool) else { continue }
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

    private static func isCountable(_ tool: String) -> Bool {
        !tool.isEmpty && !tool.hasPrefix("-") && !tool.contains("{{")
    }
}
