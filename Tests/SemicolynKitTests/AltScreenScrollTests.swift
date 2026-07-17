// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class AltScreenScrollTests: XCTestCase {
    let cell = 16.0

    // The scroll-gain multiplier makes content move faster than the finger (the
    // 1.0-gain original felt heavy/sludgy on device, 2026-07-16). One cell-height of
    // drag now emits `scrollGain` arrows. These tests pin the exact gained counts, so a
    // change to the constant is a deliberate, test-visible decision.
    var gain: Double { AltScreenScroll.scrollGain }

    // BVA: a drag small enough that even after gain it is below one cell -> nothing.
    // At gain 1.8 and cell 16, the threshold is 16/1.8 = 8.9pt; 6pt stays sub-cell.
    func testSubCellDragEmitsNothing() {
        let r = AltScreenScroll.arrows(totalDy: 6, cellHeight: cell, emittedCells: 0)
        XCTAssertEqual(r.runs, [])
        XCTAssertEqual(r.newEmittedCells, 0)
    }
    // Boundary: exactly one cell of drag -> `Int(gain)` UP arrows (natural scroll,
    // amplified by gain). At gain 1.8 that is Int(1.8) = 1 arrow for a 16pt drag.
    func testOneCellDownEmitsGainedUpArrows() {
        let r = AltScreenScroll.arrows(totalDy: 16, cellHeight: cell, emittedCells: 0)
        let expected = Int(1.0 * gain)   // cells = Int(totalDy*gain/cell) = Int(gain)
        XCTAssertEqual(r.runs, [ArrowRun(direction: .up, count: expected)])
        XCTAssertEqual(r.newEmittedCells, expected)
    }
    // Direction: dragging up -> DOWN arrows, gained. A 2-cell up-drag (-32pt) at gain
    // 1.8 = Int(2*1.8) = 3 down arrows.
    func testDragUpEmitsGainedDownArrows() {
        let r = AltScreenScroll.arrows(totalDy: -32, cellHeight: cell, emittedCells: 0)
        let expected = Int(2.0 * gain)
        XCTAssertEqual(r.runs, [ArrowRun(direction: .down, count: expected)])
        XCTAssertEqual(r.newEmittedCells, -expected)
    }
    // Incremental accounting: a second sample sends only the NEW gained delta.
    func testIncrementalDeltaOnlyNoDoubleCount() {
        let first = AltScreenScroll.arrows(totalDy: 16, cellHeight: cell, emittedCells: 0)
        let firstCells = Int(1.0 * gain)
        XCTAssertEqual(first.newEmittedCells, firstCells)
        // Drag on to 3 cells (48pt): total gained target = Int(3*gain); the second emit
        // sends only target - firstCells.
        let total = Int(3.0 * gain)
        let second = AltScreenScroll.arrows(totalDy: 48, cellHeight: cell, emittedCells: first.newEmittedCells)
        XCTAssertEqual(second.runs, [ArrowRun(direction: .up, count: total - firstCells)])
        XCTAssertEqual(second.newEmittedCells, total)
    }
    // No further movement since last emit -> nothing. Gain-agnostic: emit for a 1-cell
    // drag, then re-sample the SAME drag -> gained target unchanged -> delta 0 -> nothing
    // (whatever the gain constant is).
    func testNoNewCellsEmitsNothing() {
        let first = AltScreenScroll.arrows(totalDy: 16, cellHeight: cell, emittedCells: 0)
        let r = AltScreenScroll.arrows(totalDy: 16, cellHeight: cell, emittedCells: first.newEmittedCells)
        XCTAssertEqual(r.runs, [])
        XCTAssertEqual(r.newEmittedCells, first.newEmittedCells)
    }
    // Anti-flood: a huge flick is CLAMPED to maxCellsPerEmit per call (gain does not
    // bypass the cap).
    func testHugeFlickIsClampedToMaxPerEmit() {
        // Choose a drag whose GAINED target far exceeds the cap.
        let huge = Double(AltScreenScroll.maxCellsPerEmit + 100) * cell
        let r = AltScreenScroll.arrows(totalDy: huge, cellHeight: cell, emittedCells: 0)
        XCTAssertEqual(r.runs, [ArrowRun(direction: .up, count: AltScreenScroll.maxCellsPerEmit)])
        XCTAssertEqual(r.newEmittedCells, AltScreenScroll.maxCellsPerEmit) // progress caps too
    }
    // Gain makes content outpace the finger: the same physical drag emits strictly MORE
    // arrows than an ungained 1:1 mapping would. This is the fix's whole point.
    func testGainAmplifiesBeyondOneToOne() {
        let dragCells = 4.0
        let r = AltScreenScroll.arrows(totalDy: dragCells * cell, cellHeight: cell, emittedCells: 0)
        let count = r.runs.first?.count ?? 0
        XCTAssertGreaterThan(count, Int(dragCells))   // more than the 4 a 1:1 map would send
        XCTAssertEqual(count, Int(dragCells * gain))  // exactly the gained amount
    }
    // Guard: zero/negative cellHeight can't divide-by-zero or spew.
    func testZeroCellHeightEmitsNothing() {
        let r = AltScreenScroll.arrows(totalDy: 100, cellHeight: 0, emittedCells: 0)
        XCTAssertEqual(r.runs, [])
        XCTAssertEqual(r.newEmittedCells, 0)
    }
    // The gain constant is a real amplification (>1), else the fix is a no-op.
    func testScrollGainIsAmplifying() {
        XCTAssertGreaterThan(AltScreenScroll.scrollGain, 1.0)
    }

    // wheelEvents: gain is a FIXED 1.0 (position-tracking), independent of scrollGain.
    // One cell-height of drag = one wheel event. Finger DOWN (+dy) = wheel UP (scroll back).
    func testWheelOneCellDownEmitsOneUp() {
        let r = AltScreenScroll.wheelEvents(totalDy: 16, cellHeight: cell, emittedCells: 0)
        XCTAssertEqual(r.runs, [ArrowRun(direction: .up, count: 1)])
        XCTAssertEqual(r.newEmittedCells, 1)
    }
    // Direction: dragging up (-dy) = wheel DOWN.
    func testWheelDragUpEmitsDown() {
        let r = AltScreenScroll.wheelEvents(totalDy: -32, cellHeight: cell, emittedCells: 0)
        XCTAssertEqual(r.runs, [ArrowRun(direction: .down, count: 2)])  // 2 cells at gain 1.0
        XCTAssertEqual(r.newEmittedCells, -2)
    }
    // Sub-cell drag -> nothing (BVA below one cell at gain 1.0: 15pt < 16pt cell).
    func testWheelSubCellEmitsNothing() {
        let r = AltScreenScroll.wheelEvents(totalDy: 15, cellHeight: cell, emittedCells: 0)
        XCTAssertEqual(r.runs, [])
        XCTAssertEqual(r.newEmittedCells, 0)
    }
    // Incremental: a second sample sends only the NEW delta (no double-count).
    func testWheelIncrementalDeltaOnly() {
        let first = AltScreenScroll.wheelEvents(totalDy: 16, cellHeight: cell, emittedCells: 0)
        XCTAssertEqual(first.newEmittedCells, 1)
        let second = AltScreenScroll.wheelEvents(totalDy: 48, cellHeight: cell, emittedCells: first.newEmittedCells)
        XCTAssertEqual(second.runs, [ArrowRun(direction: .up, count: 2)])   // 3 total - 1 already
        XCTAssertEqual(second.newEmittedCells, 3)
    }
    // No new movement -> nothing.
    func testWheelNoNewCellsEmitsNothing() {
        let first = AltScreenScroll.wheelEvents(totalDy: 16, cellHeight: cell, emittedCells: 0)
        let r = AltScreenScroll.wheelEvents(totalDy: 16, cellHeight: cell, emittedCells: first.newEmittedCells)
        XCTAssertEqual(r.runs, [])
        XCTAssertEqual(r.newEmittedCells, first.newEmittedCells)
    }
    // Anti-flood: a huge flick clamps to maxCellsPerEmit.
    func testWheelHugeFlickClamped() {
        let huge = Double(AltScreenScroll.maxCellsPerEmit + 100) * cell
        let r = AltScreenScroll.wheelEvents(totalDy: huge, cellHeight: cell, emittedCells: 0)
        XCTAssertEqual(r.runs, [ArrowRun(direction: .up, count: AltScreenScroll.maxCellsPerEmit)])
        XCTAssertEqual(r.newEmittedCells, AltScreenScroll.maxCellsPerEmit)
    }
    // Guard: zero cellHeight -> nothing (fail closed).
    func testWheelZeroCellHeightEmitsNothing() {
        let r = AltScreenScroll.wheelEvents(totalDy: 100, cellHeight: 0, emittedCells: 0)
        XCTAssertEqual(r.runs, [])
        XCTAssertEqual(r.newEmittedCells, 0)
    }
    // Wheel gain is 1.0, NOT scrollGain: a 1-cell drag emits exactly 1 (arrows at 1.8 emit 1 too,
    // but a 2-cell drag distinguishes them: wheel=2, arrows=Int(2*1.8)=3).
    func testWheelGainIsOnePointZeroNotScrollGain() {
        let w = AltScreenScroll.wheelEvents(totalDy: 2 * cell, cellHeight: cell, emittedCells: 0)
        XCTAssertEqual(w.runs.first?.count, 2)                    // gain 1.0
        let a = AltScreenScroll.arrows(totalDy: 2 * cell, cellHeight: cell, emittedCells: 0)
        XCTAssertEqual(a.runs.first?.count, Int(2 * AltScreenScroll.scrollGain))  // gain 1.8 -> 3
    }
}
