// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class TmuxSessionStateTests: XCTestCase {
    private func state(_ events: [ControlModeEvent]) -> TmuxSessionState {
        var s = TmuxSessionState()
        for e in events { s.apply(e) }
        return s
    }

    func testWindowAddAppendsInOrder() {
        let s = state([.windowAdd(WindowID(raw: 1)), .windowAdd(WindowID(raw: 2))])
        XCTAssertEqual(s.windows.map(\.id), [WindowID(raw: 1), WindowID(raw: 2)])
        XCTAssertEqual(s.window(WindowID(raw: 1))?.name, "")
    }
    func testWindowAddDedupes() {
        let s = state([.windowAdd(WindowID(raw: 1)),
                       .windowRenamed(WindowID(raw: 1), name: "shell"),
                       .windowAdd(WindowID(raw: 1))]) // second add must not reset
        XCTAssertEqual(s.windows.count, 1)
        XCTAssertEqual(s.window(WindowID(raw: 1))?.name, "shell")
    }
    func testWindowClose() {
        let s = state([.windowAdd(WindowID(raw: 1)), .windowAdd(WindowID(raw: 2)),
                       .windowClose(WindowID(raw: 1))])
        XCTAssertEqual(s.windows.map(\.id), [WindowID(raw: 2)])
    }
    func testWindowRenamed() {
        let s = state([.windowAdd(WindowID(raw: 1)),
                       .windowRenamed(WindowID(raw: 1), name: "logs")])
        XCTAssertEqual(s.window(WindowID(raw: 1))?.name, "logs")
    }
    func testWindowPaneChanged() {
        let s = state([.windowAdd(WindowID(raw: 1)),
                       .windowPaneChanged(WindowID(raw: 1), active: PaneID(raw: 5))])
        XCTAssertEqual(s.window(WindowID(raw: 1))?.activePane, PaneID(raw: 5))
    }
    func testEventsForUnknownWindowAreIgnored() {
        let s = state([.windowRenamed(WindowID(raw: 9), name: "ghost"),
                       .windowPaneChanged(WindowID(raw: 9), active: PaneID(raw: 1))])
        XCTAssertTrue(s.windows.isEmpty)
    }

    func testLayoutChangeStoresBothLayouts() {
        let full: PaneLayout = .columns([
            .leaf(PaneID(raw: 1), Geometry(w: 40, h: 24, x: 0, y: 0)),
            .leaf(PaneID(raw: 2), Geometry(w: 39, h: 24, x: 41, y: 0)),
        ], Geometry(w: 80, h: 24, x: 0, y: 0))
        let zoomed: PaneLayout = .leaf(PaneID(raw: 1), Geometry(w: 80, h: 24, x: 0, y: 0))
        let s = state([.windowAdd(WindowID(raw: 1)),
                       .layoutChange(WindowID(raw: 1), layout: full, visible: zoomed, flags: "Z")])
        XCTAssertEqual(s.window(WindowID(raw: 1))?.layout, full)
        XCTAssertEqual(s.window(WindowID(raw: 1))?.visibleLayout, zoomed)
    }
    func testLayoutChangeForUnknownWindowIgnored() {
        let leaf: PaneLayout = .leaf(PaneID(raw: 1), Geometry(w: 80, h: 24, x: 0, y: 0))
        let s = state([.layoutChange(WindowID(raw: 9), layout: leaf, visible: leaf, flags: "*")])
        XCTAssertTrue(s.windows.isEmpty)
    }
    func testSessionChangedSetsIdentity() {
        let s = state([.sessionChanged(SessionID(raw: 0), name: "neotilde-a3f7c2e9")])
        XCTAssertEqual(s.sessionID, SessionID(raw: 0))
        XCTAssertEqual(s.sessionName, "neotilde-a3f7c2e9")
    }
    func testSessionWindowChangedSetsActiveWindow() {
        let s = state([.sessionChanged(SessionID(raw: 0), name: "s"),
                       .windowAdd(WindowID(raw: 2)),
                       .sessionWindowChanged(SessionID(raw: 0), active: WindowID(raw: 2))])
        XCTAssertEqual(s.activeWindow, WindowID(raw: 2))
    }
    func testSessionWindowChangedForOtherSessionIgnored() {
        let s = state([.sessionChanged(SessionID(raw: 0), name: "s"),
                       .sessionWindowChanged(SessionID(raw: 7), active: WindowID(raw: 2))])
        XCTAssertNil(s.activeWindow)
    }
    func testClosingActiveWindowClearsActive() {
        let s = state([.sessionChanged(SessionID(raw: 0), name: "s"),
                       .windowAdd(WindowID(raw: 1)),
                       .sessionWindowChanged(SessionID(raw: 0), active: WindowID(raw: 1)),
                       .windowClose(WindowID(raw: 1))])
        XCTAssertNil(s.activeWindow)
        XCTAssertTrue(s.windows.isEmpty)
    }
    func testExitSetsEndedAndReason() {
        let s = state([.exit(reason: "lost server")])
        XCTAssertTrue(s.ended)
        XCTAssertEqual(s.exitReason, "lost server")
    }
    func testContentEventsCauseNoStructuralChange() {
        let s = state([.windowAdd(WindowID(raw: 1)),
                       .output(pane: PaneID(raw: 1), data: [0x68, 0x69]),
                       .commandResult(number: 1, outcome: .ok(["x"])),
                       .unknown(verb: "pause", raw: "%pause %0"),
                       .malformed(raw: "junk", reason: "x"),
                       .sessionsChanged])
        XCTAssertEqual(s, state([.windowAdd(WindowID(raw: 1))]))
    }
}
