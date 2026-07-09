// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

// Layout string used throughout: "abcd,80x24,0,0,0"
// Parser strips the checksum (everything before the first comma), leaving
// "80x24,0,0,0" which is: w=80 h=24 x=0 y=0 paneID=0 → .leaf(PaneID(raw:0), …).

final class WindowListingTests: XCTestCase {
    func testParseSingleWindow() {
        let rows = ["@0 1 abcd,80x24,0,0,0 editor"]
        let parsed = parseWindowListing(rows)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].id, WindowID(raw: 0))
        XCTAssertTrue(parsed[0].active)
        XCTAssertEqual(parsed[0].layout, PaneLayout.parse("abcd,80x24,0,0,0"))
        XCTAssertEqual(parsed[0].name, "editor",
                       "window_name (4th field) must be parsed onto the ParsedWindow")
    }

    func testParseWindowNameWithSpaces() {
        // tmux window names may contain spaces (e.g. "my logs"). Because the name is
        // the free-form trailing field and the layout string never contains spaces,
        // the whole remainder after the layout is the name — verbatim, spaces intact.
        let rows = ["@1 1 abcd,80x24,0,0,1 my logs"]
        let parsed = parseWindowListing(rows)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].name, "my logs",
                       "A window name with spaces must be captured whole, not truncated")
    }

    func testParseWindowMissingNameYieldsEmptyName() {
        // Backward-compatible: a 3-field row (no name) still parses, name == "".
        let rows = ["@0 1 abcd,80x24,0,0,0"]
        let parsed = parseWindowListing(rows)
        XCTAssertEqual(parsed.count, 1,
                       "A legacy 3-field row (no name) must still parse")
        XCTAssertEqual(parsed[0].name, "",
                       "Absent name field yields an empty name, not a skipped row")
    }

    func testParseMultipleWindowsOneActive() {
        let rows = ["@0 0 abcd,80x24,0,0,0 shell", "@1 1 abcd,80x24,0,0,1 logs"]
        let parsed = parseWindowListing(rows)
        XCTAssertEqual(parsed.map(\.id), [WindowID(raw: 0), WindowID(raw: 1)])
        XCTAssertEqual(parsed.map(\.active), [false, true])
        XCTAssertEqual(parsed.map(\.name), ["shell", "logs"])
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
        let win = ParsedWindow(id: WindowID(raw: 3), active: true, layout: layout, name: "editor")
        let events = windowListingEvents([win], sessionID: SessionID(raw: 0))

        // Exactly 5 events for one active, named window: windowAdd + windowRenamed +
        // layoutChange + windowPaneChanged (active pane from layout) + sessionWindowChanged.
        XCTAssertEqual(events.count, 5,
                       "Expected exactly 5 events for a single active, named window")

        // windowRenamed carries the parsed window name so the tab strip shows it
        // (not the numeric @id fallback) after a reattach.
        XCTAssertTrue(events.contains(.windowRenamed(WindowID(raw: 3), name: "editor")),
                      "Expected a windowRenamed event carrying the window's name")

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

    func testWindowListingEventsOmitsRenameForEmptyName() {
        // An empty name must NOT emit a windowRenamed — renaming a window to "" would
        // clobber any name tmux later reports and gains nothing (the tab strip already
        // falls back to @id for an empty name).
        let layout = PaneLayout.parse("abcd,80x24,0,0,0")!
        let win = ParsedWindow(id: WindowID(raw: 4), active: false, layout: layout, name: "")
        let events = windowListingEvents([win], sessionID: SessionID(raw: 0))

        for event in events {
            if case .windowRenamed = event {
                XCTFail("An empty window name must not synthesize a windowRenamed event")
            }
        }
    }
}
