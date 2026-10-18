// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SemicolynKit

/// Adapter that drives the single-ranker `PredictorEngine` the way the app does: chips
/// come from `suggestions(line:lineOptedOut:)` and a committed line is learned token by
/// token through an ``InputTokenTracker``, echo confirmed.
public struct EngineReplay: ReplayPredictor {
    private var engine: PredictorEngine

    /// Builds the engine from the shipped dictionary blobs (`english_v2.bin`,
    /// `commands_v2.bin`); `nil` or an unreadable blob means that source adds nothing.
    public init(english: [UInt8]?, commands: [UInt8]?) {
        engine = PredictorEngine(
            learned: .empty,
            english: english.flatMap { WordDictionary(deserializing: $0) },
            commands: commands.flatMap { CommandTree(deserializing: $0) })
    }

    public mutating func suggestions(line: String) -> [String] {
        engine.suggestions(line: line, lineOptedOut: false).map(\.text)
    }

    public mutating func commit(line: String) {
        var tracker = InputTokenTracker()
        let committed = tracker.observe(Array((line + "\r").utf8))
        let optedOut = tracker.lastCommittedLineOptedOut
        engine.beginLine()
        for token in committed {
            engine.record(token.token, after: token.previous, echoConfirmed: true, optedOut: optedOut)
        }
    }
}
