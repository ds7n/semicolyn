// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class SuggestionAcceptanceTests: XCTestCase {
    // completeWord: send only the missing suffix, existing input kept.
    func testCompleteWordSendsSuffix() {
        XCTAssertEqual(acceptanceInsertion(kind: .completeWord, current: "comm", chip: "command"), "and")
    }
    // completeWord where chip does not extend current -> nil (cannot accept).
    func testCompleteWordRejectsNonPrefix() {
        XCTAssertNil(acceptanceInsertion(kind: .completeWord, current: "xyz", chip: "command"))
    }
    // completeWord where chip == current (nothing to add) -> nil.
    func testCompleteWordRejectsEmptySuffix() {
        XCTAssertNil(acceptanceInsertion(kind: .completeWord, current: "command", chip: "command"))
    }
    // nextWord after previous (Trigger A, current empty): send word + trailing space to chain.
    func testNextWordAfterPreviousSendsWordSpace() {
        XCTAssertEqual(acceptanceInsertion(kind: .nextWordAfterPrevious, current: "", chip: "status"), "status ")
    }
    // nextWord after current (Trigger B, current is the finished word, no space yet):
    // send separating space + word + trailing space.
    func testNextWordAfterCurrentSendsSpacedWord() {
        XCTAssertEqual(acceptanceInsertion(kind: .nextWordAfterCurrent, current: "whoami", chip: "--help"), " --help ")
    }
    // Empty chip is never accepted.
    func testEmptyChipRejected() {
        XCTAssertNil(acceptanceInsertion(kind: .nextWordAfterPrevious, current: "", chip: ""))
    }
}
