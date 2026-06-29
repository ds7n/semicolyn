// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Core-tier coverage for the cursor-placement movement engine: gain curve (EP + BVA around
/// the 600 pt/s knee), the 1.5-cell vertical dead-zone (BVA), sub-cell remainder carry, and
/// reset semantics. The `Date` is fixed since v1 doesn't consult it.
final class CursorDragEngineTests: XCTestCase {
    private let t = Date(timeIntervalSince1970: 0)

    // MARK: gain curve

    func testGainIsUnityAtAndBelowPrecisionSpeed() {
        XCTAssertEqual(CursorDragEngine.gain(forSpeed: 0), 1, accuracy: 1e-9)
        XCTAssertEqual(CursorDragEngine.gain(forSpeed: 300), 1, accuracy: 1e-9)
        XCTAssertEqual(CursorDragEngine.gain(forSpeed: 599.9), 1, accuracy: 1e-9)
        XCTAssertEqual(CursorDragEngine.gain(forSpeed: 600), 1, accuracy: 1e-9) // boundary
    }

    func testGainRampsLinearlyAbovePrecisionSpeed() {
        // precisionSpeed 600, accelRange 1200 → midpoint 1200 pt/s gives gain 2.0.
        XCTAssertEqual(CursorDragEngine.gain(forSpeed: 1200), 2, accuracy: 1e-9)
        // End of the ramp (600 + 1200 = 1800) reaches maxGain 3.0 exactly.
        XCTAssertEqual(CursorDragEngine.gain(forSpeed: 1800), 3, accuracy: 1e-9)
    }

    func testGainClampsAtMaxGain() {
        XCTAssertEqual(CursorDragEngine.gain(forSpeed: 5000), 3, accuracy: 1e-9)
    }

    // MARK: vertical dead-zone (BVA at 1.5 cells, cellH = 100)

    func testVerticalBelowDeadzoneEmitsNoRows() {
        var e = CursorDragEngine(); e.begin()
        let out = e.step(fingerDelta: (0, 149), speed: 100, cellW: 100, cellH: 100, at: t) // 1.49 cells
        XCTAssertEqual(out.rows, 0)
        XCTAssertEqual(out.cols, 0)
    }

    func testVerticalAtDeadzoneUnlocksAndEmits() {
        var e = CursorDragEngine(); e.begin()
        let out = e.step(fingerDelta: (0, 150), speed: 100, cellW: 100, cellH: 100, at: t) // exactly 1.5
        XCTAssertEqual(out.rows, 1) // unlocks on the crossing step; remainder 1.5 → 1 row down
    }

    func testVerticalStaysUnlockedAfterCrossing() {
        var e = CursorDragEngine(); e.begin()
        _ = e.step(fingerDelta: (0, 150), speed: 100, cellW: 100, cellH: 100, at: t) // cross + emit 1 (rem .5)
        let out = e.step(fingerDelta: (0, 50), speed: 100, cellW: 100, cellH: 100, at: t) // .5 + .5 = 1.0
        XCTAssertEqual(out.rows, 1)
    }

    func testHorizontalEmitsWhileVerticalLocked() {
        var e = CursorDragEngine(); e.begin()
        let out = e.step(fingerDelta: (100, 50), speed: 100, cellW: 100, cellH: 100, at: t)
        XCTAssertEqual(out.cols, 1) // one cell right
        XCTAssertEqual(out.rows, 0) // vertical still clamped (0.5 < 1.5)
    }

    // MARK: sub-cell remainder carry (cellW = 100, 0.4 cell per step)

    func testSubCellRemainderAccumulates() {
        var e = CursorDragEngine(); e.begin()
        let seq = (0..<5).map { _ in
            e.step(fingerDelta: (40, 0), speed: 100, cellW: 100, cellH: 100, at: t).cols
        }
        // 0.4,0.8,1.2(→1),0.6,1.0(→1) ⇒ no motion lost, no double-count.
        XCTAssertEqual(seq, [0, 0, 1, 0, 1])
    }

    func testSignReversalCancelsRemainder() {
        var e = CursorDragEngine(); e.begin()
        XCTAssertEqual(e.step(fingerDelta: (40, 0), speed: 100, cellW: 100, cellH: 100, at: t).cols, 0)
        XCTAssertEqual(e.step(fingerDelta: (-40, 0), speed: 100, cellW: 100, cellH: 100, at: t).cols, 0)
    }

    // MARK: direction signs

    func testNegativeDeltaEmitsLeftAndUp() {
        var e = CursorDragEngine(); e.begin()
        // Unlock vertical first with a large downward move, then move up-left.
        _ = e.step(fingerDelta: (0, 200), speed: 100, cellW: 100, cellH: 100, at: t)
        let out = e.step(fingerDelta: (-100, -100), speed: 100, cellW: 100, cellH: 100, at: t)
        XCTAssertEqual(out.cols, -1) // left
        XCTAssertEqual(out.rows, -1) // up
    }

    // MARK: acceleration applied to motion

    func testHighSpeedAppliesCappedGain() {
        var e = CursorDragEngine(); e.begin()
        // 10pt × gain 3 / 10pt cell = 3 cells in one fast step.
        let out = e.step(fingerDelta: (10, 0), speed: 9999, cellW: 10, cellH: 100, at: t)
        XCTAssertEqual(out.cols, 3)
    }

    // MARK: no-op + reset

    func testZeroMovementIsNoOp() {
        var e = CursorDragEngine(); e.begin()
        XCTAssertEqual(e.step(fingerDelta: (0, 0), speed: 0, cellW: 100, cellH: 100, at: t).cols, 0)
        XCTAssertEqual(e.step(fingerDelta: (0, 0), speed: 0, cellW: 100, cellH: 100, at: t).rows, 0)
    }

    func testNonPositiveCellIsNoOp() {
        var e = CursorDragEngine(); e.begin()
        XCTAssertEqual(e.step(fingerDelta: (100, 100), speed: 100, cellW: 0, cellH: 100, at: t).cols, 0)
    }

    func testBeginResetsVerticalUnlockAndRemainders() {
        var e = CursorDragEngine(); e.begin()
        _ = e.step(fingerDelta: (0, 300), speed: 100, cellW: 100, cellH: 100, at: t) // unlock vertical
        e.begin() // fresh gesture
        let out = e.step(fingerDelta: (0, 50), speed: 100, cellW: 100, cellH: 100, at: t) // 0.5 < 1.5
        XCTAssertEqual(out.rows, 0) // re-locked
    }
}
