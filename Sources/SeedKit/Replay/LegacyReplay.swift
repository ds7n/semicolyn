// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SemicolynKit

/// Adapter that drives the shipping (legacy) `PredictorEngine` exactly the way the app's
/// `refreshPredictorSuggestions` does, so its replay numbers are the baseline v2 must beat.
public struct LegacyReplay: ReplayPredictor {
    private var engine: PredictorEngine

    /// Builds the engine from combined-blob seeds (the `seed_pinned` layout); `nil` or an
    /// unreadable blob means no seed of that kind (see ``loadSeed(_:)`` to validate first).
    public init(cliSeed: [UInt8]?, proseSeed: [UInt8]?) {
        engine = PredictorEngine(
            learned: .empty,
            seed: cliSeed.flatMap(Self.loadSeed),
            proseSeed: proseSeed.flatMap(Self.loadSeed))
    }

    /// Parses a combined seed blob into a queryable seed, or nil if it is malformed.
    public static func loadSeed(_ blob: [UInt8]) -> PredictorSeed? {
        guard let bundled = BundledSeed(combinedBlob: blob),
              let unigram = Vocabulary(deserializing: bundled.unigramBlob),
              let bigram = BigramVocabulary(deserializing: bundled.bigramBlob) else { return nil }
        return PredictorSeed(unigram: unigram, bigram: bigram)
    }

    public mutating func suggestions(line: String) -> [String] {
        var tracker = InputTokenTracker()
        _ = tracker.observe(Array(line.utf8))
        let context = PredictionContext(line: tracker.line, cursorIndex: tracker.cursorIndex)
        let request = suggestionRequest(
            current: tracker.current, previous: tracker.previous, precedingToken: tracker.previous,
            lineOptedOut: tracker.lineOptedOut, minPrefix: engine.config.minPrefix)
        switch request {
        case .blended(let current, let previous, let allowNextWord):
            return engine.blendedSuggestions(
                current: current, previous: previous, allowNextWord: allowNextWord, context: context
            ).map(\.token)
        case .nextWord(let word):
            let raw = engine.suggestions(forPrefix: "", after: word, context: context)
            return predictorChips(current: word, suggestions: raw)
        case .none:
            return []
        }
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
