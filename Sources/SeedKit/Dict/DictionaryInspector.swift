// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SemicolynKit

/// Why ``inspectDictionary(_:)`` could not report on a blob.
public enum DictionaryInspectError: Error, Equatable {
    /// The first four bytes are neither `GDIC` nor `GCMT`.
    case unknownFormat
    /// The magic matched but the reader rejected the blob; the payload names the format.
    case corrupt(String)
}

/// Human-readable probe report for a built dictionary blob, detected by magic.
///
/// `GDIC` (English): word count, top 10 completions for fixed prefixes, and top 10
/// successors of fixed words. `GCMT` (commands): top-level tool count and top 10
/// candidates for fixed command-line positions. Each probe prints `text:score` pairs.
public func inspectDictionary(_ bytes: [UInt8]) throws -> String {
    let magic = bytes.count >= 4 ? String(decoding: bytes[0..<4], as: UTF8.self) : ""
    switch magic {
    case "GDIC":
        guard let dict = WordDictionary(deserializing: bytes) else { throw DictionaryInspectError.corrupt("GDIC") }
        var lines = ["format: GDIC english", "bytes: \(bytes.count)", "words: \(dict.wordCount)"]
        for prefix in ["t", "th", "Th", "i", "I", "lin", "ap", "AP"] {
            lines.append("complete \(prefix): " + formatProbe(dict.completions(typed: prefix, limit: 10)))
        }
        for word in ["the", "I", "to"] {
            lines.append("after \(word): " + formatProbe(dict.successors(of: word, limit: 10)))
        }
        return lines.joined(separator: "\n")
    case "GCMT":
        guard let tree = CommandTree(deserializing: bytes) else { throw DictionaryInspectError.corrupt("GCMT") }
        let toolCount = tree.candidates(segmentWords: [], typed: "", afterPipe: false, limit: Int.max).count
        var lines = ["format: GCMT commands", "bytes: \(bytes.count)", "tools: \(toolCount)"]
        let probes: [(label: String, words: [String], typed: String, afterPipe: Bool)] = [
            ("line start", [], "", false),
            ("git ", ["git"], "", false),
            ("git c", ["git"], "c", false),
            ("docker ", ["docker"], "", false),
            ("ls -", ["ls"], "-", false),
            ("| ", [], "", true),
        ]
        for probe in probes {
            let found = tree.candidates(segmentWords: probe.words, typed: probe.typed,
                                        afterPipe: probe.afterPipe, limit: 10)
            lines.append("probe '\(probe.label)': " + formatProbe(found))
        }
        return lines.joined(separator: "\n")
    default:
        throw DictionaryInspectError.unknownFormat
    }
}

/// `text:score` pairs separated by spaces, or `(none)`.
private func formatProbe(_ words: [ScoredWord]) -> String {
    words.isEmpty ? "(none)" : words.map { "\($0.text):\($0.score)" }.joined(separator: " ")
}
