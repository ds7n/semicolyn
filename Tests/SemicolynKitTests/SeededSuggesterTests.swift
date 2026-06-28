// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// SeededSuggester — Core tier. Verifies the two-layer per-prefix deference:
/// the seed fills when the user lacks signal and steps aside when they have it.
final class SeededSuggesterTests: XCTestCase {
    private func vocab(_ entries: [(String, UInt32)]) -> Vocabulary {
        var v = Vocabulary(depth: 4, width: 1 << 14)
        for (t, c) in entries { v.record(t, count: c) }
        return v
    }

    private func suggester(
        learned: [(String, UInt32)],
        seed: [(String, UInt32)],
        config: SuggestionConfig = .init()
    ) -> SeededSuggester {
        SeededSuggester(learned: vocab(learned), seed: vocab(seed), config: config)
    }

    // MARK: Layer 2 gating

    func testFastPathHidesSeedWhenEnoughConfidentLearned() {
        // 4 confident learned ≥ topK=3 → seed not consulted, even a huge seed entry.
        let s = suggester(
            learned: [("git", 10), ("gitk", 5), ("gitignore", 4), ("github", 3)],
            seed: [("git-extras", 1000)])
        XCTAssertEqual(s.suggestions(forPrefix: "git"), ["git", "gitk", "gitignore"])
    }

    func testSeedFillsWhenNoLearnedSignal() {
        let s = suggester(learned: [], seed: [("carapace", 1)])
        XCTAssertEqual(s.suggestions(forPrefix: "cara"), ["carapace"])
    }

    func testMixedBlendsConfidentLearnedWithSeed() {
        // 1 confident < topK=3 → fill path: kubectl = 5 + 0.5·100 = 55,
        // kustomize = 0.5·50 = 25, kafka = 0.5·20 = 10.
        let s = suggester(
            learned: [("kubectl", 5)],
            seed: [("kubectl", 100), ("kustomize", 50), ("kafka", 20)])
        XCTAssertEqual(s.suggestions(forPrefix: "k"), ["kubectl", "kustomize", "kafka"])
    }

    // MARK: Layer 1 weighting

    func testLearnedOutranksComparableSeedAtEqualRawCount() {
        // xy (learned 4 → score 4) vs xz (seed 4 → score 0.5·4 = 2): the seed's
        // thumb-on-the-scale keeps it below a comparable learned entry.
        let s = suggester(learned: [("xy", 4)], seed: [("xz", 4)])
        XCTAssertEqual(s.suggestions(forPrefix: "x"), ["xy", "xz"])
    }

    func testSameTokenBlendsBothSources() {
        // vim = learned 3 + 0.5·100 = 53; vimrc = 0.5·100 = 50.
        let s = suggester(learned: [("vim", 3)], seed: [("vim", 100), ("vimrc", 100)])
        XCTAssertEqual(s.suggestions(forPrefix: "vim"), ["vim", "vimrc"])
    }

    // MARK: confidence floor (BVA)

    func testBelowFloorLearnedTokenNotSuggestedSeedFillsInstead() {
        // "once" typed once (< floor 2) must not surface; the seed fills.
        let s = suggester(learned: [("once", 1)], seed: [("online", 10)])
        XCTAssertEqual(s.suggestions(forPrefix: "on"), ["online"],
                       "a below-floor learned token must not be suggested")
    }

    func testAtFloorLearnedTokenIsSuggested() {
        // "twice" at exactly floor 2 counts as a confident candidate.
        let s = suggester(learned: [("twice", 2)], seed: [])
        XCTAssertEqual(s.suggestions(forPrefix: "tw"), ["twice"])
    }

    // MARK: limits / determinism

    func testTopKCaps() {
        let s = suggester(
            learned: [],
            seed: [("xa", 9), ("xb", 8), ("xc", 7)],
            config: SuggestionConfig(topK: 2))
        XCTAssertEqual(s.suggestions(forPrefix: "x"), ["xa", "xb"])
    }

    func testNonPositiveTopKReturnsEmpty() {
        let s = suggester(learned: [("git", 5)], seed: [],
                          config: SuggestionConfig(topK: 0))
        XCTAssertEqual(s.suggestions(forPrefix: "g"), [])
    }

    func testTieBrokenLexicographically() {
        // Equal seed counts → equal scores → token-ascending tie-break.
        let s = suggester(learned: [], seed: [("ab", 10), ("aa", 10)])
        XCTAssertEqual(s.suggestions(forPrefix: "a"), ["aa", "ab"])
    }

    func testLearningFlipsRanking() {
        // Before learning, the seed ranks clang(0.5·100=50) over claude(0.5·1=0.5).
        let seed = vocab([("claude", 1), ("clang", 100)])
        var learned = Vocabulary(depth: 4, width: 1 << 14)
        let before = SeededSuggester(learned: learned, seed: seed)
        XCTAssertEqual(before.suggestions(forPrefix: "cl"), ["clang", "claude"])
        // Learning "claude" enough flips the order — proving the learned counts
        // actually drive ranking (with no learning, clang stays first).
        for _ in 0..<200 { learned.record("claude") }
        let after = SeededSuggester(learned: learned, seed: seed)
        XCTAssertEqual(after.suggestions(forPrefix: "cl"), ["claude", "clang"])
    }

    func testRanksOverWindowedAggregateRequiringSum() {
        // "deploy" appears once in each of today and rolling — below the
        // confidence floor of 2 in either alone, but today ⊕ rolling sums to 2,
        // exactly clearing the floor. If the aggregate failed to SUM (read a
        // single source), "deploy" would stay sub-floor and not surface. So this
        // distinctly proves summing drives the outcome, end to end through the
        // suggester — not just union.
        let today = vocab([("deploy", 1)])
        let rolling = vocab([("deploy", 1)])
        let learned = AggregateCandidateSource([today, rolling])
        let s = SeededSuggester(learned: learned, seed: vocab([]))  // default floor 2
        XCTAssertEqual(s.suggestions(forPrefix: "de"), ["deploy"])
    }
}
