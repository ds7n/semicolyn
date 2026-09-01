// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class PaneModelTests: XCTestCase {
    private func pid(_ n: UInt32) -> PaneID { PaneID(raw: n) }
    private func wid(_ n: UInt32) -> WindowID { WindowID(raw: n) }

    func testInitialSinglePaneFillsGrid() {
        let m = PaneModel(window: wid(1), pane: pid(1), gridCols: 80, gridRows: 24)
        XCTAssertEqual(m.rects.count, 1)
        XCTAssertEqual(m.activePane, pid(1))
        let r = m.rects[0]
        XCTAssertEqual(r.pane, pid(1))
        XCTAssertEqual(r.x, 0); XCTAssertEqual(r.y, 0)
        XCTAssertEqual(r.width, 80); XCTAssertEqual(r.height, 24)
        XCTAssertTrue(m.predictedBorders.isEmpty)   // one pane, no borders
    }

    func testHorizontalSplitProducesTwoRectsAndABorder() {
        var m = PaneModel(window: wid(1), pane: pid(1), gridCols: 80, gridRows: 24)
        m.applySplit(.sideBySide, newPane: pid(2))   // vertical divider, panes left|right
        XCTAssertEqual(m.rects.count, 2)
        // Pinned rule: existing pane keeps the left (ceil), new pane takes the right.
        // 80 cols -> left 40 (cols 0..39), 1-col border at 40, right 39 (cols 41..79).
        let left = m.rects.first { $0.pane == pid(1) }!
        let right = m.rects.first { $0.pane == pid(2) }!
        XCTAssertEqual(left.x, 0);  XCTAssertEqual(left.width, 40)
        XCTAssertEqual(right.x, 41); XCTAssertEqual(right.width, 39)
        // Border at col 40, rows 0..23:
        let border = m.predictedBorders.flatMap { $0.cells }
        XCTAssertTrue(border.contains { $0.col == 40 && $0.row == 0 })
        XCTAssertTrue(border.contains { $0.col == 40 && $0.row == 23 })
    }

    func testZoomToggleFillsThenRestores() {
        var m = PaneModel(window: wid(1), pane: pid(1), gridCols: 80, gridRows: 24)
        m.applySplit(.sideBySide, newPane: pid(2))
        m.applySelectPane(pid(2))
        m.applyZoomToggle()                          // pane 2 fills the grid
        XCTAssertEqual(m.rects.count, 1)
        XCTAssertEqual(m.rects[0].pane, pid(2))
        XCTAssertEqual(m.rects[0].width, 80)
        m.applyZoomToggle()                          // restore
        XCTAssertEqual(m.rects.count, 2)
    }

    func testSelectPaneUpdatesActive() {
        var m = PaneModel(window: wid(1), pane: pid(1), gridCols: 80, gridRows: 24)
        m.applySplit(.sideBySide, newPane: pid(2))
        m.applySelectPane(pid(2))
        XCTAssertEqual(m.activePane, pid(2))
    }

    func testRebuildFromLayoutString() {
        // Recovery path: parse a real tmux layout and rebuild rects.
        let layout = PaneLayout.parse("abcd,80x24,0,0{40x24,0,0,1,39x24,41,0,2}")!
        let m = PaneModel(window: wid(1), activePane: pid(2), layout: layout, gridCols: 80, gridRows: 24)
        XCTAssertEqual(m.rects.count, 2)
        XCTAssertEqual(m.activePane, pid(2))
        XCTAssertNotNil(m.rects.first { $0.pane == pid(1) })
        XCTAssertNotNil(m.rects.first { $0.pane == pid(2) })
    }

    func testStackedSplitProducesTwoRectsAndAHorizontalBorder() {
        var m = PaneModel(window: wid(1), pane: pid(1), gridCols: 80, gridRows: 24)
        m.applySplit(.stacked, newPane: pid(2))   // horizontal divider, panes top|bottom
        XCTAssertEqual(m.rects.count, 2)
        XCTAssertEqual(m.activePane, pid(1))
        // Pinned rule (same as .sideBySide, along height): existing pane keeps the
        // top (ceil), new pane takes the bottom (floor).
        // usable = 24 - 1 = 23; ceil(23/2) = 12 top rows (0..11), border row 12,
        // bottom 11 rows (13..23): 12 + 1 + 11 == 24.
        let top = m.rects.first { $0.pane == pid(1) }!
        let bottom = m.rects.first { $0.pane == pid(2) }!
        XCTAssertEqual(top.y, 0);      XCTAssertEqual(top.height, 12)
        XCTAssertEqual(bottom.y, 13);  XCTAssertEqual(bottom.height, 11)
        XCTAssertEqual(top.x, 0);      XCTAssertEqual(top.width, 80)
        XCTAssertEqual(bottom.x, 0);   XCTAssertEqual(bottom.width, 80)
        // Border at row 12, spanning the full column range:
        let border = m.predictedBorders.flatMap { $0.cells }
        XCTAssertTrue(border.contains { $0.col == 0 && $0.row == 12 })
        XCTAssertTrue(border.contains { $0.col == 79 && $0.row == 12 })
        XCTAssertFalse(border.contains { $0.row == 0 })   // no vertical border introduced
    }

    func testSideBySideSplitOddUsableRounding() {
        // 26 cols -> usable = 25 (odd) -> ceil(25/2) = 13 existing, 12 new.
        var m = PaneModel(window: wid(1), pane: pid(1), gridCols: 26, gridRows: 24)
        m.applySplit(.sideBySide, newPane: pid(2))
        let left = m.rects.first { $0.pane == pid(1) }!
        let right = m.rects.first { $0.pane == pid(2) }!
        XCTAssertEqual(left.x, 0);   XCTAssertEqual(left.width, 13)
        XCTAssertEqual(right.x, 14); XCTAssertEqual(right.width, 12)
    }

    func testSideBySideSplitOnOneWidePaneIsNoOp() {
        // Degenerate: width 1 -> usable (width - 1) = 0, no room for two >=1-cell
        // panes plus a border. Pinned fail-closed rule: the split is a no-op.
        var m = PaneModel(window: wid(1), pane: pid(1), gridCols: 1, gridRows: 24)
        m.applySplit(.sideBySide, newPane: pid(2))
        XCTAssertEqual(m.rects.count, 1)
        XCTAssertEqual(m.rects[0].pane, pid(1))
        XCTAssertEqual(m.rects[0].width, 1)
        XCTAssertEqual(m.activePane, pid(1))
        XCTAssertTrue(m.predictedBorders.isEmpty)
    }

    func testSideBySideSplitOnTwoWidePaneIsNoOp() {
        // Degenerate: width 2 -> usable = 1, still not enough for two >=1-cell
        // panes plus a border (needs usable >= 2). Same fail-closed no-op rule.
        var m = PaneModel(window: wid(1), pane: pid(1), gridCols: 2, gridRows: 24)
        m.applySplit(.sideBySide, newPane: pid(2))
        XCTAssertEqual(m.rects.count, 1)
        XCTAssertEqual(m.rects[0].pane, pid(1))
        XCTAssertEqual(m.rects[0].width, 2)
    }

    func testSideBySideSplitOnThreeWidePaneSucceedsAtTheBoundary() {
        // Boundary just above the degenerate case: width 3 -> usable = 2, exactly
        // enough for two 1-cell panes plus a 1-cell border.
        var m = PaneModel(window: wid(1), pane: pid(1), gridCols: 3, gridRows: 24)
        m.applySplit(.sideBySide, newPane: pid(2))
        XCTAssertEqual(m.rects.count, 2)
        let left = m.rects.first { $0.pane == pid(1) }!
        let right = m.rects.first { $0.pane == pid(2) }!
        XCTAssertEqual(left.x, 0);  XCTAssertEqual(left.width, 1)
        XCTAssertEqual(right.x, 2); XCTAssertEqual(right.width, 1)
    }

    func testStackedSplitOnOneTallPaneIsNoOp() {
        // Degenerate along height: height 1 -> usable = 0, same fail-closed rule.
        var m = PaneModel(window: wid(1), pane: pid(1), gridCols: 80, gridRows: 1)
        m.applySplit(.stacked, newPane: pid(2))
        XCTAssertEqual(m.rects.count, 1)
        XCTAssertEqual(m.rects[0].pane, pid(1))
        XCTAssertEqual(m.rects[0].height, 1)
    }

    func testThreePaneLayoutPredictsBothInteriorVerticalBordersWithoutDoubleCounting() {
        var m = PaneModel(window: wid(1), pane: pid(1), gridCols: 80, gridRows: 24)
        m.applySplit(.sideBySide, newPane: pid(2))   // pane1 [0,40) | border@40 | pane2 [41,80)
        m.applySelectPane(pid(1))
        m.applySplit(.sideBySide, newPane: pid(3))   // pane1 [0,20) | border@20 | pane3 [21,40)
        XCTAssertEqual(m.rects.count, 3)

        let borderCells = m.predictedBorders.flatMap { $0.cells }
        let columns = Set(borderCells.map(\.col))
        // Two interior vertical borders, at col 20 (pane1|pane3) and col 40 (pane3|pane2).
        XCTAssertEqual(columns, [20, 40])
        // No horizontal borders introduced by side-by-side splits.
        XCTAssertFalse(borderCells.contains { $0.col != 20 && $0.col != 40 })

        // Each border column spans the full row range exactly once per row (no
        // double-counting from both (i,j) and (j,i) adjacency checks).
        let col20Rows = borderCells.filter { $0.col == 20 }.map(\.row).sorted()
        let col40Rows = borderCells.filter { $0.col == 40 }.map(\.row).sorted()
        XCTAssertEqual(col20Rows, Array(0..<24))
        XCTAssertEqual(col40Rows, Array(0..<24))
    }

    func testApplySelectWindowRebuildsRectsAndUpdatesActiveWindowAndPane() {
        var m = PaneModel(window: wid(1), pane: pid(1), gridCols: 80, gridRows: 24)
        let layout = PaneLayout.parse("abcd,80x24,0,0{40x24,0,0,3,39x24,41,0,4}")!
        m.applySelectWindow(wid(2), layout: layout, activePane: pid(4))
        XCTAssertEqual(m.activeWindow, wid(2))
        XCTAssertEqual(m.activePane, pid(4))
        XCTAssertEqual(m.rects.count, 2)
        XCTAssertNotNil(m.rects.first { $0.pane == pid(3) })
        XCTAssertNotNil(m.rects.first { $0.pane == pid(4) })
    }
}
