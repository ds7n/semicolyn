// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ETControlModeDecisionTests: XCTestCase {
    /// The exact message the App renders in `.failed` on the no-control-mode path.
    /// Duplicated verbatim (not referenced from production) so the assertion pins
    /// the literal wording: if the production constant drifts, these tests fail.
    private static let expectedFailureMessage =
        "tmux control mode did not start on this host. "
        + "Check that tmux is installed and supports control mode (-CC, tmux 3.0+)."

    // ── handshake seen → .ready (no-op), the happy path ────────────────────────

    func testHandshakeSeen_isReady() {
        XCTAssertEqual(etControlModeDecision(handshakeSeen: true), .ready)
    }

    // ── handshake NOT seen → .failedNoControlMode(exact message) ───────────────

    func testHandshakeNotSeen_failsWithControlModeMessage() {
        // Asserts the SPECIFIC failure case AND its full associated string, not just
        // "it failed": if the decider returned `.ready`, or `.failedNoControlMode`
        // with a different message, this fails.
        XCTAssertEqual(
            etControlModeDecision(handshakeSeen: false),
            .failedNoControlMode(Self.expectedFailureMessage))
    }

    // ── message is non-empty and names the actionable cause (guards a silent regression) ──

    func testFailureMessage_mentionsTmuxAndControlMode() {
        guard case let .failedNoControlMode(msg) = etControlModeDecision(handshakeSeen: false) else {
            return XCTFail("expected .failedNoControlMode")
        }
        XCTAssertTrue(msg.contains("tmux"), "message should name tmux")
        XCTAssertTrue(msg.contains("control mode"), "message should name control mode")
        XCTAssertTrue(msg.contains("-CC"), "message should name the -CC flag")
    }
}
