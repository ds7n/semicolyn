// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class GestureEngineTapTests: XCTestCase {
    // MARK: single tap

    func testTmuxSingleTapFiresImmediatelyOnRelease() {
        var d = GestureDriver(gestureContext())
        d.down(55, 45, at: 1.0)
        XCTAssertEqual(d.up(55, 45, at: 1.1), [.restoreKeyboard, .tap(gc(5, 102))])
        XCTAssertNil(d.engine.nextDeadline)
    }

    func testRawLocalSingleTapWaitsForTheMultiTapWindow() {
        var d = GestureDriver(gestureContext(screen: .rawShell, mode: .local))
        d.down(55, 45, at: 1.0)
        XCTAssertEqual(d.up(55, 45, at: 1.1), [.restoreKeyboard])
        XCTAssertEqual(d.engine.nextDeadline, 1.1 + 0.35)
        XCTAssertEqual(d.tick(at: 1.449), [])
        XCTAssertEqual(d.tick(at: 1.1 + 0.35), [.tap(gc(5, 102))])   // the exact deadline (doubles)
        XCTAssertNil(d.engine.nextDeadline)
    }

    func testRawAppTapClicksOnlyWhenTheAppWantsTheMouse() {
        var on = GestureDriver(gestureContext(screen: .rawShell, mode: .app, appMouseOn: true))
        on.down(55, 45, at: 1.0); on.up(55, 45, at: 1.1); on.tick(at: 1.46)
        XCTAssertEqual(on.intents, [.restoreKeyboard, .tap(gc(5, 102))])

        var off = GestureDriver(gestureContext(screen: .rawShell, mode: .app, appMouseOn: false))
        off.down(55, 45, at: 1.0); off.up(55, 45, at: 1.1)
        XCTAssertNil(off.engine.nextDeadline)
        XCTAssertEqual(off.intents, [.restoreKeyboard])
    }

    func testTapWithSelectionInsideReShowsMenuOutsideClears() {
        let sel = GestureSelection(start: gc(2, 102), end: gc(8, 102))
        var inside = GestureDriver(gestureContext(selection: sel))
        inside.down(55, 45, at: 1.0)
        XCTAssertEqual(inside.up(55, 45, at: 1.1), [.restoreKeyboard, .showMenu(gp(55, 45))])

        var outside = GestureDriver(gestureContext(selection: sel))
        outside.down(155, 45, at: 1.0)
        XCTAssertEqual(outside.up(155, 45, at: 1.1), [.restoreKeyboard, .clearSelection])
    }

    func testMovementBelowDeadZoneIsStillATap() {
        var d = GestureDriver(gestureContext())
        d.down(55, 45, at: 1.0)
        d.move(66.9, 45, at: 1.05)   // 11.9pt < 12
        XCTAssertEqual(d.up(66.9, 45, at: 1.1), [.restoreKeyboard, .tap(gc(5, 102))])
    }

    // MARK: double / triple

    func testDoubleTapSelectsWordAndCancelsTheHeldRawTap() {
        var d = GestureDriver(gestureContext(screen: .rawShell, mode: .local))
        d.down(55, 45, at: 1.0); d.up(55, 45, at: 1.1)
        d.down(56, 46, at: 1.2)
        XCTAssertEqual(d.up(56, 46, at: 1.3), [.selectWord(gc(5, 102), at: gp(56, 46))])
        d.drainTicks()
        XCTAssertFalse(d.intents.contains(.tap(gc(5, 102))))
    }

    func testTmuxDoubleTapClicksOnceThenSelectsWord() {
        var d = GestureDriver(gestureContext())
        d.down(55, 45, at: 1.0); d.up(55, 45, at: 1.1)
        d.down(55, 45, at: 1.2); d.up(55, 45, at: 1.3)
        XCTAssertEqual(d.intents, [.restoreKeyboard, .tap(gc(5, 102)), .selectWord(gc(5, 102), at: gp(55, 45))])
    }

    func testTripleTapSelectsLineAndAFourthTapStartsOver() {
        var d = GestureDriver(gestureContext())
        for i in 0..<3 {
            d.down(55, 45, at: 1.0 + Double(i) * 0.2)
            d.up(55, 45, at: 1.1 + Double(i) * 0.2)
        }
        XCTAssertEqual(d.intents.last, .selectLine(row: 102, at: gp(55, 45)))
        d.down(55, 45, at: 1.6)
        XCTAssertEqual(d.up(55, 45, at: 1.7), [.restoreKeyboard, .tap(gc(5, 102))])
    }

    func testMultiTapIntervalBoundary() {
        var at = GestureDriver(gestureContext())
        at.down(55, 45, at: 1.0); at.up(55, 45, at: 1.1)
        at.down(55, 45, at: 1.4); at.up(55, 45, at: 1.45)      // exactly 0.35 later
        XCTAssertEqual(at.intents.last, .selectWord(gc(5, 102), at: gp(55, 45)))

        var past = GestureDriver(gestureContext())
        past.down(55, 45, at: 1.0); past.up(55, 45, at: 1.1)
        past.down(55, 45, at: 1.4); past.up(55, 45, at: 1.451)  // 0.351 later
        XCTAssertEqual(past.intents.last, .tap(gc(5, 102)))
    }

    /// Review Focus 4: taps more than 40pt apart are two single taps.
    func testMultiTapDistanceBoundary() {
        var near = GestureDriver(gestureContext())
        near.down(55, 45, at: 1.0); near.up(55, 45, at: 1.1)
        near.down(95, 45, at: 1.2); near.up(95, 45, at: 1.3)    // 40pt
        XCTAssertEqual(near.intents.last, .selectWord(gc(9, 102), at: gp(95, 45)))

        var far = GestureDriver(gestureContext())
        far.down(55, 45, at: 1.0); far.up(55, 45, at: 1.1)
        far.down(95.1, 45, at: 1.2); far.up(95.1, 45, at: 1.3)  // 40.1pt
        XCTAssertEqual(far.intents.last, .tap(gc(9, 102)))
    }

    // MARK: long press

    func testLongPressZoomsAtExactlyHalfASecondAndNeverTaps() {
        var d = GestureDriver(gestureContext())
        d.down(55, 45, at: 1.0)
        XCTAssertEqual(d.engine.nextDeadline, 1.5)
        XCTAssertEqual(d.tick(at: 1.499), [])
        XCTAssertEqual(d.tick(at: 1.5), [.zoom])
        XCTAssertEqual(d.up(55, 45, at: 1.8), [])
        XCTAssertEqual(d.intents, [.zoom])   // device bug build 174: no stray click
    }

    func testLongPressInRawShellDoesNothingAndNeverTaps() {
        var d = GestureDriver(gestureContext(screen: .rawShell, mode: .local))
        d.down(55, 45, at: 1.0); d.tick(at: 1.5)
        d.up(55, 45, at: 1.8); d.drainTicks()
        XCTAssertEqual(d.intents, [])
    }

    func testHoldShorterThanLongPressIsATap() {
        var d = GestureDriver(gestureContext())
        d.down(55, 45, at: 1.0)
        d.tick(at: 1.49)
        XCTAssertEqual(d.up(55, 45, at: 1.49), [.restoreKeyboard, .tap(gc(5, 102))])
    }

    func testLongPressSlopBoundary() {
        var still = GestureDriver(gestureContext())
        still.down(55, 45, at: 1.0); still.move(64.9, 45, at: 1.1)   // 9.9pt
        XCTAssertEqual(still.tick(at: 1.5), [.zoom])

        var moved = GestureDriver(gestureContext())
        moved.down(55, 45, at: 1.0); moved.move(65, 45, at: 1.1)     // 10pt
        XCTAssertNil(moved.engine.nextDeadline)
        XCTAssertEqual(moved.tick(at: 1.5), [])
        XCTAssertEqual(moved.up(65, 45, at: 1.6), [.restoreKeyboard, .tap(gc(5, 102))])
    }

    // MARK: tmux off screen

    /// Plain tmux attached but off screen (detached / exited to the login shell, or a Mosh
    /// host without tmux) yields a (rawShell, local) context: no immediate tmux tap, no zoom,
    /// no window swipe. A horizontal drag scrolls instead.
    func testTmuxOffScreenBehavesLikeTheRawShell() {
        let ctx = gestureContext(screen: GestureScreen(plainTmuxAttached: true, mode: .localScroll),
                                 mode: .local, multiWindow: true)
        var tap = GestureDriver(ctx)
        tap.down(55, 45, at: 1.0)
        XCTAssertEqual(tap.up(55, 45, at: 1.1), [.restoreKeyboard])          // held, not immediate
        XCTAssertEqual(tap.engine.nextDeadline, 1.1 + 0.35)

        var hold = GestureDriver(ctx)
        hold.down(55, 45, at: 1.0)
        XCTAssertEqual(hold.tick(at: 1.5), [])                                // no zoom
        hold.up(55, 45, at: 1.8); hold.drainTicks()
        XCTAssertEqual(hold.intents, [])

        var swipe = GestureDriver(ctx)
        swipe.down(300, 100, at: 1.0)
        swipe.move(100, 100, at: 1.02)
        XCTAssertEqual(swipe.engine.stateName, "scrolling")
        XCTAssertEqual(swipe.up(100, 100, at: 1.03), [])
        XCTAssertFalse(swipe.intents.contains { if case .switchWindow = $0 { return true }; return false })
    }

    // MARK: content offset

    /// The tap row comes from content space: with a 5pt partial-row phase (offset 1995),
    /// viewport y 24 is content y 2019, row 100 (viewport-only mapping said 101).
    func testTapRowUsesTheContentOffset() {
        var d = GestureDriver(gestureContext(contentOffsetY: 1995))
        d.down(55, 24, at: 1.0)
        XCTAssertEqual(d.up(55, 24, at: 1.1), [.restoreKeyboard, .tap(gc(5, 100))])
    }

    func testIdleHasNoDeadline() {
        XCTAssertNil(GestureEngine().nextDeadline)
        XCTAssertEqual(GestureEngine().stateName, "idle")
    }
}
