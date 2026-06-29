// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Loupe character-window clamping around the cursor.
final class LoupeWindowTests: XCTestCase {
    private let row = Array("abcdefghij") // 10 chars, indices 0…9

    func testCentersWindowOnCursor() {
        let r = loupeText(rowChars: row, cursorCol: 5, span: 4) // half=2 → start 3
        XCTAssertEqual(r.text, "defg")
        XCTAssertEqual(r.caretIndex, 2)
    }

    func testClampsAtLeftEdge() {
        let r = loupeText(rowChars: row, cursorCol: 0, span: 4)
        XCTAssertEqual(r.text, "abcd")
        XCTAssertEqual(r.caretIndex, 0)
    }

    func testClampsAtRightEdge() {
        let r = loupeText(rowChars: row, cursorCol: 9, span: 4) // start clamps to 6
        XCTAssertEqual(r.text, "ghij")
        XCTAssertEqual(r.caretIndex, 3)
    }

    func testCursorAtEndOfLine() {
        let r = loupeText(rowChars: row, cursorCol: 10, span: 4) // caret past last char
        XCTAssertEqual(r.text, "ghij")
        XCTAssertEqual(r.caretIndex, 4)
    }

    func testRowShorterThanSpan() {
        let r = loupeText(rowChars: Array("ab"), cursorCol: 1, span: 4)
        XCTAssertEqual(r.text, "ab")
        XCTAssertEqual(r.caretIndex, 1)
    }

    func testEmptyRowAndZeroSpan() {
        XCTAssertEqual(loupeText(rowChars: [], cursorCol: 0, span: 4).text, "")
        XCTAssertEqual(loupeText(rowChars: row, cursorCol: 5, span: 0).text, "")
    }
}
