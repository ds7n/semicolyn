// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

/// `MacroTemplate.parse` — turns a `{Ctrl+R}docker{Enter}` template string into a
/// `[MacroEvent]` body. Untrusted text input, so: equivalence partitions for each
/// token class, boundary values on the F-key range, and a negative case asserting
/// the SPECIFIC error for every malformed class (keybar-customization spec
/// "Template mode").
final class MacroTemplateTests: XCTestCase {
    private func parse(_ s: String) throws -> [MacroEvent] {
        try MacroTemplate.parse(s)
    }

    // MARK: - Valid partitions

    func testPlainLiteralBecomesCharEvents() throws {
        XCTAssertEqual(try parse("ls"), [MacroEvent(key: .char("l")), MacroEvent(key: .char("s"))])
    }

    func testEmptyTemplateIsEmptyBody() throws {
        XCTAssertEqual(try parse(""), [])
    }

    func testNamedKeyEnter() throws {
        XCTAssertEqual(try parse("{Enter}"), [MacroEvent(key: .enter)])
    }

    func testAllNamedKeysParse() throws {
        XCTAssertEqual(try parse("{Tab}"), [MacroEvent(key: .tab)])
        XCTAssertEqual(try parse("{Esc}"), [MacroEvent(key: .escape)])
        XCTAssertEqual(try parse("{Escape}"), [MacroEvent(key: .escape)])
        XCTAssertEqual(try parse("{Backspace}"), [MacroEvent(key: .backspace)])
        XCTAssertEqual(try parse("{Space}"), [MacroEvent(key: .char(" "))])
        XCTAssertEqual(try parse("{Up}"), [MacroEvent(key: .arrow(.up))])
        XCTAssertEqual(try parse("{Down}"), [MacroEvent(key: .arrow(.down))])
        XCTAssertEqual(try parse("{Left}"), [MacroEvent(key: .arrow(.left))])
        XCTAssertEqual(try parse("{Right}"), [MacroEvent(key: .arrow(.right))])
    }

    func testChordSingleModifier() throws {
        XCTAssertEqual(try parse("{Ctrl+R}"),
                       [MacroEvent(key: .char("R"), modifiers: KeyModifiers(control: true))])
    }

    func testChordMultipleModifiers() throws {
        XCTAssertEqual(try parse("{Ctrl+Shift+K}"),
                       [MacroEvent(key: .char("K"),
                                   modifiers: KeyModifiers(control: true, shift: true))])
    }

    func testAltAndOptionAliasesMapToOption() throws {
        let expected = [MacroEvent(key: .char("x"), modifiers: KeyModifiers(option: true))]
        XCTAssertEqual(try parse("{Alt+x}"), expected)
        XCTAssertEqual(try parse("{Option+x}"), expected)
    }

    func testModifierAndKeyNamesAreCaseInsensitive() throws {
        XCTAssertEqual(try parse("{ctrl+r}"),
                       [MacroEvent(key: .char("r"), modifiers: KeyModifiers(control: true))])
        XCTAssertEqual(try parse("{ENTER}"), [MacroEvent(key: .enter)])
    }

    func testMixedTemplatePreservesOrder() throws {
        XCTAssertEqual(
            try parse("{Ctrl+R}git{Enter}"),
            [
                MacroEvent(key: .char("R"), modifiers: KeyModifiers(control: true)),
                MacroEvent(key: .char("g")),
                MacroEvent(key: .char("i")),
                MacroEvent(key: .char("t")),
                MacroEvent(key: .enter),
            ])
    }

    func testEscapedBracesBecomeLiteralChars() throws {
        XCTAssertEqual(try parse("{{}}"),
                       [MacroEvent(key: .char("{")), MacroEvent(key: .char("}"))])
    }

    // MARK: - F-key boundary values (valid F1..F12; F0 and F13 invalid)

    func testFKeyLowerBoundF1() throws {
        XCTAssertEqual(try parse("{F1}"), [MacroEvent(key: .function(1))])
    }

    func testFKeyUpperBoundF12() throws {
        XCTAssertEqual(try parse("{F12}"), [MacroEvent(key: .function(12))])
    }

    func testFKeyBelowRangeF0Rejected() {
        assertThrows(parse: "{F0}", error: .unknownKey("F0"))
    }

    func testFKeyAboveRangeF13Rejected() {
        assertThrows(parse: "{F13}", error: .unknownKey("F13"))
    }

    // MARK: - Invalid partitions (assert the SPECIFIC error)

    func testUnterminatedPlaceholder() {
        assertThrows(parse: "{Ctrl+R", error: .unterminatedPlaceholder)
    }

    func testEmptyPlaceholder() {
        assertThrows(parse: "a{}b", error: .emptyPlaceholder)
    }

    func testUnknownKey() {
        assertThrows(parse: "{Frobnicate}", error: .unknownKey("Frobnicate"))
    }

    func testDanglingModifier() {
        assertThrows(parse: "{Ctrl+}", error: .danglingModifier)
    }

    func testUnknownModifier() {
        assertThrows(parse: "{Cmd+A}", error: .unknownModifier("Cmd"))
    }

    func testStrayCloseBrace() {
        assertThrows(parse: "a}b", error: .unexpectedCloseBrace)
    }

    private func assertThrows(parse template: String, error expected: MacroTemplateError,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try MacroTemplate.parse(template), file: file, line: line) { err in
            XCTAssertEqual(err as? MacroTemplateError, expected,
                           "wrong error for template '\(template)'", file: file, line: line)
        }
    }
}
