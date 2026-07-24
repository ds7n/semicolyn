// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Tap-to-row must convert a CONTENT-space y (a scrolled UIScrollView location) to a
/// VIEWPORT screen row by subtracting the scroll offset. It must NOT add yDisp (SwiftTerm's
/// getLine adds that internally), and must clamp into 0..<rows.
final class TapRowMappingTests: XCTestCase {
    // EP: unscrolled (offset 0) still maps directly (baseline unchanged).
    func testUnscrolledMapsDirectly() {
        XCTAssertEqual(
            TapRowMapping.row(contentY: 105, contentOffsetY: 0, cellHeight: 10, rows: 33),
            10)
    }

    // EP + the fix: scrolled tap must subtract the offset, NOT clamp to the last row.
    // contentY 5255, offset 5000 -> viewportY 255 -> row 25 (the current buggy code yields 32).
    func testScrolledSubtractsOffset() {
        XCTAssertEqual(
            TapRowMapping.row(contentY: 5255, contentOffsetY: 5000, cellHeight: 10, rows: 33),
            25)
    }

    // BVA: viewportY exactly at the last row's top maps to rows-1.
    func testLastRowBoundary() {
        // rows=33 -> last row index 32; viewportY 320 -> Int(320/10)=32.
        XCTAssertEqual(
            TapRowMapping.row(contentY: 320, contentOffsetY: 0, cellHeight: 10, rows: 33),
            32)
    }

    // BVA: viewportY past the bottom clamps to rows-1 (not beyond).
    func testPastBottomClampsToLastRow() {
        XCTAssertEqual(
            TapRowMapping.row(contentY: 999, contentOffsetY: 0, cellHeight: 10, rows: 33),
            32)
    }

    // BVA: negative viewportY (tap above content top after over-scroll) clamps to 0.
    func testNegativeViewportClampsToZero() {
        XCTAssertEqual(
            TapRowMapping.row(contentY: 10, contentOffsetY: 50, cellHeight: 10, rows: 33),
            0)
    }

    // Degenerate: non-positive cellHeight or rows returns 0, no crash / no divide-by-zero.
    func testDegenerateInputsReturnZero() {
        XCTAssertEqual(TapRowMapping.row(contentY: 100, contentOffsetY: 0, cellHeight: 0, rows: 33), 0)
        XCTAssertEqual(TapRowMapping.row(contentY: 100, contentOffsetY: 0, cellHeight: 10, rows: 0), 0)
    }
}
