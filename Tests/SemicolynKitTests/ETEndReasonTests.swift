// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ETEndReasonTests: XCTestCase {
    func testNilBecomesDefault() {
        XCTAssertEqual(sanitizeEndReason(nil), "connection ended")
    }

    func testEmptyBecomesDefault() {
        XCTAssertEqual(sanitizeEndReason(""), "connection ended")
    }

    func testCleanStringPassesThrough() {
        XCTAssertEqual(sanitizeEndReason("handshake rejected"), "handshake rejected")
    }

    // ANSI CSI colour sequence is stripped, surrounding text kept.
    func testCSISequenceStripped() {
        XCTAssertEqual(sanitizeEndReason("\u{1B}[31mdenied\u{1B}[0m"), "denied")
    }

    // OSC sequence (ESC ] ... BEL) is stripped whole.
    func testOSCSequenceStripped() {
        XCTAssertEqual(sanitizeEndReason("\u{1B}]0;evil\u{07}bye"), "bye")
    }

    // Carriage-return overwrite / control bytes removed (no line-overwrite attack).
    func testControlBytesStripped() {
        XCTAssertEqual(sanitizeEndReason("real\rFAKE\u{00}\u{07}"), "real FAKE")
    }

    // Newlines collapse to a single space so the reason stays one log line.
    func testNewlinesCollapsedToSpace() {
        XCTAssertEqual(sanitizeEndReason("line1\nline2"), "line1 line2")
    }

    // Angle-bracket markup stripped (no HTML/markup injection into a banner).
    func testMarkupStripped() {
        XCTAssertEqual(sanitizeEndReason("bye <b>bold</b>"), "bye bold")
    }

    // Over-long input truncated to exactly the max scalar count.
    func testOverLongTruncatedToExactMax() {
        let long = String(repeating: "a", count: 200)
        let out = sanitizeEndReason(long)
        XCTAssertEqual(out.unicodeScalars.count, etEndReasonMaxLength)
        XCTAssertEqual(out, String(repeating: "a", count: etEndReasonMaxLength))
    }

    // Unterminated tag: no closing '>' before end-of-string, everything from
    // '<' onward must be dropped so trailing markup text cannot leak.
    func testUnterminatedTagDropsToEnd() {
        XCTAssertEqual(sanitizeEndReason("oops <b broken"), "oops ")
    }

    // Script-shaped tag: whole open and close tag spans dropped, inner text kept.
    func testScriptTagStripped() {
        XCTAssertEqual(sanitizeEndReason("x<script>y</script>z"), "xyz")
    }
}
