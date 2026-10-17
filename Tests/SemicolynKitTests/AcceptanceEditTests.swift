// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import SemicolynKit

final class AcceptanceEditTests: XCTestCase {
    func e(_ t: String, _ k: Suggestion.Kind, _ line: String) -> AcceptanceEdit? {
        acceptanceEdit(for: Suggestion(text: t, kind: k, score: 1), line: line)
    }
    func testCompletion() {
        XCTAssertEqual(e("status", .completion, "git sta"), AcceptanceEdit(backspaces: 0, text: "tus "))
        XCTAssertEqual(e("Linux", .completion, "lin"), AcceptanceEdit(backspaces: 3, text: "Linux "))
        XCTAssertEqual(e("including", .completion, "(inc"), AcceptanceEdit(backspaces: 0, text: "luding "))
        XCTAssertEqual(e("~/projects/", .completion, "cd ~/pr"), AcceptanceEdit(backspaces: 0, text: "ojects/"))
        XCTAssertEqual(e("--output=", .completion, "x --out"), AcceptanceEdit(backspaces: 0, text: "put="))
    }
    func testCorrectionAndNextWord() {
        XCTAssertEqual(e("the", .correction, "teh"), AcceptanceEdit(backspaces: 3, text: "the "))
        XCTAssertEqual(e("status", .nextWord, "git "), AcceptanceEdit(backspaces: 0, text: "status "))
        XCTAssertEqual(e("status", .nextWord, "git"), AcceptanceEdit(backspaces: 0, text: " status "))
    }
    func testRejections() {
        XCTAssertNil(e("status", .completion, "git status"))   // nothing left to add
        XCTAssertNil(e("ok", .completion, "me,"))              // after trailing punctuation
        XCTAssertNil(e("the", .correction, "x "))              // nothing typed to correct
    }
    func testStaleChipRejected() {
        XCTAssertNil(e("status", .completion, "git sx"))       // line moved on since the refresh
    }
    func testKeystrokesSaved() {
        XCTAssertEqual(keystrokesSaved(AcceptanceEdit(backspaces: 0, text: "tus ")), 3)
        XCTAssertEqual(keystrokesSaved(AcceptanceEdit(backspaces: 3, text: "Linux ")), 8)
    }
    func testChipsThatFit() {
        XCTAssertEqual(chipsThatFit(widths: [50, 40, 30], available: 100, spacing: 5), 2)
        XCTAssertEqual(chipsThatFit(widths: [50, 40, 30], available: 95, spacing: 5), 2)   // exact fit
        XCTAssertEqual(chipsThatFit(widths: [50, 40, 30], available: 94, spacing: 5), 1)
        XCTAssertEqual(chipsThatFit(widths: [50, 40, 30], available: 130, spacing: 5), 3)
        XCTAssertEqual(chipsThatFit(widths: [200], available: 100, spacing: 5), 1)
        XCTAssertEqual(chipsThatFit(widths: [], available: 100, spacing: 5), 0)
    }
    func testStaleGuard() {
        XCTAssertTrue(shouldApplyRefresh(seq: 0, lastApplied: 5))
        XCTAssertTrue(shouldApplyRefresh(seq: 6, lastApplied: 5))
        XCTAssertFalse(shouldApplyRefresh(seq: 5, lastApplied: 5))
        XCTAssertFalse(shouldApplyRefresh(seq: 4, lastApplied: 5))
    }
}
