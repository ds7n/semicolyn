// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Handle hit-test picks which selection end a touch grabs; ordering normalizes a flipped
/// drag so the selection never inverts.
///
/// Uses `SelectionHandlePoint`/`SelectionHandleRect` (plain Double fields, no CoreGraphics)
/// instead of `CGPoint`/`CGRect`: this target is Linux-tested and the Linux Swift toolchain
/// has no `CoreGraphics` module (mirrors the existing `PaneRect` no-CoreGraphics pattern).
/// The App layer converts `CGPoint`/`CGRect` to/from these at the call boundary.
final class SelectionHandlesTests: XCTestCase {
    // EP: a point inside the start handle's rect (plus slop) grabs .start.
    func testHitStart() {
        let s = SelectionHandleRect(x: 0, y: 0, width: 10, height: 20)
        let e = SelectionHandleRect(x: 100, y: 0, width: 10, height: 20)
        XCTAssertEqual(SemicolynKit.hitTestHandle(point: SelectionHandlePoint(x: 5, y: 10),
                                                  startRect: s, endRect: e, slop: 8), .start)
    }

    // EP: a point inside the end handle grabs .end.
    func testHitEnd() {
        let s = SelectionHandleRect(x: 0, y: 0, width: 10, height: 20)
        let e = SelectionHandleRect(x: 100, y: 0, width: 10, height: 20)
        XCTAssertEqual(SemicolynKit.hitTestHandle(point: SelectionHandlePoint(x: 104, y: 10),
                                                  startRect: s, endRect: e, slop: 8), .end)
    }

    // Negative: a point far from both handles grabs neither.
    func testHitNone() {
        let s = SelectionHandleRect(x: 0, y: 0, width: 10, height: 20)
        let e = SelectionHandleRect(x: 100, y: 0, width: 10, height: 20)
        XCTAssertNil(SemicolynKit.hitTestHandle(point: SelectionHandlePoint(x: 50, y: 50),
                                                startRect: s, endRect: e, slop: 8))
    }

    // BVA: just inside slop hits, just outside misses.
    func testSlopBoundary() {
        let s = SelectionHandleRect(x: 0, y: 0, width: 10, height: 20)
        let e = SelectionHandleRect(x: 100, y: 0, width: 10, height: 20)
        XCTAssertEqual(SemicolynKit.hitTestHandle(point: SelectionHandlePoint(x: -7, y: 10),
                                                  startRect: s, endRect: e, slop: 8), .start)
        XCTAssertNil(SemicolynKit.hitTestHandle(point: SelectionHandlePoint(x: -9, y: 10),
                                                startRect: s, endRect: e, slop: 8))
    }

    // Overlapping slop (a short word): the handle whose drawn edge is nearer wins. The
    // start handle sits on the start cell's LEFT edge (x=20), the end on the end cell's
    // RIGHT edge (x=50); the split is the midpoint x=35.
    func testOverlapPicksNearerHandle() {
        let s = SelectionHandleRect(x: 20, y: 0, width: 10, height: 20)
        let e = SelectionHandleRect(x: 40, y: 0, width: 10, height: 20)
        func hit(_ x: Double) -> SelectionEnd? {
            SemicolynKit.hitTestHandle(point: SelectionHandlePoint(x: x, y: 10), startRect: s, endRect: e, slop: 22)
        }
        XCTAssertEqual(hit(48), .end)
        XCTAssertEqual(hit(22), .start)
        XCTAssertEqual(hit(34), .start)
        XCTAssertEqual(hit(36), .end)
        XCTAssertEqual(hit(35), .start)               // exact tie keeps the start
    }

    // BVA: a one-cell selection (both ends on the same cell) splits at the cell's middle.
    func testSingleCellSelectionSplitsAtMiddle() {
        let r = SelectionHandleRect(x: 20, y: 0, width: 10, height: 20)
        XCTAssertEqual(SemicolynKit.hitTestHandle(point: SelectionHandlePoint(x: 21, y: 10),
                                                  startRect: r, endRect: r, slop: 22), .start)
        XCTAssertEqual(SemicolynKit.hitTestHandle(point: SelectionHandlePoint(x: 29, y: 10),
                                                  startRect: r, endRect: r, slop: 22), .end)
    }

    // Multi-row: a touch on the end row's handle wins even though the start row's slop
    // reaches it vertically.
    func testOverlapAcrossRowsUsesVerticalDistance() {
        let s = SelectionHandleRect(x: 20, y: 0, width: 10, height: 20)
        let e = SelectionHandleRect(x: 10, y: 20, width: 10, height: 20)
        XCTAssertEqual(SemicolynKit.hitTestHandle(point: SelectionHandlePoint(x: 20, y: 38),
                                                  startRect: s, endRect: e, slop: 22), .end)
        XCTAssertEqual(SemicolynKit.hitTestHandle(point: SelectionHandlePoint(x: 20, y: 2),
                                                  startRect: s, endRect: e, slop: 22), .start)
    }

    // Ordering: a drag that moves the start below/after the end normalizes (row-major).
    func testOrderingFlipsWhenReversed() {
        let r = SemicolynKit.orderedSelection(a: (col: 5, row: 10), b: (col: 2, row: 3))
        XCTAssertEqual(r.start.row, 3); XCTAssertEqual(r.start.col, 2)
        XCTAssertEqual(r.end.row, 10);  XCTAssertEqual(r.end.col, 5)
    }

    // Ordering: same row, col decides.
    func testOrderingSameRow() {
        let r = SemicolynKit.orderedSelection(a: (col: 8, row: 4), b: (col: 3, row: 4))
        XCTAssertEqual(r.start.col, 3); XCTAssertEqual(r.end.col, 8)
    }
}
