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
