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

    func testParseSkipsRowWithUnparseableLayout() {
        // A row with a valid @N token and valid active flag but an unparseable layout
        // string must be skipped. "not-a-valid-layout" has no comma so PaneLayout.parse
        // returns nil at the first-comma guard.
        XCTAssertNil(PaneLayout.parse("not-a-valid-layout"),
                     "Precondition: layout string with no comma must parse as nil")
        let rows = ["@9 1 not-a-valid-layout", "@2 1 abcd,80x24,0,0,0"]
        let parsed = parseWindowListing(rows)
        XCTAssertEqual(parsed.map(\.id), [WindowID(raw: 2)],
                       "Bad-layout row must be skipped; only the valid row survives")
    }

    func testWindowListingEventsSynthesizesAddLayoutAndActive() {
        let layout = PaneLayout.parse("abcd,80x24,0,0,0")!
        let win = ParsedWindow(id: WindowID(raw: 3), active: true, layout: layout)
        let events = windowListingEvents([win], sessionID: SessionID(raw: 0))

        // Exactly 4 events for one active window: windowAdd + layoutChange +
        // windowPaneChanged (active pane from layout) + sessionWindowChanged.
        XCTAssertEqual(events.count, 4,
                       "Expected exactly 4 events for a single active window")

        // windowAdd for the window.
        XCTAssertTrue(events.contains(.windowAdd(WindowID(raw: 3))))

        // windowPaneChanged sets the active pane from the layout (single leaf → PaneID 0).
        XCTAssertTrue(events.contains(.windowPaneChanged(WindowID(raw: 3), active: PaneID(raw: 0))),
                      "Expected a windowPaneChanged setting the active pane from the layout")

        // layoutChange carries layout == visible == the window's layout and flags == "".
        let layoutChangeEvent = events.first(where: {
            if case .layoutChange(WindowID(raw: 3), _, _, _) = $0 { return true }
            return false
        })
        XCTAssertNotNil(layoutChangeEvent, "Expected a layoutChange event for @3")
        if case let .layoutChange(wid, evtLayout, evtVisible, evtFlags) = layoutChangeEvent! {
            XCTAssertEqual(wid, WindowID(raw: 3))
            XCTAssertEqual(evtLayout, layout,
                           "layoutChange.layout must equal the window's PaneLayout")
            XCTAssertEqual(evtVisible, layout,
                           "layoutChange.visible must equal the window's PaneLayout")
            XCTAssertEqual(evtFlags, "",
                           "layoutChange.flags must be empty string")
        }

        // sessionWindowChanged to the active window.
        XCTAssertTrue(events.contains(.sessionWindowChanged(SessionID(raw: 0), active: WindowID(raw: 3))))
    }
}
