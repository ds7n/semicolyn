// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// `GestureEngine.lastReason`: the `reason=` of the `gesture:intent` decision line.
final class GestureEngineReasonTests: XCTestCase {
    func testFreshEngineHasNoReason() {
        XCTAssertEqual(GestureEngine().lastReason, "none")
    }

    func testTapReasonsCountTheTapSequence() {
        var d = GestureDriver(gestureContext())
        d.down(55, 45, at: 1.0)
        XCTAssertEqual(d.engine.lastReason, "down")
        d.move(60, 45, at: 1.02)                       // inside the dead zone
        XCTAssertEqual(d.engine.lastReason, "deadZone")
        d.up(60, 45, at: 1.1)
        XCTAssertEqual(d.engine.lastReason, "tap:1")
        d.down(55, 45, at: 1.2); d.up(55, 45, at: 1.3)
        XCTAssertEqual(d.engine.lastReason, "tap:2")
        d.down(55, 45, at: 1.4); d.up(55, 45, at: 1.5)
        XCTAssertEqual(d.engine.lastReason, "tap:3")
    }

    func testHeldRawTapFiresWithItsOwnReason() {
        var d = GestureDriver(gestureContext(screen: .rawShell, mode: .local))
        d.down(55, 45, at: 1.0); d.up(55, 45, at: 1.1)
        d.tick(at: 1.1 + 0.35)
        XCTAssertEqual(d.engine.lastReason, "tap:held")
    }

    func testLongPressReason() {
        var d = GestureDriver(gestureContext())
        d.down(55, 45, at: 1.0)
        d.tick(at: 1.5)
        XCTAssertEqual(d.engine.lastReason, "longPress")
    }

    func testSwipeReasons() {
        var commit = GestureDriver(gestureContext())
        commit.down(300, 100, at: 1.0)
        commit.move(250, 100, at: 1.02)
        XCTAssertEqual(commit.engine.lastReason, "axisLock:swipe")
        commit.move(100, 100, at: 1.05)
        XCTAssertEqual(commit.engine.lastReason, "swipe")
        commit.up(100, 100, at: 1.06)
        XCTAssertEqual(commit.engine.lastReason, "commit")

        var back = GestureDriver(gestureContext())
        back.down(300, 100, at: 1.0)
        back.move(250, 100, at: 1.5)
        back.up(250, 100, at: 2.0)
        XCTAssertEqual(back.engine.lastReason, "springBack")
    }

    func testScrollAndFlingReasons() {
        var d = GestureDriver(gestureContext())
        d.down(100, 100, at: 0.0)
        d.move(100, 200, at: 0.05)
        XCTAssertEqual(d.engine.lastReason, "axisLock:scroll")
        d.move(100, 300, at: 0.1)
        XCTAssertEqual(d.engine.lastReason, "scroll")
        d.up(100, 300, at: 0.1)
        XCTAssertEqual(d.engine.lastReason, "fling")
        d.drainTicks()
        XCTAssertEqual(d.engine.lastReason, "flingEnd")
        d.down(100, 100, at: 5.0); d.move(100, 140, at: 6.0); d.up(100, 140, at: 7.0)
        XCTAssertEqual(d.engine.lastReason, "scrollEnd")
    }

    func testTouchThatStopsAFlingReason() {
        var d = GestureDriver(gestureContext())
        d.down(100, 100, at: 0.0); d.move(100, 200, at: 0.05); d.move(100, 300, at: 0.1); d.up(100, 300, at: 0.1)
        d.down(100, 300, at: 0.2)
        XCTAssertEqual(d.engine.lastReason, "flingStop")
        d.up(100, 300, at: 0.25)
        XCTAssertEqual(d.engine.lastReason, "flingStop")
    }

    func testHandleAndTwoFingerReasons() {
        let sel = GestureSelection(start: gc(2, 101), end: gc(8, 101))
        var d = GestureDriver(gestureContext(selection: sel))
        d.down(25, 30, at: 1.0)
        XCTAssertEqual(d.engine.lastReason, "down:handle")
        d.move(65, 70, at: 1.1)
        XCTAssertEqual(d.engine.lastReason, "handle")
        d.up(65, 70, at: 1.2)
        XCTAssertEqual(d.engine.lastReason, "handleRelease")

        d.down(200, 200, at: 2.0); d.down(210, 200, at: 2.05, touches: 2)
        XCTAssertEqual(d.engine.lastReason, "twoFinger")
        d.up(210, 200, at: 2.1, remaining: 1)
        XCTAssertEqual(d.engine.lastReason, "twoFinger:lift")
        d.up(210, 200, at: 2.2, remaining: 0)
        XCTAssertEqual(d.engine.lastReason, "twoFingerTap")
    }

    func testCancelReason() {
        var d = GestureDriver(gestureContext())
        d.down(55, 45, at: 1.0)
        d.send(.cancel, 55, 45, at: 1.1, touches: 0)
        XCTAssertEqual(d.engine.lastReason, "cancel")
    }
}
