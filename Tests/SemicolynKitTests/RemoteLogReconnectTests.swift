// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Remote log stream reconnect backoff: 1, 2, 4, 8, 16, then capped at 30 seconds.
/// Negative attempts (a caller bug) clamp to the first delay rather than crashing.
final class RemoteLogReconnectTests: XCTestCase {
    // BVA: first attempt (min) waits 1s.
    func testAttemptZeroIsOneSecond() {
        XCTAssertEqual(remoteLogReconnectDelay(attempt: 0), 1)
    }

    // EP: doubling region, every step exact.
    func testDoublingRegion() {
        XCTAssertEqual(remoteLogReconnectDelay(attempt: 1), 2)
        XCTAssertEqual(remoteLogReconnectDelay(attempt: 2), 4)
        XCTAssertEqual(remoteLogReconnectDelay(attempt: 3), 8)
    }

    // BVA: last uncapped attempt is 16s (not 30).
    func testAttemptFourIsLastUncapped() {
        XCTAssertEqual(remoteLogReconnectDelay(attempt: 4), 16)
    }

    // BVA: first capped attempt is 30s (the doubled 32 is clamped).
    func testAttemptFiveIsCapped() {
        XCTAssertEqual(remoteLogReconnectDelay(attempt: 5), 30)
    }

    // BVA: one past the cap boundary stays at the cap.
    func testAttemptSixStaysCapped() {
        XCTAssertEqual(remoteLogReconnectDelay(attempt: 6), 30)
    }

    // Adversarial: a huge attempt count must not overflow a shift/pow into garbage.
    func testLargeAttemptStaysCapped() {
        XCTAssertEqual(remoteLogReconnectDelay(attempt: 64), 30)
        XCTAssertEqual(remoteLogReconnectDelay(attempt: Int.max), 30)
    }

    // Invalid input: negative attempts clamp to the first delay.
    func testNegativeAttemptClampsToOneSecond() {
        XCTAssertEqual(remoteLogReconnectDelay(attempt: -1), 1)
        XCTAssertEqual(remoteLogReconnectDelay(attempt: Int.min), 1)
    }
}
