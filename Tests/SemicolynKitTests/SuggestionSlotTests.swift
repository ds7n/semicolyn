// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class SuggestionSlotTests: XCTestCase {
    func testSlotCountBoundary() {
        XCTAssertEqual(suggestionSlotCount(width: 359.9), 3)
        XCTAssertEqual(suggestionSlotCount(width: 360), 4)
        XCTAssertEqual(suggestionSlotCount(width: 360.1), 4)
        XCTAssertEqual(suggestionSlotCount(width: 300), 3)
        XCTAssertEqual(suggestionSlotCount(width: 1000), 4)
        XCTAssertEqual(suggestionSlotCount(width: 0), 3)
    }

    func testStaleTapIgnored() {
        // Slot 1 now holds a different word than the one pressed.
        XCTAssertNil(acceptedSuggestionIndex(pressed: "grep", index: 1, current: ["git", "make"]))
        // Same word still in the touched slot.
        XCTAssertEqual(acceptedSuggestionIndex(pressed: "make", index: 1, current: ["git", "make"]), 1)
        // Slot vanished (index out of range), and an empty list.
        XCTAssertNil(acceptedSuggestionIndex(pressed: "git", index: 3, current: ["git"]))
        XCTAssertNil(acceptedSuggestionIndex(pressed: "git", index: 0, current: []))
    }
}
