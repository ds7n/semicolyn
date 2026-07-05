// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

// Layout string used throughout: "abcd,80x24,0,0,0"
// Parser strips the checksum (everything before the first comma), leaving
// "80x24,0,0,0" which is: w=80 h=24 x=0 y=0 paneID=0 → .leaf(PaneID(raw:0), …).

final class WindowListingTests: XCTestCase {
    func testParseSingleWindow() {
        let rows = ["@0 1 abcd,80x24,0,0,0"]
        let parsed = parseWindowListing(rows)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].id, WindowID(raw: 0))
        XCTAssertTrue(parsed[0].active)
        XCTAssertEqual(parsed[0].layout, PaneLayout.parse("abcd,80x24,0,0,0"))
    }

    func testParseMultipleWindowsOneActive() {
        let rows = ["@0 0 abcd,80x24,0,0,0", "@1 1 abcd,80x24,0,0,1"]
        let parsed = parseWindowListing(rows)
        XCTAssertEqual(parsed.map(\.id), [WindowID(raw: 0), WindowID(raw: 1)])
        XCTAssertEqual(parsed.map(\.active), [false, true])
    }

    func testParseSkipsMalformedRows() {
        // Missing layout, bad window token, and a totally malformed line are skipped;
        // the one valid row survives.
        let rows = ["@0 1", "garbage", "notawindow 1 abcd,80x24,0,0,0", "@2 1 abcd,80x24,0,0,0"]
        let parsed = parseWindowListing(rows)
        XCTAssertEqual(parsed.map(\.id), [WindowID(raw: 2)])
    }

    func testWindowListingEventsSynthesizesAddLayoutAndActive() {
        let win = ParsedWindow(id: WindowID(raw: 3), active: true,
                               layout: PaneLayout.parse("abcd,80x24,0,0,0")!)
        let events = windowListingEvents([win], sessionID: SessionID(raw: 0))
        // A window-add + a layout-change for the window, and a session-window-changed
        // to the active one.
        XCTAssertTrue(events.contains(.windowAdd(WindowID(raw: 3))))
        XCTAssertTrue(events.contains(where: {
            if case let .layoutChange(w, _, _, _) = $0 { return w == WindowID(raw: 3) }
            return false
        }))
        XCTAssertTrue(events.contains(.sessionWindowChanged(SessionID(raw: 0), active: WindowID(raw: 3))))
    }
}
