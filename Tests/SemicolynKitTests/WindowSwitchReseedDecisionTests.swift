// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// The switch-vs-attach gate that decides whether a render should force-reseed the
/// now-active window's panes (repainting a window that would otherwise return blank).
final class WindowSwitchReseedDecisionTests: XCTestCase {
    // A genuine switch to a DIFFERENT window reseeds.
    func testSwitchToDifferentWindowReseeds() {
        XCTAssertTrue(WindowSwitchReseedDecision.shouldReseed(previous: 1, new: 2))
    }

    // Initial attach (no prior active window) must NOT reseed — the normal appear-path
    // seed already ran for the fresh panes; reseeding would double-capture.
    func testInitialAttachDoesNotReseed() {
        XCTAssertFalse(WindowSwitchReseedDecision.shouldReseed(previous: Optional<Int>.none, new: 7))
    }

    // Same window re-rendered (no switch) must NOT reseed.
    func testSameActiveWindowDoesNotReseed() {
        XCTAssertFalse(WindowSwitchReseedDecision.shouldReseed(previous: 5, new: 5))
    }

    // No active window in the new state → nothing to reseed.
    func testNoNewActiveWindowDoesNotReseed() {
        XCTAssertFalse(WindowSwitchReseedDecision.shouldReseed(previous: 3, new: Optional<Int>.none))
    }

    // Both nil (degenerate: never attached) → no reseed.
    func testBothNilDoesNotReseed() {
        XCTAssertFalse(WindowSwitchReseedDecision.shouldReseed(previous: Optional<Int>.none,
                                                               new: Optional<Int>.none))
    }

    // Switch is symmetric across distinct values (2 -> 1 reseeds just like 1 -> 2), so
    // switching BACK to a previously-visited window also repaints.
    func testSwitchBackAlsoReseeds() {
        XCTAssertTrue(WindowSwitchReseedDecision.shouldReseed(previous: 2, new: 1))
    }
}
