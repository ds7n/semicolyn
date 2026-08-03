// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class PaneTapActionTests: XCTestCase {
    // Inactive pane always focuses, regardless of mode or selection.
    func testInactiveLocalScrollFocuses() {
        XCTAssertEqual(
            paneTapAction(isActivePane: false, mode: .localScroll, hasSelection: false,
                          tapInsideSelection: false),
            .focusPane)
    }
    func testInactiveAppOwnsFocuses() {
        XCTAssertEqual(
            paneTapAction(isActivePane: false, mode: .appOwnsInput, hasSelection: false,
                          tapInsideSelection: false),
            .focusPane)
    }
    func testInactiveMouseReportingFocuses() {
        XCTAssertEqual(
            paneTapAction(isActivePane: false, mode: .mouseReporting, hasSelection: true,
                          tapInsideSelection: false),
            .focusPane)
    }

    // Active + localScroll delegates to the existing tapAction decider.
    func testActiveLocalScrollNoSelectionPlacesCursor() {
        XCTAssertEqual(
            paneTapAction(isActivePane: true, mode: .localScroll, hasSelection: false,
                          tapInsideSelection: false),
            .active(.placeCursor))
    }
    func testActiveLocalScrollWithSelectionClears() {
        XCTAssertEqual(
            paneTapAction(isActivePane: true, mode: .localScroll, hasSelection: true,
                          tapInsideSelection: false),
            .active(.clearSelection))
    }

    // Active + app-owned modes yield.
    func testActiveAppOwnsYields() {
        XCTAssertEqual(
            paneTapAction(isActivePane: true, mode: .appOwnsInput, hasSelection: false,
                          tapInsideSelection: false),
            .yield)
    }
    func testActiveMouseReportingYields() {
        XCTAssertEqual(
            paneTapAction(isActivePane: true, mode: .mouseReporting, hasSelection: false,
                          tapInsideSelection: false),
            .yield)
    }

    // Regression guard: the bug this feature fixes. An inactive localScroll pane
    // must NOT place a cursor (old behavior), it must focus.
    func testInactiveLocalScrollIsNotPlaceCursor() {
        XCTAssertNotEqual(
            paneTapAction(isActivePane: false, mode: .localScroll, hasSelection: false,
                          tapInsideSelection: false),
            .active(.placeCursor))
    }
}

/// Single-tap routing: tap ON an active selection re-summons the copy menu (does NOT clear);
/// tap OUTSIDE it clears; with no selection, place cursor. Re-summon/clear apply in EVERY mode.
final class TapActionReSummonTests: XCTestCase {
    // No selection -> place cursor (unchanged).
    func testNoSelectionPlaces() {
        XCTAssertEqual(tapAction(hasSelection: false, tapInsideSelection: false), .placeCursor)
    }
    // Selection + tap inside -> re-summon.
    func testInsideReSummons() {
        XCTAssertEqual(tapAction(hasSelection: true, tapInsideSelection: true), .reSummonMenu)
    }
    // Selection + tap outside -> clear.
    func testOutsideClears() {
        XCTAssertEqual(tapAction(hasSelection: true, tapInsideSelection: false), .clearSelection)
    }
    // Alt-screen (.appOwnsInput) WITH a selection: tap-inside still re-summons (not yield).
    func testAltScreenInsideReSummons() {
        XCTAssertEqual(
            paneTapAction(isActivePane: true, mode: .appOwnsInput,
                          hasSelection: true, tapInsideSelection: true),
            .active(.reSummonMenu))
    }
    // Alt-screen WITHOUT a selection: yields (unchanged app-owned behavior).
    func testAltScreenNoSelectionYields() {
        XCTAssertEqual(
            paneTapAction(isActivePane: true, mode: .appOwnsInput,
                          hasSelection: false, tapInsideSelection: false),
            .yield)
    }
    // Inactive pane always focuses, regardless of selection.
    func testInactiveFocuses() {
        XCTAssertEqual(
            paneTapAction(isActivePane: false, mode: .localScroll,
                          hasSelection: true, tapInsideSelection: true),
            .focusPane)
    }
    // isWithinSelection: single row bounds.
    func testWithinSelectionSingleRow() {
        let s = (col: 2, row: 5), e = (col: 8, row: 5)
        XCTAssertTrue(SemicolynKit.isWithinSelection(col: 5, row: 5, start: s, end: e))
        XCTAssertFalse(SemicolynKit.isWithinSelection(col: 1, row: 5, start: s, end: e))
        XCTAssertFalse(SemicolynKit.isWithinSelection(col: 9, row: 5, start: s, end: e))
    }
    // isWithinSelection: multi-row (reversed input) bounds.
    func testWithinSelectionMultiRow() {
        let s = (col: 5, row: 3), e = (col: 2, row: 7)
        XCTAssertTrue(SemicolynKit.isWithinSelection(col: 0, row: 5, start: s, end: e))
        XCTAssertTrue(SemicolynKit.isWithinSelection(col: 6, row: 3, start: s, end: e))
        XCTAssertFalse(SemicolynKit.isWithinSelection(col: 4, row: 3, start: s, end: e))
        XCTAssertFalse(SemicolynKit.isWithinSelection(col: 3, row: 7, start: s, end: e))
    }
}
