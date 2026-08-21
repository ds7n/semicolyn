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

    // Build a seed whose unigram vocab contains every token in `tokens`, each once.
    private func seed(tokens: [String]) -> PredictorSeed {
        var uni = Vocabulary(depth: 4, width: 1 << 12)
        for token in tokens { uni.record(token) }
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

    // MARK: - isTerminalWord (Trigger B gate, spec addendum 2026-08-21 Fix 1)

    // Known token, and no longer token extends it -> terminal.
    func testTerminalWordKnownAndNothingLonger() {
        let e = PredictorEngine(learned: .empty, seed: seed(tokens: ["whoami"]), config: cfg)
        XCTAssertTrue(e.isTerminalWord("whoami"))
    }

    // Known token, but a longer token sharing its prefix exists -> not terminal
    // (the user may still be typing "island").
    func testTerminalWordKnownButExtensible() {
        let e = PredictorEngine(learned: .empty, seed: seed(tokens: ["is", "island"]), config: cfg)
        XCTAssertFalse(e.isTerminalWord("is"))
    }

    // Unknown token: only longer tokens sharing its prefix are in the vocab, the
    // bare token itself was never recorded -> not terminal.
    func testTerminalWordUnknown() {
        let e = PredictorEngine(learned: .empty, seed: seed(tokens: ["type", "typescript"]), config: cfg)
        XCTAssertFalse(e.isTerminalWord("ty"))
    }

    // Union across sources: known in the CLI seed, extended only in the prose seed
    // -> still not terminal (the union of ALL sources decides, not just one).
    func testTerminalWordUnionAcrossSources() {
        let e = PredictorEngine(learned: .empty, seed: seed(tokens: ["is"]),
                                proseSeed: seed(tokens: ["island"]), config: cfg)
        XCTAssertFalse(e.isTerminalWord("is"))
    }

    // Empty string is never a terminal word, regardless of vocab contents.
    func testTerminalWordEmpty() {
        let e = PredictorEngine(learned: .empty, seed: seed(tokens: ["whoami"]), config: cfg)
        XCTAssertFalse(e.isTerminalWord(""))
    }
}
