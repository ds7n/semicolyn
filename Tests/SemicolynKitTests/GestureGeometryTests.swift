// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class GestureGeometryTests: XCTestCase {
    func testCellMapsViewportPointToAbsoluteCell() {
        XCTAssertEqual(GestureGeometry.cell(at: gp(55, 45), in: gestureContext()), gc(5, 102))
    }

    func testCellBoundariesAreFloorAndClamp() {
        let c = gestureContext()
        XCTAssertEqual(GestureGeometry.cell(at: gp(9.99, 19.99), in: c), gc(0, 100))
        XCTAssertEqual(GestureGeometry.cell(at: gp(10, 20), in: c), gc(1, 101))
        XCTAssertEqual(GestureGeometry.cell(at: gp(-5, -5), in: c), gc(0, 100))
        XCTAssertEqual(GestureGeometry.cell(at: gp(10_000, 10_000), in: c), gc(39, 129))
    }

    /// At the live bottom SwiftTerm rests `contentOffset.y` BELOW `yDisp * cellHeight` by the
    /// partial-row leftover (here 5pt: 1995 vs 2000), and draws absolute row r at content
    /// y = r * cellHeight. Rows must map in content space, clamped to topRow...topRow+rows-1.
    func testCellMapsRowsInContentSpaceWithAPartialRowPhase() {
        let c = gestureContext(contentOffsetY: 1995)
        XCTAssertEqual(GestureGeometry.cell(at: gp(0, 4), in: c), gc(0, 100))      // row 99 sliver: clamps to top row
        XCTAssertEqual(GestureGeometry.cell(at: gp(0, 24.9), in: c), gc(0, 100))   // content 2019.9: still row 100
        XCTAssertEqual(GestureGeometry.cell(at: gp(0, 25), in: c), gc(0, 101))     // content 2020: row 101
        XCTAssertEqual(GestureGeometry.cell(at: gp(0, 584.9), in: c), gc(0, 128))
        XCTAssertEqual(GestureGeometry.cell(at: gp(0, 585), in: c), gc(0, 129))
        XCTAssertEqual(GestureGeometry.cell(at: gp(0, 604.9), in: c), gc(0, 129))  // last row, bottom edge
        XCTAssertEqual(GestureGeometry.cell(at: gp(0, 10_000), in: c), gc(0, 129))
    }

    func testHandleRectUsesTheContentOffset() {
        XCTAssertEqual(GestureGeometry.handleRect(for: gc(2, 101), in: gestureContext(contentOffsetY: 1995)),
                       SelectionHandleRect(x: 20, y: 25, width: 10, height: 20))
    }

    func testHandleHitFollowsTheContentOffset() {
        // start (2,101) rect y 25...45 at offset 1995; slop 22 -> y down to 67
        let c = gestureContext(selection: GestureSelection(start: gc(2, 101), end: gc(8, 101)),
                               contentOffsetY: 1995)
        XCTAssertEqual(GestureGeometry.handle(at: gp(25, 67), in: c), .start)
        XCTAssertNil(GestureGeometry.handle(at: gp(25, 67.1), in: c))
    }

    // MARK: screen

    /// tmux is on screen only while it is attached AND the terminal is off its normal screen
    /// (tmux always uses the alternate screen). Detached / exited tmux, or a Mosh host
    /// without tmux, leaves `plainTmux` set with the shell back on the normal screen.
    func testScreenIsPlainTmuxOnlyWhileTmuxIsOnScreen() {
        XCTAssertEqual(GestureScreen(plainTmuxAttached: true, mode: .appOwnsInput), .plainTmux)
        XCTAssertEqual(GestureScreen(plainTmuxAttached: true, mode: .mouseReporting), .plainTmux)
        XCTAssertEqual(GestureScreen(plainTmuxAttached: true, mode: .localScroll), .rawShell)
        XCTAssertEqual(GestureScreen(plainTmuxAttached: false, mode: .appOwnsInput), .rawShell)
        XCTAssertEqual(GestureScreen(plainTmuxAttached: false, mode: .localScroll), .rawShell)
    }

    // MARK: context log line

    func testContextLogLineFormat() {
        let c = gestureContext(selection: GestureSelection(start: gc(2, 101), end: gc(8, 103)),
                               contentOffsetY: 1995.5, scrollGain: 1.8)
        XCTAssertEqual(c.logLine,
                       "gesture:ctx screen=plainTmux mode=app appMouse=true multiWindow=true "
                       + "sel=2,101-8,103 cell=10.00x20.00 grid=40x30 top=100 offY=1995.50 "
                       + "viewW=400.00 gain=1.80")
        let raw = gestureContext(screen: .rawShell, mode: .local, appMouseOn: false, multiWindow: false)
        XCTAssertEqual(raw.logLine,
                       "gesture:ctx screen=rawShell mode=local appMouse=false multiWindow=false "
                       + "sel=none cell=10.00x20.00 grid=40x30 top=100 offY=2000.00 "
                       + "viewW=400.00 gain=1.00")
    }

    /// Review Focus 3: layout not ready (cell size 0) maps to column 0 of the top row.
    func testZeroCellSizeMapsToTopLeftWithoutCrashing() {
        XCTAssertEqual(GestureGeometry.cell(at: gp(55, 45), in: gestureContext(cellWidth: 0, cellHeight: 0)),
                       gc(0, 100))
    }

    func testHandleRectIsViewportRelative() {
        XCTAssertEqual(GestureGeometry.handleRect(for: gc(2, 101), in: gestureContext()),
                       SelectionHandleRect(x: 20, y: 20, width: 10, height: 20))
    }

    func testHandleHitUsesSlopBoundary() {
        // start (2,101) rect x 20...30, y 20...40; slop 22 -> x up to 52
        let c = gestureContext(selection: GestureSelection(start: gc(2, 101), end: gc(8, 101)))
        XCTAssertEqual(GestureGeometry.handle(at: gp(52, 30), in: c), .start)
        XCTAssertNil(GestureGeometry.handle(at: gp(52.1, 30), in: c))
        XCTAssertEqual(GestureGeometry.handle(at: gp(85, 30), in: c), .end)
    }

    func testNoSelectionMeansNoHandle() {
        XCTAssertNil(GestureGeometry.handle(at: gp(25, 30), in: gestureContext()))
    }

    func testInsideSelection() {
        let c = gestureContext(selection: GestureSelection(start: gc(2, 101), end: gc(8, 101)))
        XCTAssertTrue(GestureGeometry.isInsideSelection(gc(5, 101), in: c))
        XCTAssertTrue(GestureGeometry.isInsideSelection(gc(8, 101), in: c))
        XCTAssertFalse(GestureGeometry.isInsideSelection(gc(9, 101), in: c))
        XCTAssertFalse(GestureGeometry.isInsideSelection(gc(5, 102), in: c))
        XCTAssertFalse(GestureGeometry.isInsideSelection(gc(5, 101), in: gestureContext()))
    }

    func testThresholdValues() {
        XCTAssertEqual(GestureThresholds.deadZone, 12)
        XCTAssertEqual(GestureThresholds.longPressDuration, 0.5)
        XCTAssertEqual(GestureThresholds.longPressSlop, 10)
        XCTAssertEqual(GestureThresholds.handleSlop, 22)
        XCTAssertEqual(GestureThresholds.multiTapInterval, 0.35)
        XCTAssertEqual(GestureThresholds.multiTapDistance, 40)
        XCTAssertEqual(GestureThresholds.twoFingerTapMaxDuration, 0.35)
        XCTAssertEqual(GestureThresholds.velocityWindow, 0.1)
        XCTAssertEqual(GestureThresholds.maxLinesPerEmit, 24)
    }
}
