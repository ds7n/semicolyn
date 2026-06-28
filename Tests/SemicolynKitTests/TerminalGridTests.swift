// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// `terminalGrid` — converts a pixel area + cell metrics into a terminal cell
/// grid. The single accurate source for the tmux client size on rotation/layout,
/// replacing the old hardcoded ~8×16 estimate. Fail-closed on degenerate input.
final class TerminalGridTests: XCTestCase {
    func testTypicalAreaDividesByCell() {
        let grid = terminalGrid(width: 320, height: 480, cellWidth: 8, cellHeight: 16)
        XCTAssertEqual(grid?.cols, 40)
        XCTAssertEqual(grid?.rows, 30)
    }

    func testNonIntegerDivisionFloors() {
        // 100/8 = 12.5 → 12 cols; 100/16 = 6.25 → 6 rows. A partial trailing cell
        // isn't usable, so floor (never round up past the visible area).
        let grid = terminalGrid(width: 100, height: 100, cellWidth: 8, cellHeight: 16)
        XCTAssertEqual(grid?.cols, 12)
        XCTAssertEqual(grid?.rows, 6)
    }

    func testAccurateCellMetricsChangeTheResult() {
        // The whole point of the unification: a real 10pt-wide cell yields 32 cols,
        // not the 40 the old width/8 estimate produced for the same 320pt width.
        XCTAssertEqual(terminalGrid(width: 320, height: 480, cellWidth: 10, cellHeight: 16)?.cols, 32)
    }

    func testSubCellAreaClampsToOneByOne() {
        // A terminal must be at least 1×1 even if the area is smaller than a cell.
        let grid = terminalGrid(width: 4, height: 4, cellWidth: 8, cellHeight: 16)
        XCTAssertEqual(grid?.cols, 1)
        XCTAssertEqual(grid?.rows, 1)
    }

    func testZeroOrNegativeInputsReturnNil() {
        XCTAssertNil(terminalGrid(width: 0, height: 480, cellWidth: 8, cellHeight: 16))
        XCTAssertNil(terminalGrid(width: 320, height: 0, cellWidth: 8, cellHeight: 16))
        XCTAssertNil(terminalGrid(width: 320, height: 480, cellWidth: 0, cellHeight: 16))
        XCTAssertNil(terminalGrid(width: 320, height: 480, cellWidth: 8, cellHeight: 0))
        XCTAssertNil(terminalGrid(width: -1, height: 480, cellWidth: 8, cellHeight: 16))
    }
}
