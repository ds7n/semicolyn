// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Card-dim opacity ramp: opacity grows linearly with drag progress and clamps at
/// `maxOpacity`, sign-agnostic (a uniform dim on the departing card; no gradient/direction).
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
}
