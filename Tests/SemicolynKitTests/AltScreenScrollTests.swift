// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class AltScreenScrollTests: XCTestCase {
    let cell = 16.0

    // BVA: below one cell → no arrows, no progress.
    func testSubCellDragEmitsNothing() {
        let r = AltScreenScroll.arrows(totalDy: 10, cellHeight: cell, emittedCells: 0)
        XCTAssertEqual(r.runs, [])
        XCTAssertEqual(r.newEmittedCells, 0)
    }
    // Boundary: exactly one cell down → one UP arrow (natural scroll).
    func testOneCellDownEmitsOneUpArrow() {
        let r = AltScreenScroll.arrows(totalDy: 16, cellHeight: cell, emittedCells: 0)
        XCTAssertEqual(r.runs, [ArrowRun(direction: .up, count: 1)])
        XCTAssertEqual(r.newEmittedCells, 1)
    }
    // Direction: dragging up → DOWN arrows.
    func testDragUpEmitsDownArrows() {
        let r = AltScreenScroll.arrows(totalDy: -48, cellHeight: cell, emittedCells: 0)
        XCTAssertEqual(r.runs, [ArrowRun(direction: .down, count: 3)])
        XCTAssertEqual(r.newEmittedCells, -3)
    }
    // Incremental accounting: a second sample sends only the NEW delta.
    func testIncrementalDeltaOnlyNoDoubleCount() {
        let first = AltScreenScroll.arrows(totalDy: 16, cellHeight: cell, emittedCells: 0)
        XCTAssertEqual(first.newEmittedCells, 1)
        let second = AltScreenScroll.arrows(totalDy: 48, cellHeight: cell, emittedCells: first.newEmittedCells)
        XCTAssertEqual(second.runs, [ArrowRun(direction: .up, count: 2)]) // cells 2 and 3 only
        XCTAssertEqual(second.newEmittedCells, 3)
    }
    // No movement since last emit → nothing.
    func testNoNewCellsEmitsNothing() {
        let r = AltScreenScroll.arrows(totalDy: 20, cellHeight: cell, emittedCells: 1)
        XCTAssertEqual(r.runs, [])
        XCTAssertEqual(r.newEmittedCells, 1)
    }
    // Anti-flood: a huge flick is CLAMPED to maxCellsPerEmit per call (assert the exact cap).
    func testHugeFlickIsClampedToMaxPerEmit() {
        let huge = Double(AltScreenScroll.maxCellsPerEmit + 40) * cell
        let r = AltScreenScroll.arrows(totalDy: huge, cellHeight: cell, emittedCells: 0)
        XCTAssertEqual(r.runs, [ArrowRun(direction: .up, count: AltScreenScroll.maxCellsPerEmit)])
        XCTAssertEqual(r.newEmittedCells, AltScreenScroll.maxCellsPerEmit) // progress caps too
    }
    // Guard: zero/negative cellHeight can't divide-by-zero or spew.
    func testZeroCellHeightEmitsNothing() {
        let r = AltScreenScroll.arrows(totalDy: 100, cellHeight: 0, emittedCells: 0)
        XCTAssertEqual(r.runs, [])
        XCTAssertEqual(r.newEmittedCells, 0)
    }
}
