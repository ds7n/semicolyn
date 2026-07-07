// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class CursorTapTargetTests: XCTestCase {
    // Same row, tap to the right → that many Right runs.
    func testSameRowRightMovesRight() {
        XCTAssertEqual(cursorTapArrows(fromCol: 2, fromRow: 5, toCol: 6, toRow: 5),
                       [ArrowRun(direction: .right, count: 4)])
    }
    // Same row, tap to the left → Left runs.
    func testSameRowLeftMovesLeft() {
        XCTAssertEqual(cursorTapArrows(fromCol: 8, fromRow: 5, toCol: 3, toRow: 5),
                       [ArrowRun(direction: .left, count: 5)])
    }
    // Same cell → no movement.
    func testSameCellIsEmpty() {
        XCTAssertEqual(cursorTapArrows(fromCol: 4, fromRow: 5, toCol: 4, toRow: 5), [])
    }
    // Boundary: col 0.
    func testToColZero() {
        XCTAssertEqual(cursorTapArrows(fromCol: 3, fromRow: 0, toCol: 0, toRow: 0),
                       [ArrowRun(direction: .left, count: 3)])
    }
    // Different row, best-effort: row delta (down) THEN col delta (right).
    func testDifferentRowEmitsRowThenCol() {
        XCTAssertEqual(cursorTapArrows(fromCol: 1, fromRow: 2, toCol: 4, toRow: 5),
                       [ArrowRun(direction: .down, count: 3), ArrowRun(direction: .right, count: 3)])
    }
    // Different row upward, no column change → only up runs.
    func testDifferentRowUpOnly() {
        XCTAssertEqual(cursorTapArrows(fromCol: 4, fromRow: 9, toCol: 4, toRow: 6),
                       [ArrowRun(direction: .up, count: 3)])
    }
}
