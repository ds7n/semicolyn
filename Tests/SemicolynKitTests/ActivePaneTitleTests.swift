// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Pure decision logic behind active-pane title keying.
final class ActivePaneTitleTests: XCTestCase {
    private let p1 = PaneID(raw: 1)
    private let p2 = PaneID(raw: 2)

    func testActivePaneTitleIsPublished() {
        XCTAssertEqual(titleToPublish(source: p1, active: p1, title: "vim"), "vim")
    }

    func testBackgroundPaneTitleIsDropped() {
        XCTAssertNil(titleToPublish(source: p2, active: p1, title: "top"))
    }

    func testTitleDroppedWhenNoActivePane() {
        XCTAssertNil(titleToPublish(source: p1, active: nil, title: "vim"))
    }

    func testActiveChangeReturnsNewPaneCachedTitle() {
        XCTAssertEqual(titleOnActiveChange(active: p2, lastTitles: [p1: "vim", p2: "htop"]), "htop")
    }

    func testActiveChangeReturnsNilWhenNewPaneHasNoCachedTitle() {
        XCTAssertNil(titleOnActiveChange(active: p2, lastTitles: [p1: "vim"]))
    }

    func testActiveChangeReturnsNilWhenNoActivePane() {
        XCTAssertNil(titleOnActiveChange(active: nil, lastTitles: [p1: "vim"]))
    }
}
