// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class OutputUnescapeTests: XCTestCase {
    func testPlainAsciiPassesThrough() {
        XCTAssertEqual(unescapeTmuxOutput("hello"), Array("hello".utf8))
    }
    func testEmptyIsEmpty() {
        XCTAssertEqual(unescapeTmuxOutput(""), [])
    }
    func testOctalEscapeDecodesToByte() {
        // \033 == ESC (0x1B), \015 == CR, \012 == LF
        XCTAssertEqual(unescapeTmuxOutput("\\033[0m"), [0x1B, 0x5B, 0x30, 0x6D])
        XCTAssertEqual(unescapeTmuxOutput("a\\015\\012"), [0x61, 0x0D, 0x0A])
    }
    func testEscapedBackslash() {
        XCTAssertEqual(unescapeTmuxOutput("a\\\\b"), [0x61, 0x5C, 0x62])
    }
    func testMaxOctalValue() {
        XCTAssertEqual(unescapeTmuxOutput("\\377"), [0xFF])
    }
    func testLoneTrailingBackslashIsMalformed() {
        XCTAssertNil(unescapeTmuxOutput("abc\\"))
    }
    func testNonOctalTripletIsMalformed() {
        XCTAssertNil(unescapeTmuxOutput("\\09a")) // 9 is not an octal digit
    }
    func testOutOfRangeOctalIsMalformed() {
        XCTAssertNil(unescapeTmuxOutput("\\400")) // 256 > 255
    }
    func testNonAsciiNumericIsNotAnOctalDigit() {
        // Superscript two (U+00B2) has wholeNumberValue 2 but is not an ASCII
        // octal digit; it must be rejected, not silently decoded to a byte.
        XCTAssertNil(unescapeTmuxOutput("\\\u{00B2}\u{00B2}\u{00B2}"))
        // Arabic-Indic digit three (U+0663) likewise.
        XCTAssertNil(unescapeTmuxOutput("\\\u{0663}\u{0663}\u{0663}"))
    }
}
