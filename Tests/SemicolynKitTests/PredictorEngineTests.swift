// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// PredictorEngine — Core tier. The runtime facade composing privacy filter +
/// learned stores + seed + seed-deferring ranker. See
/// `2026-06-21-predictor-engine-design`.
final class PredictorEngineTests: XCTestCase {
    private func engine(seed: PredictorSeed? = nil,
                        config: SuggestionConfig = .init()) -> PredictorEngine {
        PredictorEngine(learned: .empty, seed: seed, config: config)
    }

    /// A seed with `git → status` (bigram) and `git`/`grep` (unigram).
    private func sampleSeed() -> PredictorSeed {
        var uni = Vocabulary(depth: 4, width: 1 << 14)
        uni.record("git"); uni.record("grep")
        var bi = BigramVocabulary()
        bi.record(previous: "git", next: "status")
        return PredictorSeed(unigram: uni, bigram: bi)
    }

    // MARK: unigram

    func testLearnedUnigramSuggested() {
        var e = engine()
        for _ in 0..<3 { e.record("claude") }
        for _ in 0..<2 { e.record("crayon") }   // ≥ confidenceFloor so both qualify
        XCTAssertEqual(e.suggestions(forPrefix: "c"), ["claude", "crayon"])
    }

    func testSeedFillsUnigramWhenLearnedEmpty() {
        let e = engine(seed: sampleSeed())
        XCTAssertEqual(e.suggestions(forPrefix: "g"), ["git", "grep"])
    }

    func testSeedlessEngineStillSuggestsFromLearned() {
        var e = engine()   // no seed
        for _ in 0..<2 { e.record("deploy") }
        XCTAssertEqual(e.suggestions(forPrefix: "d"), ["deploy"])
    }

    // MARK: bigram (next-token)

    func testLearnedNextTokenSuggested() {
        var e = engine()
        for _ in 0..<3 { e.record("status", after: "git") }
        for _ in 0..<2 { e.record("commit", after: "git") }   // ≥ floor
        XCTAssertEqual(e.suggestions(forPrefix: "", after: "git"), ["status", "commit"])
    }

    func testSeedNextTokenSurfacesWhenUserHasNoHistory() {
        let e = engine(seed: sampleSeed())
        XCTAssertEqual(e.suggestions(forPrefix: "", after: "git"), ["status"])
    }

    func testLearnedNextTokenOutranksSeed() {
        // User's git→commit (3, ≥ floor) should appear; seed git→status fills.
        var e = engine(seed: sampleSeed())
        for _ in 0..<3 { e.record("commit", after: "git") }
        XCTAssertEqual(e.suggestions(forPrefix: "", after: "git"), ["commit", "status"])
    }

    func testEmptyPreviousFallsBackToUnigram() {
        // An empty `previous` (start of line) must query the unigram axis, not a
        // dead bigram axis that would return nothing.
        var e = engine()
        for _ in 0..<2 { e.record("deploy") }
        XCTAssertEqual(e.suggestions(forPrefix: "d", after: ""), ["deploy"])
    }

    // MARK: privacy (write-time)

    func testExcludedTokenNeverLearned() {
        var e = engine()
        for _ in 0..<5 { e.record("mypassword") }   // matches default .contains("password")
        XCTAssertEqual(e.suggestions(forPrefix: "my"), [],
                       "an excluded token must be learned nowhere")
    }

    func testExcludedPreviousSuppressesAdjacencyButNotUnigram() {
        var e = engine()
        // previous is excluded ("secret-token"); next ("deploy") is fine.
        for _ in 0..<2 { e.record("deploy", after: "secret-token") }
        XCTAssertEqual(e.suggestions(forPrefix: "d"), ["deploy"],
                       "the non-excluded next token is still a valid unigram")
        XCTAssertEqual(e.suggestions(forPrefix: "", after: "secret-token"), [],
                       "no adjacency may be learned from an excluded previous token")
    }

    func testExcludedNextTokenSuppressesBothAxes() {
        var e = engine()
        for _ in 0..<3 { e.record("apitoken", after: "curl") }   // "token" excluded
        XCTAssertEqual(e.suggestions(forPrefix: "api"), [])
        XCTAssertEqual(e.suggestions(forPrefix: "", after: "curl"), [])
    }

    // MARK: lifecycle

    func testRolloverPreservesInWindowSuggestions() {
        var e = engine()
        for _ in 0..<2 { e.record("deploy") }
        e.rollover()
        XCTAssertEqual(e.suggestions(forPrefix: "d"), ["deploy"],
                       "sealed-day learning still suggests within the window")
    }

    func testStateExposesLearnedForPersistence() {
        var e = engine()
        e.record("status", after: "git")
        let state = e.state
        // The exposed state round-trips through the rolling stores' own query path.
        XCTAssertEqual(state.bigram.candidates(after: "git", window: .days30).map { $0.token },
                       ["status"])
    }

    func testTopKConfigCapsResults() {
        var e = engine(config: SuggestionConfig(topK: 2))
        e.record("xa", count: 5); e.record("xb", count: 4); e.record("xc", count: 3)
        XCTAssertEqual(e.suggestions(forPrefix: "x"), ["xa", "xb"])
    }

    // MARK: output-token harvesting

    func testHarvestedOutputLeadsSuggestions() {
        var e = engine()
        for _ in 0..<5 { e.record("status", after: "git") }   // strong learned
        e.harvest(output: "deploy.log status.txt")            // just-seen output
        // The harvested "status.txt" leads even over a frequent learned token.
        XCTAssertEqual(e.suggestions(forPrefix: "st").first, "status.txt")
    }

    func testHarvestedAndLearnedMergeDeduped() {
        var e = engine(config: SuggestionConfig(topK: 3))
        for _ in 0..<2 { e.record("stage") }
        e.harvest(output: "stash-pop")
        let s = e.suggestions(forPrefix: "st")
        XCTAssertEqual(s, ["stash-pop", "stage"], "harvested leads, learned fills, no dup")
    }

    func testHarvestRespectsPrivacyFilter() {
        var e = engine()
        e.harvest(output: "build.log secret-aikey")   // "secret" excluded by default
        XCTAssertEqual(e.suggestions(forPrefix: "secret"), [],
                       "an excluded output token must never be harvested or surfaced")
        XCTAssertEqual(e.suggestions(forPrefix: "build"), ["build.log"])
    }

    func testHarvestedLeadsNextTokenAxisToo() {
        var e = engine()
        e.harvest(output: "config.yaml")
        // `cat <harvested-file>`: after "cat", the harvested filename leads.
        XCTAssertEqual(e.suggestions(forPrefix: "config", after: "cat").first, "config.yaml")
    }

    func testNonPositiveTopKReturnsEmptyEvenWithHarvest() {
        // The harvest path is not otherwise capped; topK <= 0 must still yield [].
        var e = engine(config: SuggestionConfig(topK: 0))
        e.harvest(output: "a1 a2 a3")
        XCTAssertEqual(e.suggestions(forPrefix: "a"), [],
                       "topK <= 0 must return nothing, not the whole harvest")
    }

    func testClearHarvestDropsOutputTokens() {
        var e = engine()
        e.harvest(output: "ephemeral.tmp")
        XCTAssertEqual(e.suggestions(forPrefix: "eph"), ["ephemeral.tmp"])
        e.clearHarvest()
        XCTAssertEqual(e.suggestions(forPrefix: "eph"), [])
    }
}
