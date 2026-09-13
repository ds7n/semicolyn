// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Axis lock decided once the finger settles past the COMMIT radius (larger than the
/// dead-zone so the lock reflects the drag's settled direction, not its first twitch).
/// A vertical veto forces scroll whenever the drag has clear vertical travel, even if
/// the horizontal component momentarily dominates; a clearly-horizontal drag in
/// multi-window tmux switches windows; everything else scrolls.
final class DragAxisLockTests: XCTestCase {
    private let commit = DragAxisLock.commitRadiusPoints

    // BVA: total movement below the commit radius -> pending (not yet locked), even past
    // the smaller dead-zone. Keeps re-sampling instead of freezing on an early twitch.
    func testSubCommitRadiusIsPending() {
        // A point past the old dead-zone (12) but short of the commit radius (24) on a
        // clearly-horizontal path must still be pending, not an early switch.
        XCTAssertEqual(DragAxisLock.resolve(dx: 16, dy: 1, isMultiWindowTmux: true),
                       .pending)
    }

    // BVA: just past the commit radius on a pure vertical axis -> scroll.
    func testJustPastCommitRadiusVerticalScrolls() {
        XCTAssertEqual(DragAxisLock.resolve(dx: 0, dy: commit + 0.1, isMultiWindowTmux: true),
                       .scroll)
    }

    // THE BUG (Issue A): a vertical scroll that begins with a sideways twitch. Once the
    // drag has clear vertical travel (|dy| over the veto floor), it MUST scroll even when
    // the horizontal component dominates at that instant. Pre-fix this locked to switch.
    func testVerticalVetoForcesScrollDespiteHorizontalDominance() {
        // |dx|=40 dominates |dy|=20 (ratio 2.0), but dy=20 > veto floor (14) -> scroll.
        XCTAssertEqual(DragAxisLock.resolve(dx: 40, dy: 20, isMultiWindowTmux: true),
                       .scroll)
    }

    // BVA: just BELOW the vertical-veto floor, a clearly-horizontal drag still switches.
    func testJustBelowVerticalVetoStillSwitches() {
        let veto = DragAxisLock.verticalVetoPoints
        // dy just under the floor, dx well past commit radius and dominant -> switch.
        XCTAssertEqual(DragAxisLock.resolve(dx: commit + 20, dy: veto - 1, isMultiWindowTmux: true),
                       .switchWindow(delta: -1))
    }

    // EP: clear rightward horizontal drag, multi-window -> PREVIOUS window (-1).
    func testHorizontalRightSwitchesPrev() {
        XCTAssertEqual(DragAxisLock.resolve(dx: commit + 40, dy: 2, isMultiWindowTmux: true),
                       .switchWindow(delta: -1))
    }

    // EP: clear leftward horizontal drag, multi-window -> NEXT window (+1).
    func testHorizontalLeftSwitchesNext() {
        XCTAssertEqual(DragAxisLock.resolve(dx: -(commit + 40), dy: 2, isMultiWindowTmux: true),
                       .switchWindow(delta: +1))
    }

    // EP: clearly-horizontal drag but NOT multi-window -> scroll (switch gated).
    func testHorizontalSingleWindowScrolls() {
        XCTAssertEqual(DragAxisLock.resolve(dx: commit + 40, dy: 2, isMultiWindowTmux: false),
                       .scroll)
    }

    // BVA: just BELOW the switch-dominance ratio (with dy under the veto) -> scroll.
    func testJustBelowSwitchRatioScrolls() {
        let r = DragAxisLock.switchDominanceRatio
        // dy=12 is under the veto (14); dx just under ratio*dy -> scroll on dominance.
        XCTAssertEqual(DragAxisLock.resolve(dx: 12 * r - 3, dy: 12, isMultiWindowTmux: true),
                       .scroll)
    }

    // BVA: just ABOVE the switch-dominance ratio (dy under the veto) -> switch.
    func testJustAboveSwitchRatioSwitches() {
        let r = DragAxisLock.switchDominanceRatio
        // Ensure the point also clears the commit radius: 12*2+3 = 27 > 24.
        XCTAssertEqual(DragAxisLock.resolve(dx: 12 * r + 3, dy: 12, isMultiWindowTmux: true),
                       .switchWindow(delta: -1))
    }

    // Constants match the shipped values (no silent retune): commit radius 24, dead-zone
    // 12, veto floor 14, dominance ratio 2.0.
    func testConstantsMatchShippedValues() {
        XCTAssertEqual(DragAxisLock.deadZonePoints, 12)
        XCTAssertEqual(DragAxisLock.commitRadiusPoints, 24)
        XCTAssertEqual(DragAxisLock.verticalVetoPoints, 14)
        XCTAssertEqual(DragAxisLock.switchDominanceRatio, 2.0)
    }
}
