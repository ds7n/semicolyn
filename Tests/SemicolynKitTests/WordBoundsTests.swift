// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class WordBoundsTests: XCTestCase {
    /// Helper: build isWordChar from a mask; out-of-range -> false.
    private func pred(_ mask: [Bool]) -> (Int) -> Bool {
        { i in i >= 0 && i < mask.count && mask[i] }
    }

    // Mid-word expands both directions. "  word  " -> cols 2..5 are word.
    func testMidWordExpandsBothWays() {
        let mask = [false, false, true, true, true, true, false, false] // cols 2,3,4,5
        let r = wordBounds(cols: 8, col: 4, isWordChar: pred(mask))
        XCTAssertEqual(r.start, 2)
        XCTAssertEqual(r.end, 5)
    }

    // Word at column 0 clamps left, expands right.
    func testWordAtLeftEdgeClamps() {
        let mask = [true, true, true, false, false]
        let r = wordBounds(cols: 5, col: 0, isWordChar: pred(mask))
        XCTAssertEqual(r.start, 0)
        XCTAssertEqual(r.end, 2)
    }

    // Word at last column clamps right.
    func testWordAtRightEdgeClamps() {
        let mask = [false, false, true, true, true] // cols 2,3,4 (4 = last)
        let r = wordBounds(cols: 5, col: 4, isWordChar: pred(mask))
        XCTAssertEqual(r.start, 2)
        XCTAssertEqual(r.end, 4)
    }

    // Tap on whitespace: the tapped cell is not a word char; selection is just that cell.
    func testTapOnWhitespaceIsDegenerate() {
        let mask = [true, true, false, true, true] // col 2 is space
        let r = wordBounds(cols: 5, col: 2, isWordChar: pred(mask))
        XCTAssertEqual(r.start, 2)
        XCTAssertEqual(r.end, 2)
    }

    // Single-char word bounded by spaces.
    func testSingleCharWord() {
        let mask = [false, true, false]
        let r = wordBounds(cols: 3, col: 1, isWordChar: pred(mask))
        XCTAssertEqual(r.start, 1)
        XCTAssertEqual(r.end, 1)
    }

    // All-whitespace row: degenerate at the tapped col.
    func testAllWhitespaceRow() {
        let mask = [false, false, false, false]
        let r = wordBounds(cols: 4, col: 2, isWordChar: pred(mask))
        XCTAssertEqual(r.start, 2)
        XCTAssertEqual(r.end, 2)
    }

    // Out-of-range col clamps into [0, cols-1] before expanding.
    func testColAboveRangeClamps() {
        let mask = [true, true, true, true]
        let r = wordBounds(cols: 4, col: 99, isWordChar: pred(mask))
        XCTAssertEqual(r.start, 0)   // whole row is word, clamps to last col then expands full
        XCTAssertEqual(r.end, 3)
    }

    // Whole row is a word: full-width selection.
    func testWholeRowWord() {
        let mask = [true, true, true, true]
        let r = wordBounds(cols: 4, col: 1, isWordChar: pred(mask))
        XCTAssertEqual(r.start, 0)
        XCTAssertEqual(r.end, 3)
    }
}
