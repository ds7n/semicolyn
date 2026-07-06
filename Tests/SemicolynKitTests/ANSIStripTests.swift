// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Stripping ANSI/CSI/OSC escape sequences from harvested terminal output so the
/// predictor learns visible words, not color codes. Regression for the device bug
/// where SGR sequences (`\u{1b}[38;2;…m`) leaked into the suggestion vocabulary.
final class ANSIStripTests: XCTestCase {
    // The exact device case: a truecolor SGR prompt around a word.
    func testStripsTruecolorSGRAroundWord() {
        let raw = "\u{1b}[38;2;122;162;247muser\u{1b}[0m"
        XCTAssertEqual(stripANSI(raw), "user")
    }

    // CSI erase-in-line (`\u{1b}[K`) and a bare CR are removed.
    func testStripsEraseAndCarriageReturn() {
        XCTAssertEqual(stripANSI("\u{15}\u{1b}[K\rhello"), "hello")
    }

    // Plain text with no escapes is unchanged.
    func testPlainTextUnchanged() {
        XCTAssertEqual(stripANSI("ls -la /tmp"), "ls -la /tmp")
    }

    // OSC (window-title) sequence terminated by BEL is removed, surrounding text kept.
    func testStripsOSCSequence() {
        XCTAssertEqual(stripANSI("a\u{1b}]0;my title\u{07}b"), "ab")
    }

    // A multi-parameter CSI (cursor move) is removed.
    func testStripsCursorMoveCSI() {
        XCTAssertEqual(stripANSI("\u{1b}[2;5Hprompt"), "prompt")
    }

    // Newlines/tabs (real token separators) are preserved for the caller to split on.
    func testPreservesWhitespaceSeparators() {
        XCTAssertEqual(stripANSI("foo\nbar\tbaz"), "foo\nbar\tbaz")
    }
}
