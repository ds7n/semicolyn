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
        for _ in 0..<4 { e.record("claude") }   // 4 nil → graduates; higher count
        for _ in 0..<3 { e.record("crayon") }   // 3 nil → graduates; claude (4) strictly outranks crayon (3)
        XCTAssertEqual(e.suggestions(forPrefix: "c"), ["claude", "crayon"])
    }

    func testSeedFillsUnigramWhenLearnedEmpty() {
        let e = engine(seed: sampleSeed())
        XCTAssertEqual(e.suggestions(forPrefix: "g"), ["git", "grep"])
    }

    func testSeedlessEngineStillSuggestsFromLearned() {
        var e = engine()   // no seed
        for _ in 0..<3 { e.record("deploy") }   // ≥ 3 nil → graduates
        XCTAssertEqual(e.suggestions(forPrefix: "d"), ["deploy"])
    }

    // MARK: bigram (next-token)

    func testLearnedNextTokenSuggested() {
        var e = engine()
        // Graduate both tokens via 3 nil occurrences first; then the after-"git"
        // records persist directly (already graduated). Relative ranking preserved.
        for _ in 0..<3 { e.record("status") }
        for _ in 0..<3 { e.record("status", after: "git") }
        for _ in 0..<3 { e.record("commit") }
        for _ in 0..<2 { e.record("commit", after: "git") }   // ≥ floor; commit < status
        XCTAssertEqual(e.suggestions(forPrefix: "", after: "git"), ["status", "commit"])
    }

    func testSeedNextTokenSurfacesWhenUserHasNoHistory() {
        let e = engine(seed: sampleSeed())
        XCTAssertEqual(e.suggestions(forPrefix: "", after: "git"), ["status"])
    }

    func testLearnedNextTokenOutranksSeed() {
        // User's git→commit (3, ≥ floor) should appear; seed git→status fills.
        // Graduate commit via 3 nil first, then record 3× after "git".
        var e = engine(seed: sampleSeed())
        for _ in 0..<3 { e.record("commit") }       // graduate via nil count
        for _ in 0..<3 { e.record("commit", after: "git") }   // now persists directly
        XCTAssertEqual(e.suggestions(forPrefix: "", after: "git"), ["commit", "status"])
    }

    func testEmptyPreviousFallsBackToUnigram() {
        // An empty `previous` (start of line) must query the unigram axis, not a
        // dead bigram axis that would return nothing.
        var e = engine()
        for _ in 0..<3 { e.record("deploy") }   // ≥ 3 nil → graduates
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
        // Graduate deploy via 3 nil first so the unigram assertion holds; then record
        // the excluded-previous contexts (adjacency still suppressed by filter).
        for _ in 0..<3 { e.record("deploy") }
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
        for _ in 0..<3 { e.record("deploy") }   // ≥ 3 nil → graduates
        e.rollover()
        XCTAssertEqual(e.suggestions(forPrefix: "d"), ["deploy"],
                       "sealed-day learning still suggests within the window")
    }

    func testStateExposesLearnedForPersistence() {
        var e = engine()
        // Graduate "status" via 3 nil first so the git→status bigram persists into state.
        for _ in 0..<3 { e.record("status") }
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
        for _ in 0..<3 { e.record("stage") }   // ≥ 3 nil → graduates
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

    // MARK: - L6 frequency graduation through the engine

    /// Build a seedless engine on an empty learned state.
    private func freshEngine() -> PredictorEngine {
        PredictorEngine(learned: .empty, seed: nil)
    }

    func testTokenNotLearnedBeforeThreeDistinctContexts() {
        var e = freshEngine()
        e.record("hunter2", after: "sudo")           // ctx 1 (one-off password)
        // A single-context token must NOT be suggestable from the learned store.
        // Prefix "hunter" should yield nothing learned (no seed, no harvest).
        XCTAssertFalse(e.suggestions(forPrefix: "hunter", after: nil).contains("hunter2"))
        XCTAssertFalse(e.suggestions(forPrefix: "hunter", after: "sudo").contains("hunter2"))
    }

    func testTokenLearnedAfterThreeDistinctContexts() {
        var e = freshEngine()
        e.record("deploy", after: "git")             // ctx 1
        e.record("deploy", after: "make")            // ctx 2
        e.record("deploy", after: "npm")             // ctx 3 → graduates
        // Now "deploy" is in the learned unigram store and suggestable.
        XCTAssertTrue(e.suggestions(forPrefix: "dep", after: nil).contains("deploy"))
    }

    func testGraduationBackfillsBigramContexts() {
        var e = freshEngine()
        // Give the "git" context count 2 so the backfilled bigram clears the
        // confidenceFloor (default 2); the two other distinct contexts still drive
        // graduation (3 distinct contexts: git, make, npm).
        e.record("deploy", after: "git")             // ctx "git" (count 1)
        e.record("deploy", after: "git")             // ctx "git" (count 2, still 1 distinct)
        e.record("deploy", after: "make")            // ctx "make" (2 distinct)
        e.record("deploy", after: "npm")             // ctx "npm" (3 distinct) → graduates, backfills all
        // A backfilled bigram context at/above the floor is suggestable: after
        // "git" (count 2), "deploy" ranks.
        XCTAssertTrue(e.suggestions(forPrefix: "dep", after: "git").contains("deploy"))
    }

    func testFilterExcludedTokenNeverEntersTierOrStore() {
        var e = freshEngine()
        // ghp_ is L5-excluded → filtered at the top of record, never graduates even
        // across many distinct contexts.
        e.record("ghp_secretA", after: "a")
        e.record("ghp_secretA", after: "b")
        e.record("ghp_secretA", after: "c")
        e.record("ghp_secretA", after: "d")
        XCTAssertFalse(e.suggestions(forPrefix: "ghp", after: nil).contains("ghp_secretA"))
    }

    func testResetGraduationClearsDeferredCounts() {
        var e = freshEngine()
        e.record("deploy", after: "git")
        e.record("deploy", after: "make")
        e.resetGraduation()
        e.record("deploy", after: "npm")             // only 1 context post-reset
        XCTAssertFalse(e.suggestions(forPrefix: "dep", after: nil).contains("deploy"))
    }

    // MARK: - L7 confidence derivation + storeLiteral wiring

    func testLowConfidenceTokenNeverCompletesButCounts() {
        var engine = PredictorEngine(learned: .empty, seed: nil)
        // Graduate a token low-confidence via 3 distinct contexts (default threshold 3),
        // each with echoConfirmed:false so it graduates .low.
        for prev in ["run", "make", "just"] {
            engine.record("deploysecretxyz", count: 2, after: prev, echoConfirmed: false)
        }
        // It graduated (count is on disk) but has NO literal → never a completion.
        XCTAssertTrue(engine.suggestions(forPrefix: "deploy").isEmpty,
                      "low-confidence token must never surface as a literal completion")
    }

    func testHighConfidenceTokenCompletes() {
        var engine = PredictorEngine(learned: .empty, seed: nil)
        for prev in ["run", "make", "just"] {
            engine.record("deployprod", count: 2, after: prev, echoConfirmed: true)
        }
        XCTAssertEqual(engine.suggestions(forPrefix: "deploy"), ["deployprod"])
    }

    func testOptedOutForcesLowConfidence() {
        var engine = PredictorEngine(learned: .empty, seed: nil)
        for prev in ["run", "make", "just"] {
            engine.record("deployxyz", count: 2, after: prev, echoConfirmed: true, optedOut: true)
        }
        XCTAssertTrue(engine.suggestions(forPrefix: "deploy").isEmpty,
                      "opted-out line forces low-confidence → no literal")
    }
}
