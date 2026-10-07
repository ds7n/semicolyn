// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class GestureEngineDragTests: XCTestCase {
    private let sel = GestureSelection(start: gc(2, 101), end: gc(8, 101))   // start rect x20..30 y20..40

    // MARK: scroll

    func testDeadZoneBoundary() {
        var d = GestureDriver(gestureContext())
        d.down(100, 100, at: 1.0)
        d.move(100, 111.9, at: 1.05)
        XCTAssertEqual(d.engine.stateName, "pressed")
        d.move(100, 112, at: 1.06)
        XCTAssertEqual(d.engine.stateName, "scrolling")
    }

    func testScrollEmitsWholeLinesInFingerDirection() {
        var d = GestureDriver(gestureContext())
        d.down(100, 100, at: 1.0)
        XCTAssertEqual(d.move(100, 139.9, at: 1.1), [.scroll(lines: 1, at: gc(10, 106))])   // 39.9 / 20 -> 1
        XCTAssertEqual(d.move(100, 140, at: 1.2), [.scroll(lines: 1, at: gc(10, 107))])     // total 2
        XCTAssertEqual(d.move(100, 60, at: 1.3), [.scroll(lines: -4, at: gc(10, 103))])     // total -2
    }

    func testScrollClampsToMaxLinesPerEmit() {
        var d = GestureDriver(gestureContext())
        d.down(100, 0, at: 1.0)
        XCTAssertEqual(d.move(100, 1000, at: 1.1), [.scroll(lines: 24, at: gc(10, 129))])
    }

    func testScrollGainForArrowKeys() {
        var d = GestureDriver(gestureContext(scrollGain: 1.8))
        d.down(100, 100, at: 1.0)
        XCTAssertEqual(d.move(100, 120, at: 1.1), [.scroll(lines: 1, at: gc(10, 106))])   // 20*1.8/20 = 1.8
        XCTAssertEqual(d.move(100, 140, at: 1.2), [.scroll(lines: 2, at: gc(10, 107))])   // 3.6 -> 3 total
    }

    /// Review Focus 3: a zero cell height never emits scroll (and does not crash).
    func testZeroCellHeightEmitsNoScroll() {
        var d = GestureDriver(gestureContext(cellWidth: 0, cellHeight: 0))
        d.down(100, 100, at: 1.0)
        d.move(100, 400, at: 1.1)
        d.up(100, 400, at: 1.2)
        d.drainTicks()
        XCTAssertFalse(d.intents.contains { if case .scroll = $0 { return true }; return false })
    }

    func testHorizontalDragOnRawShellScrolls() {
        var d = GestureDriver(gestureContext(screen: .rawShell, mode: .local))
        d.down(200, 100, at: 1.0)
        d.move(100, 100, at: 1.1)
        XCTAssertEqual(d.engine.stateName, "scrolling")
    }

    // MARK: swipe

    func testSwipeCommitsByDistance() {
        var d = GestureDriver(gestureContext())
        d.down(300, 100, at: 1.0)
        d.move(250, 100, at: 1.5)
        XCTAssertEqual(d.engine.stateName, "swiping")
        d.move(140, 100, at: 2.0)
        XCTAssertEqual(d.up(140, 100, at: 2.5), [.switchWindow(delta: +1)])   // dx -160 = 40% of 400
    }

    func testSwipeSnapsBackBelowDistanceWhenSlow() {
        var d = GestureDriver(gestureContext())
        d.down(300, 100, at: 1.0)
        d.move(250, 100, at: 1.5)
        d.move(141, 100, at: 2.0)
        XCTAssertEqual(d.up(141, 100, at: 2.5), [])                              // dx -159, slow
    }

    func testSwipeCommitsByFlick() {
        var d = GestureDriver(gestureContext())
        d.down(300, 100, at: 1.0)
        d.move(280, 100, at: 1.02)
        d.move(240, 100, at: 1.05)
        XCTAssertEqual(d.up(240, 100, at: 1.05), [.switchWindow(delta: +1)])    // -60pt / 0.05s = -1200 pt/s
        var right = GestureDriver(gestureContext())
        right.down(100, 100, at: 1.0); right.move(120, 100, at: 1.02); right.move(160, 100, at: 1.05)
        XCTAssertEqual(right.up(160, 100, at: 1.05), [.switchWindow(delta: -1)])
    }

    /// A fast flick with ONE move past the dead zone: velocity is measured from the touch-down
    /// sample, -50pt / 0.02s = -2500 pt/s, so it commits (50pt alone is far below 40%).
    func testOneMoveFlickCommitsFromTheTouchDownSample() {
        var d = GestureDriver(gestureContext())
        d.down(300, 100, at: 1.0)
        d.move(250, 100, at: 1.016)
        XCTAssertEqual(d.up(250, 100, at: 1.02), [.switchWindow(delta: +1)])
    }

    func testAxisRatioBoundary() {
        var swipe = GestureDriver(gestureContext())
        swipe.down(200, 100, at: 1.0); swipe.move(183, 110, at: 1.1)   // |dx| 17 = 1.7 x 10
        XCTAssertEqual(swipe.engine.stateName, "swiping")
        var scroll = GestureDriver(gestureContext())
        scroll.down(200, 100, at: 1.0); scroll.move(183.1, 110, at: 1.1)   // 16.9
        XCTAssertEqual(scroll.engine.stateName, "scrolling")
    }

    func testSingleWindowTmuxNeverSwipes() {
        var d = GestureDriver(gestureContext(multiWindow: false))
        d.down(300, 100, at: 1.0); d.move(100, 100, at: 1.1)
        XCTAssertEqual(d.engine.stateName, "scrolling")
    }

    /// Review Focus 5: zero view width never switches.
    func testZeroWidthNeverSwitches() {
        var d = GestureDriver(gestureContext(viewWidth: 0))
        d.down(300, 100, at: 1.0); d.move(100, 100, at: 1.02)
        XCTAssertEqual(d.up(100, 100, at: 1.03), [])
    }

    // MARK: handle drag

    func testHandleDragExtendsSelectionAndShowsMenuOnRelease() {
        var d = GestureDriver(gestureContext(selection: sel))
        d.down(25, 30, at: 1.0)                       // on the start handle
        XCTAssertEqual(d.move(65, 70, at: 1.1),
                       [.setSelection(start: gc(8, 101), end: gc(6, 103), loupe: gp(65, 70))])
        XCTAssertEqual(d.up(65, 70, at: 1.2), [.endSelectionDrag(gp(65, 70), showMenu: true)])
    }

    /// Device bug build 175: a horizontal handle drag must never switch windows.
    func testHorizontalHandleDragNeverSwitches() {
        var d = GestureDriver(gestureContext(selection: sel))
        d.down(25, 30, at: 1.0)
        d.move(225, 30, at: 1.05)
        d.up(225, 30, at: 1.06)
        XCTAssertFalse(d.intents.contains(.switchWindow(delta: -1)))
        XCTAssertFalse(d.intents.contains(.switchWindow(delta: 1)))
        XCTAssertEqual(d.intents.last, .endSelectionDrag(gp(225, 30), showMenu: true))
    }

    /// Review Focus 2: holding a handle still never zooms; dragging after still extends.
    func testHoldingAHandleNeverZooms() {
        var d = GestureDriver(gestureContext(selection: sel))
        d.down(25, 30, at: 1.0)
        XCTAssertNil(d.engine.nextDeadline)
        XCTAssertEqual(d.tick(at: 2.0), [])
        XCTAssertEqual(d.move(65, 70, at: 2.1),
                       [.setSelection(start: gc(8, 101), end: gc(6, 103), loupe: gp(65, 70))])
    }

    /// Device bugs 176/178/179: with a selection on screen, swipes off the handles keep working.
    func testRepeatedSwipesWithASelectionAllSwitch() {
        var d = GestureDriver(gestureContext(selection: sel))
        for i in 0..<3 {
            let t = 1.0 + Double(i)
            d.down(300, 300, at: t)
            d.move(250, 300, at: t + 0.02)
            d.move(100, 300, at: t + 0.05)
            d.up(100, 300, at: t + 0.05)
        }
        XCTAssertEqual(d.intents.filter { $0 == .switchWindow(delta: +1) }.count, 3)
    }

    // MARK: fling

    func testFastReleaseFlingsAndConservesLines() {
        var d = GestureDriver(gestureContext())
        d.down(100, 100, at: 0.0)
        d.move(100, 200, at: 0.05)
        d.move(100, 300, at: 0.1)
        d.up(100, 300, at: 0.1)                          // 2000 pt/s
        XCTAssertEqual(d.engine.stateName, "flinging")
        let dragLines = d.intents.reduce(0) { if case let .scroll(n, _) = $1 { return $0 + n }; return $0 }
        XCTAssertEqual(dragLines, 10)                     // 200pt / 20
        let last = d.drainTicks()
        XCTAssertEqual(d.engine.stateName, "idle")
        let total = d.intents.reduce(0) { if case let .scroll(n, _) = $1 { return $0 + n }; return $0 }
        let expectedFling = Int(ScrollMomentum(velocity: 2000).offset(at: last - 0.1) / 20)
        XCTAssertEqual(total - dragLines, expectedFling)  // no lost or duplicated lines
        XCTAssertGreaterThan(expectedFling, 30)
    }

    /// A one-move scroll flick flings: velocity 40pt / 0.03s from the touch-down sample.
    func testOneMoveScrollFlickFlings() {
        var d = GestureDriver(gestureContext())
        d.down(100, 100, at: 0.0)
        XCTAssertEqual(d.move(100, 140, at: 0.02), [.scroll(lines: 2, at: gc(10, 107))])
        XCTAssertEqual(d.up(100, 140, at: 0.03), [])
        XCTAssertEqual(d.engine.stateName, "flinging")
        let last = d.drainTicks()
        XCTAssertEqual(d.engine.stateName, "idle")
        let total = d.intents.reduce(0) { if case let .scroll(n, _) = $1 { return $0 + n }; return $0 }
        let expectedFling = Int(ScrollMomentum(velocity: 40.0 / 0.03).offset(at: last - 0.03) / 20)
        XCTAssertEqual(expectedFling, 22)   // ~(1333 / 2.80) * (1 - 70 / 1333) = ~450pt over 20pt rows
        XCTAssertEqual(total - 2, expectedFling)
    }

    func testSlowReleaseDoesNotFling() {
        var d = GestureDriver(gestureContext())
        d.down(100, 100, at: 0.0)
        d.move(100, 140, at: 1.0)
        d.move(100, 145, at: 1.5)
        d.up(100, 145, at: 2.0)
        XCTAssertEqual(d.engine.stateName, "idle")
        XCTAssertNil(d.engine.nextDeadline)
    }

    func testVelocityUsesOnlyTheLastTenthOfASecond() {
        var d = GestureDriver(gestureContext())
        d.down(100, 100, at: 0.0)
        d.move(100, 200, at: 0.02)       // scrolling begins
        d.move(100, 400, at: 0.05)       // fast movement inside the scroll (~348 pt/s untrimmed)
        d.move(100, 401, at: 0.5)        // then nearly still
        d.move(100, 402, at: 0.6)
        d.up(100, 402, at: 0.6)
        XCTAssertEqual(d.engine.stateName, "idle")   // 10 pt/s over the last 0.1s: no fling
        XCTAssertNil(d.engine.nextDeadline)
    }

    /// Review Focus 1: the touch that stops a fling is not a tap.
    func testTouchThatStopsAFlingIsNotATap() {
        var d = GestureDriver(gestureContext())
        d.down(100, 100, at: 0.0); d.move(100, 200, at: 0.05); d.move(100, 300, at: 0.1); d.up(100, 300, at: 0.1)
        d.tick(at: 0.12)
        let before = d.intents.count
        d.down(100, 300, at: 0.2)
        XCTAssertEqual(d.engine.stateName, "pressed")
        XCTAssertEqual(d.up(100, 300, at: 0.25), [])
        d.drainTicks()
        XCTAssertEqual(d.intents.count, before)      // no tap, no further fling lines
    }

    // MARK: two fingers

    func testSecondFingerCancelsScrollAndQuickTwoFingerTapShowsMenu() {
        var d = GestureDriver(gestureContext(selection: sel))
        d.down(200, 200, at: 1.0)
        d.down(210, 200, at: 1.05, touches: 2)
        XCTAssertEqual(d.engine.stateName, "twoFinger")
        d.up(210, 200, at: 1.2, remaining: 1)
        XCTAssertEqual(d.up(210, 200, at: 1.3, remaining: 0), [.showMenu(gp(210, 200))])
    }

    func testTwoFingerTapWithoutSelectionDoesNothing() {
        var d = GestureDriver(gestureContext())
        d.down(200, 200, at: 1.0); d.down(210, 200, at: 1.05, touches: 2)
        d.up(210, 200, at: 1.2, remaining: 1)
        XCTAssertEqual(d.up(210, 200, at: 1.3, remaining: 0), [])
    }

    func testPinchIsNotATwoFingerTap() {
        var d = GestureDriver(gestureContext(selection: sel))
        d.down(200, 200, at: 1.0); d.down(210, 200, at: 1.05, touches: 2)
        d.move(230, 220, at: 1.1, touches: 2)            // centroid moved >= 10
        d.up(230, 220, at: 1.2, remaining: 1)
        XCTAssertEqual(d.up(230, 220, at: 1.3, remaining: 0), [])
    }

    /// After one finger lifts, the remaining finger's jitter reports its own position, not the
    /// centroid; it must not count as movement.
    func testRemainingFingerJitterDoesNotCancelTwoFingerTap() {
        var d = GestureDriver(gestureContext(selection: sel))
        d.down(180, 200, at: 1.0)
        d.down(200, 200, at: 1.05, touches: 2)
        d.up(200, 200, at: 1.2, remaining: 1)
        d.move(180, 200, at: 1.22, touches: 1)
        XCTAssertEqual(d.up(180, 200, at: 1.3, remaining: 0), [.showMenu(gp(180, 200))])
    }

    func testSlowTwoFingerTouchIsNotATap() {
        var d = GestureDriver(gestureContext(selection: sel))
        d.down(200, 200, at: 1.0); d.down(210, 200, at: 1.05, touches: 2)
        d.up(210, 200, at: 1.39, remaining: 1)
        XCTAssertEqual(d.up(210, 200, at: 1.41, remaining: 0), [])   // 0.36s after the 2nd finger
    }

    func testSecondFingerDuringScrollStopsScrolling() {
        var d = GestureDriver(gestureContext())
        d.down(100, 100, at: 1.0); d.move(100, 160, at: 1.1)
        let before = d.intents.count
        d.down(110, 160, at: 1.15, touches: 2)
        d.move(110, 400, at: 1.2, touches: 2)
        d.up(110, 400, at: 1.3, remaining: 1)
        d.move(100, 600, at: 1.35)                        // remaining finger keeps moving
        d.up(100, 600, at: 1.4, remaining: 0)
        d.drainTicks()
        XCTAssertEqual(d.intents.count, before)
    }

    func testSecondFingerCancelsHandleDragWithoutMenu() {
        var d = GestureDriver(gestureContext(selection: sel))
        d.down(25, 30, at: 1.0); d.move(65, 70, at: 1.1)
        XCTAssertEqual(d.down(70, 70, at: 1.15, touches: 2), [.endSelectionDrag(gp(65, 70), showMenu: false)])
    }

    func testCancelEndsHandleDragWithoutMenu() {
        var d = GestureDriver(gestureContext(selection: sel))
        d.down(25, 30, at: 1.0); d.move(65, 70, at: 1.1)
        XCTAssertEqual(d.send(.cancel, 65, 70, at: 1.2, touches: 0), [.endSelectionDrag(gp(65, 70), showMenu: false)])
        XCTAssertEqual(d.engine.stateName, "idle")
    }
}
