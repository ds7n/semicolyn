// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class PaneRectsTests: XCTestCase {
    private let cw = 8.0, ch = 16.0

    func testSinglePaneFillsWindow() {
        let layout = PaneLayout.leaf(PaneID(raw: 0), Geometry(w: 80, h: 24, x: 0, y: 0))
        XCTAssertEqual(paneRects(in: layout, cellWidth: cw, cellHeight: ch),
                       [PaneRect(pane: PaneID(raw: 0), x: 0, y: 0, width: 640, height: 384)])
    }

    func testSideBySideSplitColumns() {
        // 80x24 window split into two 40-wide columns (divider ignored; panes abut).
        let left  = PaneLayout.leaf(PaneID(raw: 1), Geometry(w: 40, h: 24, x: 0,  y: 0))
        let right = PaneLayout.leaf(PaneID(raw: 2), Geometry(w: 40, h: 24, x: 41, y: 0))
        let layout = PaneLayout.columns([left, right], Geometry(w: 80, h: 24, x: 0, y: 0))
        XCTAssertEqual(paneRects(in: layout, cellWidth: cw, cellHeight: ch), [
            PaneRect(pane: PaneID(raw: 1), x: 0,   y: 0, width: 320, height: 384),
            PaneRect(pane: PaneID(raw: 2), x: 328, y: 0, width: 320, height: 384),
        ])
    }

    func testStackedSplitRows() {
        let top    = PaneLayout.leaf(PaneID(raw: 1), Geometry(w: 80, h: 12, x: 0, y: 0))
        let bottom = PaneLayout.leaf(PaneID(raw: 2), Geometry(w: 80, h: 11, x: 0, y: 13))
        let layout = PaneLayout.rows([top, bottom], Geometry(w: 80, h: 24, x: 0, y: 0))
        XCTAssertEqual(paneRects(in: layout, cellWidth: cw, cellHeight: ch), [
            PaneRect(pane: PaneID(raw: 1), x: 0, y: 0,   width: 640, height: 192),
            PaneRect(pane: PaneID(raw: 2), x: 0, y: 208, width: 640, height: 176),
        ])
    }

    func testNestedGridPreservesOrderAndGeometry() {
        // Left column is itself a 2-row stack → 3 leaves total.
        let lt = PaneLayout.leaf(PaneID(raw: 1), Geometry(w: 40, h: 12, x: 0, y: 0))
        let lb = PaneLayout.leaf(PaneID(raw: 2), Geometry(w: 40, h: 11, x: 0, y: 13))
        let leftCol = PaneLayout.rows([lt, lb], Geometry(w: 40, h: 24, x: 0, y: 0))
        let right = PaneLayout.leaf(PaneID(raw: 3), Geometry(w: 39, h: 24, x: 41, y: 0))
        let layout = PaneLayout.columns([leftCol, right], Geometry(w: 80, h: 24, x: 0, y: 0))
        let rects = paneRects(in: layout, cellWidth: cw, cellHeight: ch)
        XCTAssertEqual(rects.map(\.pane), [PaneID(raw: 1), PaneID(raw: 2), PaneID(raw: 3)])
        XCTAssertEqual(rects[0], PaneRect(pane: PaneID(raw: 1), x: 0, y: 0,   width: 320, height: 192))
        XCTAssertEqual(rects[1], PaneRect(pane: PaneID(raw: 2), x: 0, y: 208, width: 320, height: 176))
        XCTAssertEqual(rects[2], PaneRect(pane: PaneID(raw: 3), x: 328, y: 0, width: 312, height: 384))
    }
}
