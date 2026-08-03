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

/// Sub-word selection breaks on a character-class change (word / space / punct), matching
/// iOS/desktop double-click. Fixes the "double-tap grabbed the whole .claude-staging-oauth.json"
/// bug: double-tapping `staging` selects `staging`, not the whole token.
final class SubWordBoundsTests: XCTestCase {
    // Model the string ".claude-staging-oauth.json" as a class function over columns.
    private func classer(_ s: String) -> (Int) -> CharClass {
        let chars = Array(s)
        return { i in
            guard i >= 0, i < chars.count else { return .space }
            let c = chars[i]
            if c == " " || c == "\t" || c == "\0" { return .space }
            if SemicolynKit.selectionPunctuation.contains(c) { return .punct }
            return .word
        }
    }

    // EP: a word run is bounded by the surrounding punctuation.
    func testWordRunBreaksOnPunct() {
        let s = ".claude-staging-oauth.json"     // indices: 0='.' 1..6='claude' 7='-' 8..14='staging' ...
        let (start, end) = SemicolynKit.subWordBounds(cols: s.count, col: 10, classOf: classer(s))
        XCTAssertEqual(start, 8)   // 's' of staging
        XCTAssertEqual(end, 14)    // 'g' of staging
    }

    // EP: tapping ON punctuation selects the contiguous punct run (here a single '-').
    func testPunctRun() {
        let s = ".claude-staging-oauth.json"
        let (start, end) = SemicolynKit.subWordBounds(cols: s.count, col: 7, classOf: classer(s))
        XCTAssertEqual(start, 7)
        XCTAssertEqual(end, 7)
    }

    // EP: tapping a space yields a degenerate single-cell range.
    func testSpaceDegenerate() {
        let s = "ab cd"
        let (start, end) = SemicolynKit.subWordBounds(cols: s.count, col: 2, classOf: classer(s))
        XCTAssertEqual(start, 2)
        XCTAssertEqual(end, 2)
    }

    // BVA: first column, word run to the left edge.
    func testFirstColumnWord() {
        let s = "abc def"
        let (start, end) = SemicolynKit.subWordBounds(cols: s.count, col: 0, classOf: classer(s))
        XCTAssertEqual(start, 0)
        XCTAssertEqual(end, 2)
    }

    // BVA: last column, word run to the right edge.
    func testLastColumnWord() {
        let s = "abc def"
        let (start, end) = SemicolynKit.subWordBounds(cols: s.count, col: 6, classOf: classer(s))
        XCTAssertEqual(start, 4)
        XCTAssertEqual(end, 6)
    }

    // BVA: col past cols clamps in.
    func testColClamped() {
        let s = "abc"
        let (start, end) = SemicolynKit.subWordBounds(cols: s.count, col: 99, classOf: classer(s))
        XCTAssertEqual(start, 0)
        XCTAssertEqual(end, 2)
    }
}
