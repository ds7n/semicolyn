// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// A single tap dismisses an active selection first; otherwise it places the cursor.
final class TapActionTests: XCTestCase {
    // EP: selection present → the tap clears it (does NOT place cursor).
    func testTapWithSelectionClears() {
        XCTAssertEqual(tapAction(hasSelection: true), .clearSelection)
    }

    // EP: no selection → the tap places the cursor.
    func testTapWithoutSelectionPlaces() {
        XCTAssertEqual(tapAction(hasSelection: false), .placeCursor)
    }
}
