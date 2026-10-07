// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// A follow-up tap (the 2nd/3rd tap of a multi-tap) must be told apart from a fresh tap so
/// plain-tmux fires the single-tap action instantly on tap 1 but never again on taps 2-3.
final class TapFollowUpTests: XCTestCase {
    func testFirstTapEverIsNotAFollowUp() {
        XCTAssertFalse(isFollowUpTap(at: 100, previousTapAt: nil))
    }

    func testJustInsideWindowIsAFollowUp() {
        XCTAssertTrue(isFollowUpTap(at: 100 + followUpTapWindow - 0.001, previousTapAt: 100))
    }

    func testExactlyAtWindowIsAFreshTap() {
        XCTAssertFalse(isFollowUpTap(at: 100 + followUpTapWindow, previousTapAt: 100))
    }

    func testJustPastWindowIsAFreshTap() {
        XCTAssertFalse(isFollowUpTap(at: 100 + followUpTapWindow + 0.001, previousTapAt: 100))
    }

    /// A clock that ran backwards (or a stale timestamp) must never swallow a real tap.
    func testNegativeIntervalIsAFreshTap() {
        XCTAssertFalse(isFollowUpTap(at: 99, previousTapAt: 100))
    }

    /// The window must cover iOS's multi-tap interval (~0.35s) so a real double-tap's
    /// second tap is always suppressed; pinned so a change is deliberate.
    func testWindowValue() {
        XCTAssertEqual(followUpTapWindow, 0.4)
    }
}
