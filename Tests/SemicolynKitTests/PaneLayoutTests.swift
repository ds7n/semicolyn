// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class PaneLayoutTests: XCTestCase {
    func testSingleLeaf() {
        // checksum,80x24,0,0,1
        let expected: PaneLayout = .leaf(PaneID(raw: 1), Geometry(w: 80, h: 24, x: 0, y: 0))
        XCTAssertEqual(PaneLayout.parse("bc62,80x24,0,0,1"), expected)
    }
    func testTwoColumnSplit() {
        let expected: PaneLayout = .columns([
            .leaf(PaneID(raw: 1), Geometry(w: 40, h: 24, x: 0, y: 0)),
            .leaf(PaneID(raw: 2), Geometry(w: 39, h: 24, x: 41, y: 0)),
        ], Geometry(w: 80, h: 24, x: 0, y: 0))
        XCTAssertEqual(PaneLayout.parse("e5e4,80x24,0,0{40x24,0,0,1,39x24,41,0,2}"), expected)
    }
    func testTwoRowSplit() {
        let expected: PaneLayout = .rows([
            .leaf(PaneID(raw: 1), Geometry(w: 80, h: 12, x: 0, y: 0)),
            .leaf(PaneID(raw: 2), Geometry(w: 80, h: 11, x: 0, y: 13)),
        ], Geometry(w: 80, h: 24, x: 0, y: 0))
        XCTAssertEqual(PaneLayout.parse("aaaa,80x24,0,0[80x12,0,0,1,80x11,0,13,2]"), expected)
    }
    func testNestedSplit() {
        // a column whose second child is a row split
        let expected: PaneLayout = .columns([
            .leaf(PaneID(raw: 1), Geometry(w: 40, h: 24, x: 0, y: 0)),
            .rows([
                .leaf(PaneID(raw: 2), Geometry(w: 39, h: 12, x: 41, y: 0)),
                .leaf(PaneID(raw: 3), Geometry(w: 39, h: 11, x: 41, y: 13)),
            ], Geometry(w: 39, h: 24, x: 41, y: 0)),
        ], Geometry(w: 80, h: 24, x: 0, y: 0))
        let s = "bbbb,80x24,0,0{40x24,0,0,1,39x24,41,0[39x12,41,0,2,39x11,41,13,3]}"
        XCTAssertEqual(PaneLayout.parse(s), expected)
    }
    func testUnbalancedBracketsIsNil() {
        XCTAssertNil(PaneLayout.parse("bc62,80x24,0,0{40x24,0,0,1"))
    }
    func testMissingChecksumIsNil() {
        // "80x24" before the first comma is treated as the (ignored) checksum,
        // leaving "0,0,1" which is not a valid node -> nil.
        XCTAssertNil(PaneLayout.parse("80x24,0,0,1"))
    }
    func testNonNumericFieldIsNil() {
        XCTAssertNil(PaneLayout.parse("bc62,80xZZ,0,0,1"))
    }
    func testNonAsciiDigitFieldIsNil() {
        // Arabic-Indic digits are Unicode numerics but not ASCII digits; a
        // dimension built from them must be rejected, not parsed.
        XCTAssertNil(PaneLayout.parse("bc62,\u{0664}\u{0660}x24,0,0,1"))
    }
}
