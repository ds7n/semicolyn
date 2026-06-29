// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Halo center placement, edge clamping, offscreen flag, and degenerate guards.
final class CursorHaloGeometryTests: XCTestCase {
    func testCentersOnCellWhenAwayFromEdges() {
        // col 10 → (10.5)*10 = 105 (in [60,140]); row 4 → (4.5)*20 = 90 (in [60,180]).
        let p = cursorHaloPlacement(cursorCol: 10, cursorRow: 4, cellWidth: 10, cellHeight: 20,
                                    paneWidth: 200, paneHeight: 240, visibleRows: 12, radius: 60)
        XCTAssertEqual(p?.centerX, 105)
        XCTAssertEqual(p?.centerY, 90)
        XCTAssertEqual(p?.isOffscreen, false)
        XCTAssertEqual(p?.radius, 60)
    }

    func testClampsToLeftAndTopEdges() {
        // col 0 → raw 5 → clamped up to radius 60; row 0 → raw 10 → clamped to 60.
        let p = cursorHaloPlacement(cursorCol: 0, cursorRow: 0, cellWidth: 10, cellHeight: 20,
                                    paneWidth: 200, paneHeight: 240, visibleRows: 12, radius: 60)
        XCTAssertEqual(p?.centerX, 60)
        XCTAssertEqual(p?.centerY, 60)
    }

    func testClampsToRightEdge() {
        // col 19 → raw 195 → clamped down to paneWidth-radius = 140.
        let p = cursorHaloPlacement(cursorCol: 19, cursorRow: 4, cellWidth: 10, cellHeight: 20,
                                    paneWidth: 200, paneHeight: 240, visibleRows: 12, radius: 60)
        XCTAssertEqual(p?.centerX, 140)
    }

    func testCentersWhenPaneNarrowerThanDisc() {
        // paneWidth 100 < 2*radius(120) → lo 60 > hi 40 → center at 50.
        let p = cursorHaloPlacement(cursorCol: 5, cursorRow: 4, cellWidth: 10, cellHeight: 20,
                                    paneWidth: 100, paneHeight: 240, visibleRows: 12, radius: 60)
        XCTAssertEqual(p?.centerX, 50)
    }

    func testOffscreenFlagBoundary() {
        func offscreen(_ row: Int) -> Bool? {
            cursorHaloPlacement(cursorCol: 5, cursorRow: row, cellWidth: 10, cellHeight: 20,
                                paneWidth: 200, paneHeight: 240, visibleRows: 12, radius: 60)?.isOffscreen
        }
        XCTAssertEqual(offscreen(-1), true)  // above the window
        XCTAssertEqual(offscreen(11), false) // last visible row (visibleRows-1)
        XCTAssertEqual(offscreen(12), true)  // == visibleRows → below the window
    }

    func testDegenerateDimensionsReturnNil() {
        XCTAssertNil(cursorHaloPlacement(cursorCol: 1, cursorRow: 1, cellWidth: 0, cellHeight: 20,
                                         paneWidth: 200, paneHeight: 240, visibleRows: 12, radius: 60))
        XCTAssertNil(cursorHaloPlacement(cursorCol: 1, cursorRow: 1, cellWidth: 10, cellHeight: 20,
                                         paneWidth: 200, paneHeight: 240, visibleRows: 12, radius: 0))
    }
}
