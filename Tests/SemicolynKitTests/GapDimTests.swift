// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Gap-dim ramp (opacity grows with drag progress, clamped) + gradient direction
/// (dark end nearest the departing window, mirrored by drag direction).
final class GapDimTests: XCTestCase {
    private let width = 400.0

    // EP: no drag -> fully transparent.
    func testZeroDragIsTransparent() {
        XCTAssertEqual(GapDim.opacity(offset: 0, width: width), 0, accuracy: 0.0001)
    }

    // EP: half-width drag -> half of maxOpacity.
    func testHalfDragIsHalfMax() {
        XCTAssertEqual(GapDim.opacity(offset: 200, width: width),
                       0.5 * GapDim.maxOpacity, accuracy: 0.0001)
    }

    // BVA: at full width -> exactly maxOpacity.
    func testAtWidthIsMax() {
        XCTAssertEqual(GapDim.opacity(offset: width, width: width),
                       GapDim.maxOpacity, accuracy: 0.0001)
    }

    // BVA: past full width -> clamped at maxOpacity (does not exceed).
    func testPastWidthClampsToMax() {
        XCTAssertEqual(GapDim.opacity(offset: width * 2, width: width),
                       GapDim.maxOpacity, accuracy: 0.0001)
    }

    // Sign-agnostic: a leftward (negative) drag ramps the same as rightward.
    func testNegativeOffsetRampsSame() {
        XCTAssertEqual(GapDim.opacity(offset: -200, width: width),
                       GapDim.opacity(offset: 200, width: width), accuracy: 0.0001)
    }

    // Guard: width <= 0 -> 0 (no divide-by-zero / no dim).
    func testZeroWidthIsTransparent() {
        XCTAssertEqual(GapDim.opacity(offset: 100, width: 0), 0, accuracy: 0.0001)
    }

    // Direction: previous (rightward drag, gap opens on the LEFT) and next (leftward drag,
    // gap opens on the RIGHT) produce MIRRORED endpoints.
    func testEndpointsMirrorByDirection() {
        let prev = GapDim.endpoints(exposed: .previous)
        let next = GapDim.endpoints(exposed: .next)
        XCTAssertEqual(prev.startX, next.endX, accuracy: 0.0001)
        XCTAssertEqual(prev.endX, next.startX, accuracy: 0.0001)
        // And they are not degenerate (start != end).
        XCTAssertNotEqual(prev.startX, prev.endX)
    }

    // Direction: .none -> a defined default with no gradient span (start == end),
    // so no dim direction is implied when there is no horizontal drag.
    func testNoneHasNoSpan() {
        let none = GapDim.endpoints(exposed: .none)
        XCTAssertEqual(none.startX, none.endX, accuracy: 0.0001)
    }

    // Absolute direction (locks the sign the mirror test can't): .previous is a RIGHTWARD
    // drag, so the window slides right and the gap opens on the LEFT -> the DARK end (startX)
    // must be on the LEFT (0.0), fading to clear on the right (1.0). This is where the gap
    // actually is; the pre-2026-07-19 mapping had it backwards and no dim was visible.
    func testPreviousDarkEndIsOnTheLeft() {
        let ep = GapDim.endpoints(exposed: .previous)
        XCTAssertEqual(ep.startX, 0.0, accuracy: 0.0001)   // dark end = left edge (where the gap opens)
        XCTAssertEqual(ep.endX, 1.0, accuracy: 0.0001)     // clear end = right edge
    }

    // Mirror: .next is a LEFTWARD drag, gap opens on the RIGHT -> dark end on the RIGHT (1.0).
    func testNextDarkEndIsOnTheRight() {
        let ep = GapDim.endpoints(exposed: .next)
        XCTAssertEqual(ep.startX, 1.0, accuracy: 0.0001)   // dark end = right edge (where the gap opens)
        XCTAssertEqual(ep.endX, 0.0, accuracy: 0.0001)     // clear end = left edge
    }
}
