// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class PaneModelValidationTests: XCTestCase {
    private func scalar(_ u: UInt32) -> Unicode.Scalar { Unicode.Scalar(u)! }

    func testBoxDrawingRangeBoundaries() {
        XCTAssertFalse(isBoxDrawing(scalar(0x24FF)))   // min-1
        XCTAssertTrue(isBoxDrawing(scalar(0x2500)))    // min (─)
        XCTAssertTrue(isBoxDrawing(scalar(0x2502)))    // │
        XCTAssertTrue(isBoxDrawing(scalar(0x257F)))    // max
        XCTAssertFalse(isBoxDrawing(scalar(0x2580)))   // max+1
        XCTAssertFalse(isBoxDrawing(scalar(0x41)))     // 'A'
    }

    func testAllPredictedCellsBoxDrawingIsValid() {
        let border = PredictedBorder(cells: [(40, 0), (40, 1), (40, 2)])
        let grid: [[UInt32: Unicode.Scalar]] = []   // unused; use a closure below
        _ = grid
        let v = validateBorders([border]) { col, row in
            (col == 40 && (0...2).contains(row)) ? scalar(0x2502) : scalar(0x20)
        }
        XCTAssertEqual(v, .valid)
    }

    func testMissingBorderCellIsDrift() {
        let border = PredictedBorder(cells: [(40, 0), (40, 1)])
        let v = validateBorders([border]) { col, row in
            (col == 40 && row == 0) ? scalar(0x2502) : scalar(0x20)   // (40,1) is a space
        }
        XCTAssertEqual(v, .drift)
    }

    func testStrayBoxGlyphElsewhereDoesNotAffectVerdict() {
        // A box glyph at a NON-predicted cell must not make a drifted model look valid,
        // nor a valid model drift: we only inspect predicted cells.
        let border = PredictedBorder(cells: [(40, 0)])
        let v = validateBorders([border]) { col, row in
            if col == 40 && row == 0 { return scalar(0x2502) }   // predicted: present
            if col == 5  && row == 5 { return scalar(0x2502) }   // stray, ignored
            return scalar(0x20)
        }
        XCTAssertEqual(v, .valid)
    }

    func testOutOfRangeCellIsDrift() {
        let border = PredictedBorder(cells: [(999, 0)])
        let v = validateBorders([border]) { _, _ in nil }   // out of range
        XCTAssertEqual(v, .drift)
    }
}
