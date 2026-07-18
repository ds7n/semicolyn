// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Live-drag geometry: translation -> clamped content offset (rubber-band past +/-width),
/// and which neighbor the exposed gap reveals (by drag-direction sign).
final class WindowDragModelTests: XCTestCase {
    private let width = 400.0

    // EP: no drag -> no offset (identity).
    func testZeroDragIsIdentity() {
        XCTAssertEqual(WindowDragModel.offset(dx: 0, width: width), 0, accuracy: 0.0001)
    }

    // EP: mid-drag within bounds passes through unchanged.
    func testMidDragPassesThrough() {
        XCTAssertEqual(WindowDragModel.offset(dx: 120, width: width), 120, accuracy: 0.0001)
    }

    // BVA: at exactly +width the content is fully off (fully reveals prev on the left).
    func testAtWidthIsFullyRevealed() {
        XCTAssertEqual(WindowDragModel.offset(dx: width, width: width), width, accuracy: 0.0001)
    }

    // BVA: past +width rubber-bands (moves less than 1:1, stays below 2*width).
    func testPastWidthRubberBands() {
        let o = WindowDragModel.offset(dx: width + 200, width: width)
        XCTAssertGreaterThan(o, width)            // still past the edge
        XCTAssertLessThan(o, width + 200)          // but resisted (rubber-band)
        XCTAssertLessThan(o, 2 * width)            // never runs away
    }

    // Symmetry: past -width rubber-bands the same way on the negative side.
    func testPastNegativeWidthRubberBands() {
        let o = WindowDragModel.offset(dx: -(width + 200), width: width)
        XCTAssertLessThan(o, -width)
        XCTAssertGreaterThan(o, -(width + 200))
    }

    // Exposed neighbor: rightward drag (dx>0) reveals the PREVIOUS window.
    func testRightDragExposesPrevious() {
        XCTAssertEqual(WindowDragModel.exposedNeighbor(dx: 50), .previous)
    }

    // Exposed neighbor: leftward drag (dx<0) reveals the NEXT window.
    func testLeftDragExposesNext() {
        XCTAssertEqual(WindowDragModel.exposedNeighbor(dx: -50), .next)
    }

    // Exposed neighbor: no horizontal drag reveals nothing.
    func testZeroDragExposesNone() {
        XCTAssertEqual(WindowDragModel.exposedNeighbor(dx: 0), .none)
    }
}
