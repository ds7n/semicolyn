// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ControlModeParserTests: XCTestCase {
    private func feed(_ s: String) -> [ControlModeEvent] {
        ControlModeParser().feed(Array(s.utf8))
    }

    func testWindowAddAndClose() {
        XCTAssertEqual(feed("%window-add @3\n"), [.windowAdd(WindowID(raw: 3))])
        XCTAssertEqual(feed("%window-close @3\n"), [.windowClose(WindowID(raw: 3))])
        XCTAssertEqual(feed("%unlinked-window-close @3\n"), [.windowClose(WindowID(raw: 3))])
    }
    func testWindowRenamedKeepsSpaces() {
        XCTAssertEqual(feed("%window-renamed @1 my long name\n"),
                       [.windowRenamed(WindowID(raw: 1), name: "my long name")])
    }
    func testWindowPaneChanged() {
        XCTAssertEqual(feed("%window-pane-changed @1 %5\n"),
                       [.windowPaneChanged(WindowID(raw: 1), active: PaneID(raw: 5))])
    }
    func testSessionEvents() {
        XCTAssertEqual(feed("%session-changed $0 main\n"),
                       [.sessionChanged(SessionID(raw: 0), name: "main")])
        XCTAssertEqual(feed("%session-window-changed $0 @2\n"),
                       [.sessionWindowChanged(SessionID(raw: 0), active: WindowID(raw: 2))])
        XCTAssertEqual(feed("%sessions-changed\n"), [.sessionsChanged])
    }
    func testExitWithAndWithoutReason() {
        XCTAssertEqual(feed("%exit\n"), [.exit(reason: nil)])
        XCTAssertEqual(feed("%exit server exited unexpectedly\n"),
                       [.exit(reason: "server exited unexpectedly")])
    }
    func testUnknownVerbIsTolerated() {
        XCTAssertEqual(feed("%pause %0\n"), [.unknown(verb: "pause", raw: "%pause %0")])
    }
    func testNonNotificationLineIsMalformed() {
        XCTAssertEqual(feed("garbage line\n"),
                       [.malformed(raw: "garbage line", reason: "line does not start with %")])
    }
    func testMissingArgumentIsMalformed() {
        // %window-add with no @id
        if case .malformed = feed("%window-add\n").first {} else {
            XCTFail("expected .malformed for argument-less %window-add")
        }
    }
    func testCarriageReturnsAreStripped() {
        XCTAssertEqual(feed("%sessions-changed\r\n"), [.sessionsChanged])
    }
    func testPartialLineBuffersUntilNewline() {
        let parser = ControlModeParser()
        XCTAssertEqual(parser.feed(Array("%window-".utf8)), [])
        XCTAssertEqual(parser.feed(Array("add @9\n".utf8)), [.windowAdd(WindowID(raw: 9))])
    }
    func testMultipleEventsInOneFeed() {
        XCTAssertEqual(feed("%sessions-changed\n%window-add @1\n"),
                       [.sessionsChanged, .windowAdd(WindowID(raw: 1))])
    }
}
