// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Macro → terminal bytes: each event runs through the same `encodeKey` codec as
/// a live keypress, concatenated in order. Boundary on the cursor-key-mode flag
/// for arrows.
final class MacroExpansionTests: XCTestCase {
    func testEmptyBodyEncodesToNoBytes() {
        XCTAssertEqual(encodeMacroBody([], applicationCursorKeys: false), [])
    }

    func testCharsConcatenateInOrder() {
        let body = [MacroEvent(key: .char("a")), MacroEvent(key: .char("b"))]
        XCTAssertEqual(encodeMacroBody(body, applicationCursorKeys: false), [0x61, 0x62])
    }

    func testControlModifierProducesControlByte() {
        let body = [MacroEvent(key: .char("c"), modifiers: KeyModifiers(control: true))]
        XCTAssertEqual(encodeMacroBody(body, applicationCursorKeys: false), [0x03])  // Ctrl-C
    }

    func testEnterEncodesCarriageReturn() {
        XCTAssertEqual(encodeMacroBody([MacroEvent(key: .enter)], applicationCursorKeys: false), [0x0d])
    }

    func testArrowRespectsNormalCursorMode() {
        let body = [MacroEvent(key: .arrow(.up))]
        XCTAssertEqual(encodeMacroBody(body, applicationCursorKeys: false), Array("\u{1b}[A".utf8))
    }

    func testArrowRespectsApplicationCursorMode() {
        let body = [MacroEvent(key: .arrow(.up))]
        XCTAssertEqual(encodeMacroBody(body, applicationCursorKeys: true), Array("\u{1b}OA".utf8))
    }

    func testMixedSequenceMatchesParsedTemplate() throws {
        // End-to-end: a template parses then expands to the bytes you'd type by hand.
        let body = try MacroTemplate.parse("git{Enter}")
        XCTAssertEqual(encodeMacroBody(body, applicationCursorKeys: false),
                       Array("git".utf8) + [0x0d])
    }

    func testMacroEncodedMethodMatchesFreeFunction() {
        let macro = Macro(id: MacroID("m"), name: "x",
                          body: [MacroEvent(key: .char("z")), MacroEvent(key: .enter)])
        XCTAssertEqual(macro.encoded(applicationCursorKeys: false),
                       encodeMacroBody(macro.body, applicationCursorKeys: false))
    }
}
