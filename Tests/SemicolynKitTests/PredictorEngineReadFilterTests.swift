// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class PredictorEngineReadFilterTests: XCTestCase {
    // Build a seed whose unigram vocab contains two tokens at a known count.
    // Mirrors `PredictorEngineContextTests.seed(token:count:)`.
    private func seed(tokens: [(token: String, count: UInt32)]) -> PredictorSeed {
        var uni = Vocabulary(depth: 4, width: 1 << 12)
        for (token, count) in tokens {
            for _ in 0..<count { uni.record(token) }
        }
        let bi = BigramVocabulary(depth: 4, width: 1 << 12)
        return PredictorSeed(unigram: uni, bigram: bi)
    }

    private let cfg = SuggestionConfig(topK: 5, confidenceFloor: 2, seedWeight: 1.0, minPrefix: 1)

    // A seed-baked profane token must never surface from suggestions(), even though
    // it was never passed through `record` (the write-time filter). This is the
    // read-time safety backstop for ANY seed (CLI, prose, or future additions).
    func testExcludedSeedTokenNeverSuggested() {
        let filter = TokenFilter(patterns: [.blocklist(["wtf"])])
        let seed = seed(tokens: [("wtf", 50), ("west", 50)])
        let e = PredictorEngine(learned: LearnedState.empty, seed: seed, filter: filter, config: cfg)

        let results = e.suggestions(forPrefix: "w")

        XCTAssertFalse(results.contains("wtf"), "excluded token must never be suggested")
        XCTAssertTrue(results.contains("west"), "clean token sharing the prefix must still be suggested")
    }

    // M-1 regression: when a profane token would rank ABOVE topK clean candidates
    // sharing the prefix, the engine must still return topK CLEAN suggestions
    // (backfilled from the next candidate), not topK-minus-the-excluded-one. This
    // requires the exclusion filter to run BEFORE the topK truncation, not after.
    func testProfaneTopRankedTokenIsBackfilledNotJustDropped() {
        let filter = TokenFilter(patterns: [.blocklist(["shitshow"])])
        let smallCfg = SuggestionConfig(topK: 3, confidenceFloor: 2, seedWeight: 1.0, minPrefix: 1)
        // "shitshow" has the highest count so it would occupy the #1 topK slot if
        // ranked before filtering; four clean tokens share the "sh" prefix, more
        // than topK, so a correct backfill still fills all 3 slots with clean tokens.
        let seed = seed(tokens: [
            ("shitshow", 999),
            ("share", 90),
            ("shape", 80),
            ("shell", 70),
            ("ship", 60),
        ])
        let e = PredictorEngine(learned: LearnedState.empty, seed: seed, filter: filter, config: smallCfg)

        let results = e.suggestions(forPrefix: "sh")

        XCTAssertEqual(results.count, 3, "topK clean suggestions must be fully backfilled")
        XCTAssertFalse(results.contains("shitshow"), "excluded token must never be suggested")
        XCTAssertEqual(results, ["share", "shape", "shell"],
                       "the 3 highest-count CLEAN tokens must fill topK, in rank order")
    }
}
