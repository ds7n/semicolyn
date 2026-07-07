// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class MoshExitDecisionTests: XCTestCase {
    // Clean exit (rc == 0 → nil reason) is a normal session end regardless of time.
    func testNilReasonIsEndedEarly() {
        XCTAssertEqual(moshExitDecision(reason: nil, elapsed: 0.05), .ended)
    }
    func testNilReasonIsEndedLate() {
        XCTAssertEqual(moshExitDecision(reason: nil, elapsed: 120), .ended)
    }

    // Nonzero exit inside the grace window = handshake never came up → SSH fallback.
    func testFailureAtZeroIsFallback() {
        XCTAssertEqual(moshExitDecision(reason: "boom", elapsed: 0), .fallbackSSH)
    }
    // Boundary: 2.999 < 3.0 → fallback.
    func testFailureJustUnderGraceIsFallback() {
        XCTAssertEqual(moshExitDecision(reason: "boom", elapsed: 2.999), .fallbackSSH)
    }
    // Boundary: exactly 3.0 is NOT inside the half-open window → crashBanner.
    func testFailureAtGraceBoundaryIsCrashBanner() {
        XCTAssertEqual(moshExitDecision(reason: "boom", elapsed: 3.0), .crashBanner)
    }
    func testFailureJustOverGraceIsCrashBanner() {
        XCTAssertEqual(moshExitDecision(reason: "boom", elapsed: 3.001), .crashBanner)
    }
    func testFailureLongAfterIsCrashBanner() {
        XCTAssertEqual(moshExitDecision(reason: "boom", elapsed: 30), .crashBanner)
    }

    // Regression pin: the EXACT device trace — reason string at 0.09s → fallback.
    func testDeviceTraceStringAtNinetyMsIsFallback() {
        XCTAssertEqual(
            moshExitDecision(reason: "Mosh connection failed — using SSH", elapsed: 0.09),
            .fallbackSSH)
    }

    // Custom grace window is honored (BVA around a 5s window).
    func testCustomGraceWindow() {
        XCTAssertEqual(moshExitDecision(reason: "boom", elapsed: 4.9, graceWindow: 5.0), .fallbackSSH)
        XCTAssertEqual(moshExitDecision(reason: "boom", elapsed: 5.0, graceWindow: 5.0), .crashBanner)
    }

    // Watchdog: no callback seen by deadline → SSH fallback; any callback → noop.
    func testWatchdogNoCallbackIsFallback() {
        XCTAssertEqual(moshWatchdogAction(sawAnyCallback: false), .fallbackSSH)
    }
    func testWatchdogAnyCallbackIsNoop() {
        XCTAssertEqual(moshWatchdogAction(sawAnyCallback: true), .noop)
    }
}
