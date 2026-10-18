// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ANSIByteFilterTests: XCTestCase {
    func b(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testStripsSequences() {
        var f = ANSIByteFilter()
        XCTAssertEqual(f.filter(b("a\u{1b}[1;32mb\u{1b}]0;title\u{07}c\u{1b}(Bd")), b("abcd"))
    }

    func testSequenceSplitAcrossChunks() {
        var f = ANSIByteFilter()
        XCTAssertEqual(f.filter(b("x\u{1b}[3")), b("x"))
        XCTAssertEqual(f.filter(b("1my")), b("y"))
    }

    func testUnterminatedOSCEndsAtNewline() {
        var f = ANSIByteFilter()
        XCTAssertEqual(f.filter([0x1b, UInt8(ascii: "]")] + Array(repeating: UInt8(ascii: "a"), count: 600) + b("\nz")), b("\nz"))
    }

    func testControlByteAbortsCSI() {
        var f = ANSIByteFilter()
        XCTAssertEqual(f.filter(b("\u{1b}[12\rok")), b("\rok"))
    }

    func testOSCEndsAtStringTerminator() {
        var f = ANSIByteFilter()
        XCTAssertEqual(f.filter(b("a\u{1b}]0;t\u{1b}\\b")), b("ab"))
    }

    func testDCSAndOtherStringSequencesEndAtBEL() {
        for intro in ["P", "X", "^", "_"] {
            var f = ANSIByteFilter()
            XCTAssertEqual(f.filter(b("a\u{1b}\(intro)payload\u{07}b")), b("ab"), "intro \(intro)")
        }
    }

    func testEscapeWithIntermediateAndFinal() {
        var f = ANSIByteFilter()
        // ESC ( B charset select, ESC = keypad mode (no intermediate), ESC # 8.
        XCTAssertEqual(f.filter(b("1\u{1b}(B2\u{1b}=3\u{1b}#84")), b("1234"))
    }

    func testEscapeSplitBetweenEscAndFinal() {
        var f = ANSIByteFilter()
        XCTAssertEqual(f.filter(b("a\u{1b}")), b("a"))
        XCTAssertEqual(f.filter(b("(Bb")), b("b"))
    }

    func testPlainAndUTF8BytesPassThrough() {
        var f = ANSIByteFilter()
        let input = b("héllo ❯ world\r\n")
        XCTAssertEqual(f.filter(input), input)
    }

    func testStateIsEquatableAndReturnsToGround() {
        var f = ANSIByteFilter()
        _ = f.filter(b("\u{1b}[1m"))
        XCTAssertEqual(f, ANSIByteFilter())
        _ = f.filter(b("\u{1b}["))
        XCTAssertNotEqual(f, ANSIByteFilter())
    }

    func testEmptyInput() {
        var f = ANSIByteFilter()
        XCTAssertEqual(f.filter([]), [])
    }

    func testESCInsideOpenStringStartsFreshSequence() {
        var f = ANSIByteFilter()
        XCTAssertEqual(f.filter(b("\u{1b}]x\u{1b}[31my")), b("y"))
        var g = ANSIByteFilter()
        XCTAssertEqual(g.filter(b("\u{1b}]0;t\u{1b}[31mPassword: ")), b("Password: "))
    }

    func testStringTerminatorsUnchanged() {
        var f = ANSIByteFilter()
        XCTAssertEqual(f.filter(b("\u{1b}]t\u{1b}\\a\u{1b}]t\u{07}b\u{1b}]t\nc")), b("ab\nc"))
    }
}
