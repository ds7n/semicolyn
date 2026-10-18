// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// PredictorEngine: Core tier (privacy rules: Critical). The runtime facade composing
/// the privacy filter, the learned stores, screen-word harvest and the single ranker.
/// Engines here carry no dictionaries unless a test says so, so every suggestion comes
/// from what the test recorded or harvested. See `2026-06-21-predictor-engine-design`.
final class PredictorEngineTests: XCTestCase {
    private func engine(filter: TokenFilter = .init(), english: WordDictionary? = nil) -> PredictorEngine {
        PredictorEngine(learned: .empty, english: english, commands: nil, filter: filter)
    }

    private func texts(_ e: PredictorEngine, _ line: String) -> [String] {
        e.suggestions(line: line, lineOptedOut: false).map(\.text)
    }

    /// The learned successors of `previous` in the persisted state, with their counts.
    private func learnedSuccessors(_ e: PredictorEngine, after previous: String) -> [String: UInt32] {
        Dictionary(uniqueKeysWithValues: e.state.bigram.candidates(after: previous, window: .days30)
            .map { ($0.token, $0.count) })
    }

    // MARK: harvest (output -> screen words)

    /// Regression (device bug): a colored prompt line harvested from output must
    /// contribute the visible WORD, never the SGR escape codes around it.
    func testHarvestStripsEscapeCodesFromColoredOutput() {
        var e = engine()
        e.harvest(output: "\u{1b}[38;2;122;162;247muser\u{1b}[0m.host\n")
        // The reset between `user` and `.host` is stripped, so they fuse into one token.
        XCTAssertEqual(texts(e, "user"), ["user.host"])
        XCTAssertEqual(texts(e, "u"), ["user.host"])
        // The SGR numeric params never became words.
        XCTAssertEqual(texts(e, "38"), [])
    }

    func testHarvestRespectsPrivacyFilter() {
        var e = engine()
        e.harvest(output: "build.log secret-aikey\n")   // "secret" excluded by default
        XCTAssertEqual(texts(e, "secret"), [], "an excluded output token must never be harvested or surfaced")
        XCTAssertEqual(texts(e, "build"), ["build.log"])
    }

    func testClearHarvestDropsOutputTokens() {
        var e = engine()
        e.harvest(output: "ephemeral.tmp\n")
        XCTAssertEqual(texts(e, "eph"), ["ephemeral.tmp"])
        e.clearHarvest()
        XCTAssertEqual(texts(e, "eph"), [])
    }

    // MARK: learned words

    func testLearnedUnigramRanksByCount() {
        var e = engine()
        for _ in 0..<4 { e.record("claude") }
        for _ in 0..<3 { e.record("clasp") }
        XCTAssertEqual(texts(e, "cl"), ["claude", "clasp"])
    }

    func testLearnedNextWordAfterPrevious() {
        var e = engine()
        for _ in 0..<3 { e.record("status") }
        for _ in 0..<3 { e.record("status", after: "git") }
        for _ in 0..<3 { e.record("commit") }
        for _ in 0..<2 { e.record("commit", after: "git") }
        XCTAssertEqual(texts(e, "git "), ["status", "commit"])
        XCTAssertEqual(learnedSuccessors(e, after: "git"), ["status": 3, "commit": 2])
    }

    // MARK: privacy (write-time)

    func testExcludedTokenNeverLearned() {
        var e = engine()
        for _ in 0..<5 { e.record("mypassword") }   // matches default .contains("password")
        XCTAssertEqual(texts(e, "my"), [], "an excluded token must be learned nowhere")
        XCTAssertFalse(e.state.unigram.containsLiteral("mypassword"))
    }

    func testExcludedPreviousSuppressesAdjacencyButNotUnigram() {
        var e = engine()
        for _ in 0..<3 { e.record("deploy") }
        for _ in 0..<2 { e.record("deploy", after: "secret-token") }
        XCTAssertEqual(texts(e, "de"), ["deploy"], "the non-excluded next token is still a valid unigram")
        XCTAssertEqual(learnedSuccessors(e, after: "secret-token"), [:],
                       "no adjacency may be learned from an excluded previous token")
    }

    func testExcludedNextTokenSuppressesBothAxes() {
        var e = engine()
        for _ in 0..<3 { e.record("apitoken", after: "curl") }   // "token" excluded
        XCTAssertEqual(texts(e, "api"), [])
        XCTAssertEqual(texts(e, "curl "), [])
        XCTAssertEqual(learnedSuccessors(e, after: "curl"), [:])
    }

    // MARK: lifecycle

    func testRolloverPreservesInWindowSuggestions() {
        var e = engine()
        for _ in 0..<3 { e.record("deploy") }
        e.rollover()
        XCTAssertEqual(texts(e, "de"), ["deploy"], "sealed-day learning still suggests within the window")
    }

    func testStateExposesLearnedForPersistence() {
        var e = engine()
        for _ in 0..<3 { e.record("status") }
        e.record("status", after: "git")
        XCTAssertEqual(learnedSuccessors(e, after: "git"), ["status": 1])
    }

    // MARK: L6 frequency graduation through the engine

    func testTokenNotLearnedBeforeThreeDistinctContexts() {
        var e = engine()
        e.record("hunter2", after: "sudo")           // one context (a one-off password)
        XCTAssertEqual(texts(e, "hunter"), [])
        XCTAssertEqual(texts(e, "sudo "), [])
        XCTAssertFalse(e.state.unigram.containsLiteral("hunter2"))
    }

    func testTokenLearnedAfterThreeDistinctContexts() {
        var e = engine()
        e.record("deploy", after: "git")
        e.record("deploy", after: "make")
        XCTAssertEqual(texts(e, "dep"), [], "two contexts are not enough for an unknown word")
        e.record("deploy", after: "npm")             // third context graduates
        XCTAssertEqual(texts(e, "dep"), ["deploy"])
    }

    func testOrdinaryWordWithClausePunctuationLearnsTrimmedLiteral() {
        var e = engine()
        for prev in ["git", "make", "npm"] { e.record("passwords,", after: prev) }
        XCTAssertEqual(texts(e, "pass"), ["passwords"])
    }

    func testGraduationBackfillsBigramContexts() {
        var e = engine()
        e.record("deploy", after: "git")
        e.record("deploy", after: "git")
        e.record("deploy", after: "make")
        e.record("deploy", after: "npm")             // graduates and backfills every context
        XCTAssertEqual(learnedSuccessors(e, after: "git"), ["deploy": 2])
        XCTAssertEqual(learnedSuccessors(e, after: "make"), ["deploy": 1])
        XCTAssertEqual(texts(e, "git "), ["deploy"])
    }

    func testFilterExcludedTokenNeverEntersTierOrStore() {
        var e = engine()
        for prev in ["a", "b", "c", "d"] { e.record("ghp_secretA", after: prev) }
        XCTAssertEqual(texts(e, "ghp"), [])
        XCTAssertFalse(e.state.unigram.containsLiteral("ghp_secretA"))
    }

    func testResetGraduationClearsDeferredCounts() {
        var e = engine()
        e.record("deploy", after: "git")
        e.record("deploy", after: "make")
        e.resetGraduation()
        e.record("deploy", after: "npm")             // only 1 context post-reset
        XCTAssertEqual(texts(e, "dep"), [])
    }

    // MARK: L7 confidence derivation + storeLiteral wiring

    func testLowConfidenceTokenNeverCompletes() {
        var e = engine()
        for prev in ["run", "make", "just"] {
            e.record("deploysecretxyz", count: 2, after: prev, echoConfirmed: false)
        }
        XCTAssertEqual(texts(e, "deploy"), [], "low-confidence token must never surface as a literal completion")
        XCTAssertFalse(e.state.unigram.containsLiteral("deploysecretxyz"))
    }

    func testHighConfidenceTokenCompletes() {
        var e = engine()
        for prev in ["run", "make", "just"] {
            e.record("deployprod", count: 2, after: prev, echoConfirmed: true)
        }
        XCTAssertEqual(texts(e, "deploy"), ["deployprod"])
    }

    func testOptedOutForcesLowConfidence() {
        var e = engine()
        for prev in ["run", "make", "just"] {
            e.record("deployxyz", count: 2, after: prev, echoConfirmed: true, optedOut: true)
        }
        XCTAssertEqual(texts(e, "deploy"), [], "opted-out line forces low confidence, so no literal")
    }

    /// Positive control for `testHighConfidenceTokenCompletes`: the only difference is a
    /// pattern-adjacent token (entropy about 3.32 bits/char, inside the soft band [3.25, 4.0)
    /// for threshold 4.0), so dropping `isPatternAdjacent` from the derivation fails this.
    func testPatternAdjacentForcesLowConfidence() {
        var e = engine(filter: TokenFilter(entropyThreshold: 4.0, entropyMinLength: 16))
        let token = "aabbccddeeffgghhiijj"
        XCTAssertFalse(e.filter.excludes(token))
        XCTAssertTrue(e.filter.isPatternAdjacent(token))
        for prev in ["run", "make", "just"] {
            e.record(token, count: 2, after: prev, echoConfirmed: true, optedOut: false)
        }
        XCTAssertEqual(texts(e, "aabb"), [])
    }

    // MARK: purgeLearned + forgetLastLine + beginLine

    func testPurgeLearnedClearsUserStateKeepsDictionary() throws {
        let english = try XCTUnwrap(WordDictionary(deserializing: try WordDictionary(
            entries: [ScoredWord(text: "sshd", score: 100)], successors: [:]).serialize()))
        var e = engine(english: english)
        for prev in ["a", "b", "c"] { e.record("sshconfig", count: 2, after: prev, echoConfirmed: true) }
        e.harvest(output: "sshkeys.txt\n")
        XCTAssertEqual(Set(texts(e, "ssh")), ["sshconfig", "sshd", "sshkeys.txt"])  // precondition
        e.purgeLearned()
        XCTAssertEqual(texts(e, "ssh"), ["sshd"], "learned and harvested words are gone; the dictionary stays")
        XCTAssertFalse(e.state.unigram.containsLiteral("sshconfig"))
    }

    func testForgetLastLineOnEngineDropsPendingLine() {
        var e = engine()
        e.beginLine()
        e.record("hunter2pass", count: 1, after: "sudo", echoConfirmed: true)   // pending, not graduated
        e.forgetLastLine()
        // Forgotten, so two more distinct contexts still leave it short of three.
        e.record("hunter2pass", count: 1, after: "x", echoConfirmed: true)
        e.record("hunter2pass", count: 1, after: "y", echoConfirmed: true)
        XCTAssertEqual(texts(e, "hunter"), [])
    }
}
