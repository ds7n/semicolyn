// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// At-dead-zone axis lock: inside dead-zone -> pending; vertical -> scroll;
/// clearly-horizontal in multi-window tmux -> switch; else scroll.
final class DragAxisLockTests: XCTestCase {
    private let dz = DragAxisLock.deadZonePoints

    // BVA: total movement below the dead-zone -> pending (not yet locked).
    func testSubDeadZoneIsPending() {
        XCTAssertEqual(DragAxisLock.resolve(dx: dz * 0.4, dy: dz * 0.4, isMultiWindowTmux: true),
                       .pending)
    }

    // BVA: just past the dead-zone on a pure vertical axis -> scroll.
    func testJustPastDeadZoneVerticalScrolls() {
        XCTAssertEqual(DragAxisLock.resolve(dx: 0, dy: dz + 0.1, isMultiWindowTmux: true),
                       .scroll)
    }

    // EP: clear rightward horizontal drag, multi-window -> PREVIOUS window (-1).
    func testHorizontalRightSwitchesPrev() {
        XCTAssertEqual(DragAxisLock.resolve(dx: dz + 40, dy: 2, isMultiWindowTmux: true),
                       .switchWindow(delta: -1))
    }

    // EP: clear leftward horizontal drag, multi-window -> NEXT window (+1).
    func testHorizontalLeftSwitchesNext() {
        XCTAssertEqual(DragAxisLock.resolve(dx: -(dz + 40), dy: 2, isMultiWindowTmux: true),
                       .switchWindow(delta: +1))
    }

    // EP: clearly-horizontal drag but NOT multi-window -> scroll (switch gated).
    func testHorizontalSingleWindowScrolls() {
        XCTAssertEqual(DragAxisLock.resolve(dx: dz + 40, dy: 2, isMultiWindowTmux: false),
                       .scroll)
    }

    // BVA: just BELOW the switch-dominance ratio -> scroll.
    func testJustBelowSwitchRatioScrolls() {
        let r = DragAxisLock.switchDominanceRatio
        XCTAssertEqual(DragAxisLock.resolve(dx: 30 * r - 3, dy: 30, isMultiWindowTmux: true),
                       .scroll)
    }

    // BVA: just ABOVE the switch-dominance ratio -> switch (rightward -> previous).
    func testJustAboveSwitchRatioSwitches() {
        let r = DragAxisLock.switchDominanceRatio
        XCTAssertEqual(DragAxisLock.resolve(dx: 30 * r + 3, dy: 30, isMultiWindowTmux: true),
                       .switchWindow(delta: -1))
    }

    // Constants match the shipped GestureClassifier values (no silent retune).
    func testConstantsMatchShippedValues() {
        XCTAssertEqual(DragAxisLock.deadZonePoints, 12)
        XCTAssertEqual(DragAxisLock.switchDominanceRatio, 1.7)
    }
}
