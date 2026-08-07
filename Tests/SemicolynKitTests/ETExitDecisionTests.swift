// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ETExitDecisionTests: XCTestCase {
    // ── first-frame seen → always .dismiss (graceful), reason ignored ──────────

    func testFirstFrameSeen_nilReason_dismisses() {
        XCTAssertEqual(etExitDecision(reason: nil, sawFirstFrame: true), .dismiss)
    }

    func testFirstFrameSeen_benignReason_dismisses() {
        XCTAssertEqual(etExitDecision(reason: "session ended", sawFirstFrame: true), .dismiss)
    }

    func testFirstFrameSeen_dropReason_dismisses() {
        // A mid-session network drop after a real session still dismisses gracefully.
        XCTAssertEqual(etExitDecision(reason: "connection lost", sawFirstFrame: true), .dismiss)
    }

    func testFirstFrameSeen_adversarialReasonIgnored_dismisses() {
        // The untrusted reason is NOT consulted on the dismiss path.
        XCTAssertEqual(etExitDecision(reason: "\u{1B}[31mboom\u{1B}[0m", sawFirstFrame: true), .dismiss)
    }

    // ── first-frame never seen → .handshakeFailed(sanitized reason) ────────────

    func testNoFirstFrame_nilReason_failsWithSanitizeDefault() {
        // sanitizeEndReason(nil) == "connection ended"
        XCTAssertEqual(etExitDecision(reason: nil, sawFirstFrame: false),
                       .handshakeFailed("connection ended"))
    }

    func testNoFirstFrame_plainReason_failsWithReason() {
        XCTAssertEqual(etExitDecision(reason: "handshake rejected", sawFirstFrame: false),
                       .handshakeFailed("handshake rejected"))
    }

    func testNoFirstFrame_ansiControlReason_failsWithSanitizedValue() {
        // Proves sanitization is wired through the decider: ANSI SGR are stripped,
        // trailing CRLF collapses to a single space. If the decider forgot to call
        // sanitizeEndReason, this asserts the wrong (raw) string and fails.
        XCTAssertEqual(etExitDecision(reason: "\u{1B}[1mfail\u{1B}[0m\r\n", sawFirstFrame: false),
                       .handshakeFailed("fail "))
    }
}
