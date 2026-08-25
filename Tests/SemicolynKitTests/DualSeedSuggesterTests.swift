// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Minimal in-memory candidate source for deterministic ranking tests.
private struct FakeSource: CandidateSource {
    let items: [TokenCount]
    func candidates(forPrefix prefix: String) -> [TokenCount] {
        items.filter { $0.token.hasPrefix(prefix) }
    }
}

final class DualSeedSuggesterTests: XCTestCase {
    private let empty = FakeSource(items: [])
    // CLI seed suggests "commit"; prose seed suggests "compose" for prefix "com".
    private let cliSeed = FakeSource(items: [TokenCount(token: "commit", count: 100)])
    private let proseSeed = FakeSource(items: [TokenCount(token: "compose", count: 100)])
    private let cfg = SuggestionConfig(topK: 2, confidenceFloor: 2, seedWeight: 1.0, minPrefix: 2)

    func testBiasZeroIsCliOnly() {
        let s = DualSeedSuggester(learned: empty, cliSeed: cliSeed, proseSeed: proseSeed,
                                  bias: 0.0, config: cfg, learnedMagnitude: 100,
                                  cliMagnitude: 100, proseMagnitude: 100)
        // prose scaled by 0 -> only "commit" survives.
        XCTAssertEqual(s.suggestions(forPrefix: "com"), ["commit"])
    }

    func testBiasOneIsProseOnly() {
        let s = DualSeedSuggester(learned: empty, cliSeed: cliSeed, proseSeed: proseSeed,
                                  bias: 1.0, config: cfg, learnedMagnitude: 100,
                                  cliMagnitude: 100, proseMagnitude: 100)
        XCTAssertEqual(s.suggestions(forPrefix: "com"), ["compose"])
    }

    func testMidBiasInterleavesByScaledScore() {
        // bias 0.7: prose 100*0.7=70 outranks cli 100*0.3=30 -> compose first.
        let s = DualSeedSuggester(learned: empty, cliSeed: cliSeed, proseSeed: proseSeed,
                                  bias: 0.7, config: cfg, learnedMagnitude: 100,
                                  cliMagnitude: 100, proseMagnitude: 100)
        XCTAssertEqual(s.suggestions(forPrefix: "com"), ["compose", "commit"])
    }

    func testConfidentLearnedFastPathIgnoresSeeds() {
        // Two confident learned candidates >= topK(2) -> seeds not consulted.
        let learned = FakeSource(items: [TokenCount(token: "comrade", count: 9),
                                         TokenCount(token: "combine", count: 5)])
        let s = DualSeedSuggester(learned: learned, cliSeed: cliSeed, proseSeed: proseSeed,
                                  bias: 0.9, config: cfg, learnedMagnitude: 9,
                                  cliMagnitude: 100, proseMagnitude: 100)
        XCTAssertEqual(s.suggestions(forPrefix: "com"), ["comrade", "combine"])
    }

    // MARK: - scoredSuggestions

    func testScoredSuggestionsMatchesStringOrder() {
        // Regression lock: scoredSuggestions' tokens must match suggestions() exactly
        // for the mid-bias blend path.
        let s = DualSeedSuggester(learned: empty, cliSeed: cliSeed, proseSeed: proseSeed,
                                  bias: 0.7, config: cfg, learnedMagnitude: 100,
                                  cliMagnitude: 100, proseMagnitude: 100)
        let scored = s.scoredSuggestions(forPrefix: "com")
        XCTAssertEqual(scored.map { $0.token }, s.suggestions(forPrefix: "com"))
        XCTAssertEqual(scored.map { $0.token }, ["compose", "commit"])
    }

    func testScoredSuggestionsDescendingByScore() {
        // Same mid-bias setup: compose(70) must score above commit(30), and the
        // returned list must be sorted score-descending.
        let s = DualSeedSuggester(learned: empty, cliSeed: cliSeed, proseSeed: proseSeed,
                                  bias: 0.7, config: cfg, learnedMagnitude: 100,
                                  cliMagnitude: 100, proseMagnitude: 100)
        let scored = s.scoredSuggestions(forPrefix: "com")
        XCTAssertEqual(scored.map { $0.score }, scored.map { $0.score }.sorted(by: >))
        XCTAssertEqual(scored.count, 2)
        XCTAssertGreaterThan(scored[0].score, scored[1].score)
        XCTAssertEqual(scored[0].token, "compose")
        XCTAssertEqual(scored[1].token, "commit")
    }

    func testScoredSuggestionsConfidentFastPathExactScores() {
        // Confident-learned fast path scores are the raw Double(count), not
        // normalized/blended.
        let learned = FakeSource(items: [TokenCount(token: "comrade", count: 9),
                                         TokenCount(token: "combine", count: 5)])
        let s = DualSeedSuggester(learned: learned, cliSeed: cliSeed, proseSeed: proseSeed,
                                  bias: 0.9, config: cfg, learnedMagnitude: 9,
                                  cliMagnitude: 100, proseMagnitude: 100)
        let scored = s.scoredSuggestions(forPrefix: "com")
        XCTAssertEqual(scored.count, 2)
        XCTAssertEqual(scored[0].token, "comrade")
        XCTAssertEqual(scored[0].score, 9.0)
        XCTAssertEqual(scored[1].token, "combine")
        XCTAssertEqual(scored[1].score, 5.0)
    }

    func testScoredSuggestionsEmptyReturnsEmptyArray() {
        let s = DualSeedSuggester(learned: empty, cliSeed: empty, proseSeed: empty,
                                  bias: 0.5, config: cfg, learnedMagnitude: 0,
                                  cliMagnitude: 0, proseMagnitude: 0)
        XCTAssertEqual(s.scoredSuggestions(forPrefix: "zzz").count, 0)
        XCTAssertTrue(s.scoredSuggestions(forPrefix: "zzz").isEmpty)
    }
}
