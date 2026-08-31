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
}
