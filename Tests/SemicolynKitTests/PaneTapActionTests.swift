// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class PaneTapActionTests: XCTestCase {
    // Inactive pane always focuses, regardless of mode or selection.
    func testInactiveLocalScrollFocuses() {
        XCTAssertEqual(
            paneTapAction(isActivePane: false, mode: .localScroll, hasSelection: false),
            .focusPane)
    }
    func testInactiveAppOwnsFocuses() {
        XCTAssertEqual(
            paneTapAction(isActivePane: false, mode: .appOwnsInput, hasSelection: false),
            .focusPane)
    }
    func testInactiveMouseReportingFocuses() {
        XCTAssertEqual(
            paneTapAction(isActivePane: false, mode: .mouseReporting, hasSelection: true),
            .focusPane)
    }

    // Active + localScroll delegates to the existing tapAction decider.
    func testActiveLocalScrollNoSelectionPlacesCursor() {
        XCTAssertEqual(
            paneTapAction(isActivePane: true, mode: .localScroll, hasSelection: false),
            .active(.placeCursor))
    }
    func testActiveLocalScrollWithSelectionClears() {
        XCTAssertEqual(
            paneTapAction(isActivePane: true, mode: .localScroll, hasSelection: true),
            .active(.clearSelection))
    }

    // Active + app-owned modes yield.
    func testActiveAppOwnsYields() {
        XCTAssertEqual(
            paneTapAction(isActivePane: true, mode: .appOwnsInput, hasSelection: false),
            .yield)
    }
    func testActiveMouseReportingYields() {
        XCTAssertEqual(
            paneTapAction(isActivePane: true, mode: .mouseReporting, hasSelection: false),
            .yield)
    }

    // Regression guard: the bug this feature fixes. An inactive localScroll pane
    // must NOT place a cursor (old behavior), it must focus.
    func testInactiveLocalScrollIsNotPlaceCursor() {
        XCTAssertNotEqual(
            paneTapAction(isActivePane: false, mode: .localScroll, hasSelection: false),
            .active(.placeCursor))
    }
}
