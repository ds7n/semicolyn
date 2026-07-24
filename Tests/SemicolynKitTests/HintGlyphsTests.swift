// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class HintGlyphsTests: XCTestCase {

    // MARK: hintGlyph(for:) per secondary kind (EP, exact glyph strings)

    func testLiteralGlyphIsTheLiteral() {
        XCTAssertEqual(hintGlyph(for: .literal("\\")), "\\")
        XCTAssertEqual(hintGlyph(for: .literal("_")), "_")
        XCTAssertEqual(hintGlyph(for: .literal("&")), "&")
    }
    func testPlainTabGlyph() {
        XCTAssertEqual(hintGlyph(for: .key(.tab, KeyModifiers())), "⇥")
    }
    func testShiftTabGlyph() {
        XCTAssertEqual(hintGlyph(for: .key(.tab, KeyModifiers(shift: true))), "⇤")
    }
    func testEscapeGlyph() {
        XCTAssertEqual(hintGlyph(for: .key(.escape, KeyModifiers())), "⎋")
    }
    func testEnterAndBackspaceGlyphs() {
        XCTAssertEqual(hintGlyph(for: .key(.enter, KeyModifiers())), "⏎")
        XCTAssertEqual(hintGlyph(for: .key(.backspace, KeyModifiers())), "⌫")
    }
    func testArrowGlyphs() {
        XCTAssertEqual(hintGlyph(for: .key(.arrow(.up), KeyModifiers())), "↑")
        XCTAssertEqual(hintGlyph(for: .key(.arrow(.down), KeyModifiers())), "↓")
        XCTAssertEqual(hintGlyph(for: .key(.arrow(.left), KeyModifiers())), "←")
        XCTAssertEqual(hintGlyph(for: .key(.arrow(.right), KeyModifiers())), "→")
    }
    func testFunctionKeyGlyph() {
        XCTAssertEqual(hintGlyph(for: .key(.function(5), KeyModifiers())), "F5")
    }
    func testCharGlyph() {
        XCTAssertEqual(hintGlyph(for: .key(.char("x"), KeyModifiers())), "x")
    }

    // MARK: hintGlyphs(for:) projection onto (up, down)

    func testBothPresentStacks() {
        // The | key example: up "(" over down ")".
        let s = SwipeSecondaries(up: .literal("("), down: .literal(")"))
        let g = hintGlyphs(for: s)
        XCTAssertEqual(g.up, "(")
        XCTAssertEqual(g.down, ")")
    }
    func testUpOnly() {
        // The common case: "/" -> up "\", no down.
        let g = hintGlyphs(for: SwipeSecondaries(up: .literal("\\")))
        XCTAssertEqual(g.up, "\\")
        XCTAssertNil(g.down)
    }
    func testDownOnly() {
        let g = hintGlyphs(for: SwipeSecondaries(down: .literal(";")))
        XCTAssertNil(g.up)
        XCTAssertEqual(g.down, ";")
    }
    func testNeither() {
        let g = hintGlyphs(for: SwipeSecondaries())
        XCTAssertNil(g.up)
        XCTAssertNil(g.down)
    }
}
