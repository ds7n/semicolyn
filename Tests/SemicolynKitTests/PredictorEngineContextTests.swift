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

    // MARK: - Next-word (empty-prefix bigram) contract

    // Contract lock: `suggestions(forPrefix: "", after: <known word>)` returns that
    // word's recorded successors, ranked and capped at topK, excluding the keying
    // word itself. Learned via `record(_:after:)`, mirroring the sibling bigram
    // tests in `PredictorEngineTests.swift` (e.g. `testLearnedNextTokenSuggested`).
    func testNextWordReturnsSuccessorsForKnownWord() {
        var e = PredictorEngine(learned: .empty, seed: nil, config: cfg)
        // Graduate "status" and "commit" via 3 nil occurrences each, then record the
        // after-"git" adjacency (confidenceFloor 2 in `cfg`); status outranks commit.
        for _ in 0..<3 { e.record("status") }
        for _ in 0..<3 { e.record("status", after: "git") }
        for _ in 0..<3 { e.record("commit") }
        for _ in 0..<2 { e.record("commit", after: "git") }
        let out = e.suggestions(forPrefix: "", after: "git")
        XCTAssertEqual(out, ["status", "commit"], "known word must yield its recorded successors, ranked")
        XCTAssertTrue(out.contains("status"))
        XCTAssertFalse(out.contains("git"), "the keying word is never its own successor")
        XCTAssertLessThanOrEqual(out.count, e.config.topK)
    }

    // Negative: a word with no recorded successors returns a specific empty list,
    // not a crash and not some other word's successors.
    func testNextWordEmptyForUnknownWord() {
        var e = PredictorEngine(learned: .empty, seed: nil, config: cfg)
        for _ in 0..<3 { e.record("status") }
        for _ in 0..<3 { e.record("status", after: "git") }
        XCTAssertEqual(e.suggestions(forPrefix: "", after: "nonexistentword"), [])
    }

    // MARK: - blendedSuggestions

    // Only completions exist ("com" has longer unigram completions, no bigram
    // successors recorded after "com" itself) -> every chip is a completion, and
    // the exact typed token is excluded even if it were somehow a candidate.
    func testBlendCompletionsOnly() {
        var e = PredictorEngine(learned: .empty, seed: nil, config: cfg)
        for _ in 0..<3 { e.record("commit") }
        for _ in 0..<3 { e.record("command") }
        let out = e.blendedSuggestions(current: "com", previous: nil)
        XCTAssertFalse(out.isEmpty)
        XCTAssertTrue(out.allSatisfy { !$0.isNextWord })
        XCTAssertFalse(out.contains { $0.token == "com" })
        XCTAssertEqual(Set(["commit", "command"]).intersection(out.map { $0.token }).count, out.count,
                       "every chip must be one of the recorded completions")
    }

    // Only next-words exist ("git" is a full word with recorded successors, but
    // nothing longer than "git" itself as a unigram completion) -> every chip is
    // a next-word chip.
    func testBlendNextWordOnly() {
        var e = PredictorEngine(learned: .empty, seed: nil, config: cfg)
        for _ in 0..<3 { e.record("git") }
        for _ in 0..<3 { e.record("status") }
        for _ in 0..<3 { e.record("status", after: "git") }
        for _ in 0..<3 { e.record("commit") }
        for _ in 0..<2 { e.record("commit", after: "git") }
        let out = e.blendedSuggestions(current: "git", previous: nil)
        XCTAssertFalse(out.isEmpty)
        XCTAssertTrue(out.allSatisfy { $0.isNextWord })
        XCTAssertEqual(Set(["status", "commit"]).intersection(out.map { $0.token }).count, out.count)
    }

    // Both axes have candidates ("run" has longer completions "running"/"runner"
    // AND recorded bigram successors "tests"/"build") -> at least one of each,
    // capped at topK, no duplicate tokens.
    func testBlendBothGuaranteesOnePerGroup() {
        var e = PredictorEngine(learned: .empty, seed: nil, config: cfg)
        for _ in 0..<4 { e.record("running") }
        for _ in 0..<3 { e.record("runner") }
        for _ in 0..<3 { e.record("run") }
        for _ in 0..<4 { e.record("tests") }
        for _ in 0..<4 { e.record("tests", after: "run") }
        for _ in 0..<3 { e.record("build") }
        for _ in 0..<3 { e.record("build", after: "run") }
        let out = e.blendedSuggestions(current: "run", previous: nil)
        XCTAssertLessThanOrEqual(out.count, e.config.topK)
        XCTAssertTrue(out.contains { !$0.isNextWord }, "at least one completion")
        XCTAssertTrue(out.contains { $0.isNextWord }, "at least one next-word")
        XCTAssertEqual(Set(out.map { $0.token }).count, out.count, "no duplicate tokens")
        XCTAssertFalse(out.contains { $0.token == "run" }, "exact current excluded")
    }

    // Empty current -> empty (Trigger A handled elsewhere, not by blend).
    func testBlendEmptyCurrent() {
        let e = PredictorEngine(learned: .empty, seed: nil, config: cfg)
        XCTAssertEqual(e.blendedSuggestions(current: "", previous: "git"), [])
    }

    // allowNextWord: false must suppress the next-word axis entirely, even when
    // successors exist (same fixture as testBlendBothGuaranteesOnePerGroup, which
    // proves next-word chips DO surface when allowed) -> every chip is a
    // completion and none is a next-word chip.
    func testBlendAllowNextWordFalseSuppressesNextWordAxis() {
        var e = PredictorEngine(learned: .empty, seed: nil, config: cfg)
        for _ in 0..<4 { e.record("running") }
        for _ in 0..<3 { e.record("runner") }
        for _ in 0..<3 { e.record("run") }
        for _ in 0..<4 { e.record("tests") }
        for _ in 0..<4 { e.record("tests", after: "run") }
        for _ in 0..<3 { e.record("build") }
        for _ in 0..<3 { e.record("build", after: "run") }
        let out = e.blendedSuggestions(current: "run", previous: nil, allowNextWord: false)
        XCTAssertFalse(out.isEmpty)
        XCTAssertTrue(out.allSatisfy { !$0.isNextWord }, "next-word axis must be suppressed")
        XCTAssertFalse(out.contains { $0.token == "tests" || $0.token == "build" },
                       "next-word successors must not leak in even as completions")
    }
}
