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

    // MARK: - detectUnpredictedBorder (B1: catches added panes, e.g. a raw `C-b %`)

    func testEmptyBordersIsVacuouslyValid() {
        // Pins the KNOWN limitation of the OLD check: a single-pane model predicts
        // NO borders, so validateBorders([]) is vacuously valid even when a split
        // was made outside our tracking. This is exactly why detectUnpredictedBorder
        // exists: it inspects the RENDERED grid, not just the predicted cells.
        let v = validateBorders([]) { _, _ in nil }
        XCTAssertEqual(v, .valid)
    }

    func testSinglePaneWithRenderedSplitIsUnpredictedDrift() {
        let whole = PaneRect(pane: PaneID(raw: 1), x: 0, y: 0, width: 80, height: 24)
        let v = detectUnpredictedBorder(rects: [whole], gridCols: 80, gridRows: 24) { col, row in
            col == 40 ? scalar(0x2502) : scalar(0x20)
        }
        XCTAssertEqual(v, .drift)
    }

    func testCorrectTwoPaneModelHasNoUnpredictedBorder() {
        var model = PaneModel(window: WindowID(raw: 0), pane: PaneID(raw: 1), gridCols: 80, gridRows: 24)
        model.applySplit(.sideBySide, newPane: PaneID(raw: 2))
        // Real border sits at col 40, the shared EDGE between the two rects (left
        // is x:0 width:40 -> cols 0..39; right is x:41 width:39 -> cols 41..79),
        // not in either rect's interior, so it must not false-trip.
        let v = detectUnpredictedBorder(rects: model.rects, gridCols: 80, gridRows: 24) { col, row in
            col == 40 ? scalar(0x2502) : scalar(0x20)
        }
        XCTAssertEqual(v, .valid)
    }

    func testSinglePaneNoBorderIsValid() {
        let whole = PaneRect(pane: PaneID(raw: 1), x: 0, y: 0, width: 80, height: 24)
        let v = detectUnpredictedBorder(rects: [whole], gridCols: 80, gridRows: 24) { _, _ in scalar(0x20) }
        XCTAssertEqual(v, .valid)
    }

    func testUnpredictedHorizontalSplitIsDrift() {
        let whole = PaneRect(pane: PaneID(raw: 1), x: 0, y: 0, width: 80, height: 24)
        let v = detectUnpredictedBorder(rects: [whole], gridCols: 80, gridRows: 24) { col, row in
            row == 12 ? scalar(0x2500) : scalar(0x20)
        }
        XCTAssertEqual(v, .drift)
    }

    func testNarrowRectHasNoInteriorToScan() {
        // Width 2 -> no interior columns ((x+1)..<(x+width-1) is empty), so the
        // vertical scan must not crash and must not false-trip on box-drawing
        // rendered in the (only) two columns. Height is also degenerate (2) so
        // the horizontal scan is likewise skipped, isolating the width guard.
        let narrow = PaneRect(pane: PaneID(raw: 1), x: 0, y: 0, width: 2, height: 2)
        let v = detectUnpredictedBorder(rects: [narrow], gridCols: 2, gridRows: 2) { col, row in
            scalar(0x2502)
        }
        XCTAssertEqual(v, .valid)
    }
}
