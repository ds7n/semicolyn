// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Pure trailing-debounce policy: a burst of refresh requests collapses to one
/// recompute once the quiet window elapses with no newer request.
final class SuggestionRefreshCoalescerTests: XCTestCase {
    // Not due before the quiet window elapses.
    func testNotDueBeforeQuietWindow() {
        var c = SuggestionRefreshCoalescer(quietWindow: 0.05)
        c.requestRefresh(at: 1.00)
        XCTAssertFalse(c.isDue(at: 1.02))   // only 20ms elapsed < 50ms
    }

    // Due exactly at the boundary (quietWindow elapsed).
    func testDueAtBoundary() {
        var c = SuggestionRefreshCoalescer(quietWindow: 0.05)
        c.requestRefresh(at: 1.00)
        XCTAssertTrue(c.isDue(at: 1.05))    // exactly 50ms elapsed
    }

    // A newer request within the window resets the clock — the earlier check is no longer due.
    func testNewerRequestResetsWindow() {
        var c = SuggestionRefreshCoalescer(quietWindow: 0.05)
        c.requestRefresh(at: 1.00)
        c.requestRefresh(at: 1.03)          // burst continues
        XCTAssertFalse(c.isDue(at: 1.05))   // measured from 1.03, only 20ms elapsed
        XCTAssertTrue(c.isDue(at: 1.08))    // 50ms after the LATEST request
    }

    // Never requested ⇒ never due (nothing to recompute).
    func testNeverRequestedNeverDue() {
        let c = SuggestionRefreshCoalescer(quietWindow: 0.05)
        XCTAssertFalse(c.isDue(at: 99.0))
        XCTAssertNil(c.lastRequested)
    }
}
