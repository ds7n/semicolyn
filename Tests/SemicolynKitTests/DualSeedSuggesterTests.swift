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
}
