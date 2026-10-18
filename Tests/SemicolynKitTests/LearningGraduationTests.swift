// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import SemicolynKit

/// Core tier: engine-picked `requiredContexts` (tapped / already-learned = 1,
/// dictionary or known tool = 2, unknown = 3) and the unchanged low-confidence rule.
final class LearningGraduationTests: XCTestCase {
    func learnedLiteral(_ e: PredictorEngine, _ w: String) -> Bool { e.state.unigram.containsLiteral(w) }

    func testAcceptedWordLearnsAtOnce() throws {
        var e = try RankFixture.engine()
        e.record("zorblax", after: "x", accepted: true)
        XCTAssertTrue(learnedLiteral(e, "zorblax"))
    }

    func testUnacceptedUnknownWordDoesNotLearnAtOnce() throws {
        var e = try RankFixture.engine()
        e.record("zorblax", after: "x")
        XCTAssertFalse(learnedLiteral(e, "zorblax"))
    }

    func testDictionaryWordNeedsTwo() throws {
        var e = try RankFixture.engine()
        e.record("cat", after: "a"); XCTAssertFalse(learnedLiteral(e, "cat"))
        e.record("cat", after: "b"); XCTAssertTrue(learnedLiteral(e, "cat"))
    }

    func testDictionaryWordSameContextTwiceDoesNotGraduate() throws {
        var e = try RankFixture.engine()
        e.record("cat", after: "a"); e.record("cat", after: "a")
        XCTAssertFalse(learnedLiteral(e, "cat"))
    }

    func testCapitalizedDictionaryWordUsesFoldedLookup() throws {
        var e = try RankFixture.engine()
        e.record("Linux", after: "a"); XCTAssertFalse(learnedLiteral(e, "Linux"))
        e.record("Linux", after: "b"); XCTAssertTrue(learnedLiteral(e, "Linux"))
    }

    func testKnownToolNotInDictionaryNeedsTwo() throws {
        XCTAssertNil(try RankFixture.english().bestStoredForm(ofFolded: "ghx"))
        let tools = CommandTree(tools: [CommandNode(name: "ghx", score: 10, children: [], flags: [])],
                                pipeTargets: [])
        var e = PredictorEngine(learned: .empty, english: try RankFixture.english(), commands: tools,
                                filter: .init())
        e.record("ghx", after: "a"); XCTAssertFalse(learnedLiteral(e, "ghx"))
        e.record("ghx", after: "b"); XCTAssertTrue(learnedLiteral(e, "ghx"))
    }

    func testUnknownWordStillNeedsThree() throws {
        var e = try RankFixture.engine()
        e.record("hunter2", after: "a"); e.record("hunter2", after: "b")
        XCTAssertFalse(learnedLiteral(e, "hunter2"))
        e.record("hunter2", after: "c"); XCTAssertTrue(learnedLiteral(e, "hunter2"))
    }

    func testAlreadyLearnedRegraduatesAtOnce() throws {
        var e = try RankFixture.engine()
        for p in ["a", "b", "c"] { e.record("zork", after: p) }
        XCTAssertTrue(learnedLiteral(e, "zork"))
        e.resetGraduation()  // a new session
        let before = e.suggestions(line: "zo", lineOptedOut: false).first?.score ?? 0
        e.record("zork", after: "d")
        XCTAssertGreaterThan(e.suggestions(line: "zo", lineOptedOut: false).first?.score ?? 0, before)
    }

    func testLowConfidenceNeverStoresLiteral() throws {
        var e = try RankFixture.engine()
        e.record("zorblax", after: "x", echoConfirmed: false, accepted: true)
        XCTAssertFalse(learnedLiteral(e, "zorblax"))
    }

    func testAcceptedDoesNotBypassTokenFilter() throws {
        var e = try RankFixture.engine()
        let secret = "AKIAIOSFODNN7EXAMPLE"
        e.record(secret, after: "x", accepted: true)
        XCTAssertFalse(learnedLiteral(e, secret))
    }
}
