// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Learned-word fade clock and literal cap (Core tier, privacy P-H2). Every test
/// drives `PredictorEngine.record` so the wiring is covered, not only the state.
/// Words are recorded with `accepted: true` so they graduate (and become literals)
/// on the first occurrence, bypassing the 3-context deferral.
final class LearnedFadeTests: XCTestCase {
    private func engine() -> PredictorEngine {
        PredictorEngine(learned: .empty, english: nil, commands: nil)
    }

    private func learn(_ e: inout PredictorEngine, _ word: String, times: Int) {
        for _ in 0..<times { e.record(word, accepted: true) }
    }

    /// A distinct consonant-only lowercase token for `n` (5 letters over 8
    /// consonants: 32,768 values). No vowels keeps it clear of every word-based
    /// privacy rule and low-entropy enough to pass the entropy filter.
    private func token(_ n: Int) -> String {
        let letters = Array("bcdfghjk")
        var n = n
        var out = ""
        for _ in 0..<5 {
            out.append(letters[n % letters.count])
            n /= letters.count
        }
        return out
    }

    private func recordDistinct(_ e: inout PredictorEngine, count: Int, from start: Int = 0) {
        for i in start..<(start + count) { e.record(token(i), accepted: true) }
    }

    // MARK: fade clock

    func testHalfLifeAfter25000Words() {
        var e = engine()
        learn(&e, "needle", times: 8)
        learn(&e, "filler", times: 25_000)
        XCTAssertEqual(e.state.unigram.estimate("needle"), 4, accuracy: 0.01)
    }

    func testNoStepAt999() {
        var e = engine()
        learn(&e, "needle", times: 8)
        learn(&e, "filler", times: 991)
        XCTAssertEqual(e.state.wordsSinceFade, 999)
        XCTAssertEqual(e.state.unigram.estimate("needle"), 8, accuracy: 1e-6)
    }

    func testOneStepAt1000() {
        var e = engine()
        learn(&e, "needle", times: 8)
        learn(&e, "filler", times: 992)
        XCTAssertEqual(e.state.wordsSinceFade, 0)
        XCTAssertEqual(e.state.unigram.estimate("needle"), 8 * LearnedState.fadeFactor, accuracy: 1e-4)
    }

    func testIdleChangesNothing() {
        var e = engine()
        learn(&e, "needle", times: 8)
        let before = e.state
        var after = before
        after.noteLearned(words: 0)
        XCTAssertEqual(after, before)
    }

    func testNoteLearnedAppliesWholeStepsAndCarriesRemainder() {
        var state = LearnedState.empty
        state.unigram.record("needle", count: 8)
        state.noteLearned(words: 2_500)
        XCTAssertEqual(state.wordsSinceFade, 500)
        let twoSteps = 8 * LearnedState.fadeFactor * LearnedState.fadeFactor
        XCTAssertEqual(state.unigram.estimate("needle"), twoSteps, accuracy: 1e-4)
    }

    func testSingleUseBigramPrunedWithTheSameClock() {
        var e = engine()
        e.record("alpha", accepted: true)
        e.record("beta", after: "alpha", accepted: true)
        learn(&e, "filler", times: 83_000 - 2)  // 83,000 learned words total
        XCTAssertEqual(e.state.bigram.candidates(after: "alpha").map(\.token), ["beta"])
        learn(&e, "filler", times: 1_000)  // 84,000 total
        XCTAssertEqual(e.state.bigram.candidates(after: "alpha").map(\.token), [])
    }

    func testSingleUsePrunedAfterFading() {
        var e = engine()
        e.record("rare", accepted: true)
        learn(&e, "filler", times: 83_000 - 1)  // 83,000 learned words total
        XCTAssertTrue(e.state.unigram.containsLiteral("rare"), "2^(-83/25) = 0.1003 >= 0.1")
        learn(&e, "filler", times: 1_000)  // 84,000 total
        XCTAssertFalse(e.state.unigram.containsLiteral("rare"), "2^(-84/25) = 0.0975 < 0.1")
        XCTAssertTrue(e.state.unigram.containsLiteral("filler"))
    }

    // MARK: literal cap

    func testBelowCapLiteralSetUntouched() {
        var e = engine()
        recordDistinct(&e, count: 19_999)
        XCTAssertEqual(e.learnedWordCount, 19_999)
    }

    func testCapTriggersOnceToTarget() {
        var e = engine()
        recordDistinct(&e, count: 20_001)
        XCTAssertEqual(e.learnedWordCount, 18_000)
        recordDistinct(&e, count: 1, from: 20_001)
        XCTAssertEqual(e.learnedWordCount, 18_001)
    }

    func testEnforceCapDropsLowestEstimatesFirst() {
        var state = LearnedState.empty
        state.unigram.record("keeper", count: 50)
        for i in 0..<20_000 { state.unigram.record(token(i), count: 1) }
        XCTAssertEqual(state.unigram.literalCount, 20_001)
        state.enforceCap()
        XCTAssertEqual(state.unigram.literalCount, 18_000)
        XCTAssertTrue(state.unigram.containsLiteral("keeper"))
    }
}
