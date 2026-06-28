// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

/// `MacroTemplate.parseBody` — turns a parameterized template into a
/// `[MacroBodyElement]` body, recognizing `${name}` / `${name:default}` placeholders
/// alongside the existing `{chord}` / literal tokens. Untrusted text: equivalence
/// partitions per token class + a negative case asserting the SPECIFIC error for each
/// malformed class (keybar-customization spec "Optional placeholders").
final class MacroPlaceholderTests: XCTestCase {
    private func body(_ s: String) throws -> [MacroBodyElement] { try MacroTemplate.parseBody(s) }
    private func ev(_ c: Character) -> MacroBodyElement { .event(MacroEvent(key: .char(c))) }
    private func ph(_ n: String, _ d: String? = nil) -> MacroBodyElement {
        .placeholder(MacroPlaceholder(name: n, defaultValue: d))
    }

    // MARK: - Valid partitions

    func testBarePlaceholderHasNoDefault() throws {
        XCTAssertEqual(try body("${host}"), [ph("host")])
    }

    func testPlaceholderWithDefault() throws {
        XCTAssertEqual(try body("${dir:/tmp}"), [ph("dir", "/tmp")])
    }

    func testPlaceholderWithEmptyDefaultIsEmptyStringNotNil() throws {
        // `${x:}` differs from `${x}` — an explicit empty default, not "prompt".
        XCTAssertEqual(try body("${x:}"), [ph("x", "")])
    }

    func testNameAllowsUnderscoreAndDigits() throws {
        XCTAssertEqual(try body("${a_b1}"), [ph("a_b1")])
    }

    func testOnlyFirstColonSplitsNameFromDefault() throws {
        XCTAssertEqual(try body("${url:http://x}"), [ph("url", "http://x")])
    }

    func testLiteralTextMixedWithPlaceholder() throws {
        XCTAssertEqual(try body("a${x}b"), [ev("a"), ph("x"), ev("b")])
    }

    func testDollarNotFollowedByBraceIsLiteral() throws {
        XCTAssertEqual(try body("$5"), [ev("$"), ev("5")])
    }

    func testPlaceholderThenChordInterleave() throws {
        XCTAssertEqual(
            try body("${x}{Ctrl+R}"),
            [ph("x"), .event(MacroEvent(key: .char("R"), modifiers: KeyModifiers(control: true)))])
    }

    func testPlainTemplateIsAllEvents() throws {
        XCTAssertEqual(try body("ls"), [ev("l"), ev("s")])
    }

    func testEmptyTemplateIsEmptyBody() throws {
        XCTAssertEqual(try body(""), [])
    }

    // MARK: - Negative: each malformed class asserts its SPECIFIC error

    func testUnterminatedParameterErrors() {
        XCTAssertThrowsError(try body("${host")) {
            XCTAssertEqual($0 as? MacroTemplateError, .unterminatedParameter)
        }
    }

    func testEmptyParameterErrors() {
        XCTAssertThrowsError(try body("${}")) {
            XCTAssertEqual($0 as? MacroTemplateError, .emptyParameter)
        }
    }

    func testInvalidNameWithSpaceErrors() {
        XCTAssertThrowsError(try body("${a b}")) {
            XCTAssertEqual($0 as? MacroTemplateError, .invalidParameterName("a b"))
        }
    }

    func testInvalidNameWithHyphenErrors() {
        XCTAssertThrowsError(try body("${a-b}")) {
            XCTAssertEqual($0 as? MacroTemplateError, .invalidParameterName("a-b"))
        }
    }
}
