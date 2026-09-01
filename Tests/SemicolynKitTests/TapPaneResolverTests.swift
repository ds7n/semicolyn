// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class TapPaneResolverTests: XCTestCase {
    private func pid(_ n: UInt32) -> PaneID { PaneID(raw: n) }
    private func wid(_ n: UInt32) -> WindowID { WindowID(raw: n) }

    private func twoPane() -> PaneModel {
        var m = PaneModel(window: wid(1), pane: pid(1), gridCols: 80, gridRows: 24)
        m.applySplit(.sideBySide, newPane: pid(2))   // left 0..39, border 40, right 41..79
        return m
    }

    func testTapInsideLeftPane() {
        XCTAssertEqual(resolveTappedPane(col: 10, row: 5, in: twoPane()), pid(1))
    }
    func testTapInsideRightPane() {
        XCTAssertEqual(resolveTappedPane(col: 60, row: 5, in: twoPane()), pid(2))
    }
    func testTapOnLeftPaneRightBoundaryMinusOne() {
        XCTAssertEqual(resolveTappedPane(col: 39, row: 0, in: twoPane()), pid(1))   // last left col
    }
    func testTapOnRightPaneLeftBoundary() {
        XCTAssertEqual(resolveTappedPane(col: 41, row: 0, in: twoPane()), pid(2))   // first right col
    }
    func testTapOnBorderColumnIsNil() {
        XCTAssertNil(resolveTappedPane(col: 40, row: 5, in: twoPane()))             // the divider
    }
    func testTapOutsideGridIsNil() {
        XCTAssertNil(resolveTappedPane(col: 999, row: 5, in: twoPane()))
    }
    func testSinglePaneTapAnywhereResolves() {
        let m = PaneModel(window: wid(1), pane: pid(1), gridCols: 80, gridRows: 24)
        XCTAssertEqual(resolveTappedPane(col: 0, row: 0, in: m), pid(1))
        XCTAssertEqual(resolveTappedPane(col: 79, row: 23, in: m), pid(1))
    }
}
