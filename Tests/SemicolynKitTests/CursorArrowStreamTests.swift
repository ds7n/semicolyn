// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Sign→direction mapping and run counts for `arrowEvents`.
final class CursorArrowStreamTests: XCTestCase {
    func testZeroDeltaEmitsNothing() {
        XCTAssertEqual(arrowEvents(cols: 0, rows: 0), [])
    }

    func testPositiveColsAreRight() {
        XCTAssertEqual(arrowEvents(cols: 2, rows: 0), [ArrowRun(direction: .right, count: 2)])
    }

    func testNegativeColsAreLeft() {
        XCTAssertEqual(arrowEvents(cols: -3, rows: 0), [ArrowRun(direction: .left, count: 3)])
    }

    func testPositiveRowsAreDown() {
        XCTAssertEqual(arrowEvents(cols: 0, rows: 1), [ArrowRun(direction: .down, count: 1)])
    }

    func testNegativeRowsAreUp() {
        XCTAssertEqual(arrowEvents(cols: 0, rows: -2), [ArrowRun(direction: .up, count: 2)])
    }

    func testCombinedEmitsHorizontalThenVertical() {
        XCTAssertEqual(arrowEvents(cols: 1, rows: -1),
                       [ArrowRun(direction: .right, count: 1), ArrowRun(direction: .up, count: 1)])
    }
}
