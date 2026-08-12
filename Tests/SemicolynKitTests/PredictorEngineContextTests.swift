// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class PredictorEngineContextTests: XCTestCase {
    // Build a seed whose unigram vocab contains one token at a known count.
    // NOTE: `PredictorSeed`'s real (and only) initializer is the memberwise
    // `init(unigram: Vocabulary, bigram: BigramVocabulary)`, not
    // `init(version:unigramBlob:bigramBlob:)` as the brief guessed; a
    // serialize/deserialize round trip is unnecessary here.
    private func seed(token: String, count: UInt32) -> PredictorSeed {
        var uni = Vocabulary(depth: 4, width: 1 << 12)
        for _ in 0..<count { uni.record(token) }
        let bi = BigramVocabulary(depth: 4, width: 1 << 12)
        return PredictorSeed(unigram: uni, bigram: bi)
    }

    private let cfg = SuggestionConfig(topK: 2, confidenceFloor: 2, seedWeight: 1.0, minPrefix: 2)

    // Regression gate: default context (all-nil) with no prose seed == today.
    func testDefaultContextNoProseSeedUnchanged() {
        let e = PredictorEngine(learned: LearnedState.empty, seed: seed(token: "commit", count: 50),
                                config: cfg)
        XCTAssertEqual(e.suggestions(forPrefix: "com"), ["commit"])
        // explicit default context path is identical
        XCTAssertEqual(e.suggestions(forPrefix: "com", after: nil, context: .init()), ["commit"])
    }

    // With a prose seed and a prose-leaning context, the prose token can win.
    func testProseContextSurfacesProseToken() {
        let e = PredictorEngine(learned: LearnedState.empty,
                                seed: seed(token: "commit", count: 100),
                                proseSeed: seed(token: "compose", count: 100),
                                config: cfg)
        // foregroundProcess "claude" -> bias 0.85 -> prose "compose" outranks "commit".
        let ctx = PredictionContext(foregroundProcess: "claude")
        XCTAssertEqual(e.suggestions(forPrefix: "com", after: nil, context: ctx).first, "compose")
    }

    // A CLI context keeps the CLI token first even with a prose seed present.
    func testCliContextKeepsCliToken() {
        let e = PredictorEngine(learned: LearnedState.empty,
                                seed: seed(token: "commit", count: 100),
                                proseSeed: seed(token: "compose", count: 100),
                                config: cfg)
        let ctx = PredictionContext(foregroundProcess: "zsh")   // bias 0.15
        XCTAssertEqual(e.suggestions(forPrefix: "com", after: nil, context: ctx).first, "commit")
    }
}
