// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Keystroke log redaction: structural-only by default; content or a VISIBLE
/// redaction marker (never a silent drop) when content logging is on.
final class KeystrokeLogDecisionTests: XCTestCase {
    // EP: content logging OFF → structural only, regardless of password flag.
    func testOffIsStructuralOnly() {
        XCTAssertEqual(
            keystrokeLogDecision(event: "insertText", content: "abc", logContent: false, isPasswordLine: false),
            "insertText(len=3)")
    }

    func testOffIsStructuralEvenOnPasswordLine() {
        XCTAssertEqual(
            keystrokeLogDecision(event: "insertText", content: "abc", logContent: false, isPasswordLine: true),
            "insertText(len=3)")
    }

    // EP: content ON, not a password line → logs the actual content.
    func testOnNonPasswordLogsContent() {
        XCTAssertEqual(
            keystrokeLogDecision(event: "insertText", content: "ls", logContent: true, isPasswordLine: false),
            "insertText(\"ls\")")
    }

    // EP: content ON, password line → VISIBLE redaction marker with length, no content.
    func testOnPasswordLineRedactsVisibly() {
        XCTAssertEqual(
            keystrokeLogDecision(event: "insertText", content: "hunter2", logContent: true, isPasswordLine: true),
            "insertText(REDACTED len=7 reason=password-line)")
    }

    // Redaction never leaks the content: assert the secret substring is absent.
    func testRedactionOmitsContent() {
        let out = keystrokeLogDecision(event: "insertText", content: "s3cr3t", logContent: true, isPasswordLine: true)
        XCTAssertFalse(out.contains("s3cr3t"), "redacted output must not contain the content: \(out)")
    }

    // BVA: empty content → len=0 structural.
    func testEmptyContentLenZero() {
        XCTAssertEqual(
            keystrokeLogDecision(event: "deleteBackward", content: "", logContent: false, isPasswordLine: false),
            "deleteBackward(len=0)")
    }
}
