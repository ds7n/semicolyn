// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// TmuxAction's command is what its private binding runs (no -t = active pane).
final class TmuxActionTests: XCTestCase {
    func testEachActionCommand() {
        XCTAssertEqual(TmuxAction.splitHorizontal.command, "split-window -h")
        XCTAssertEqual(TmuxAction.splitVertical.command, "split-window -v")
        XCTAssertEqual(TmuxAction.closePane.command, "kill-pane")
        XCTAssertEqual(TmuxAction.newWindow.command, "new-window")
        XCTAssertEqual(TmuxAction.zoom.command, "resize-pane -Z")
        XCTAssertEqual(TmuxAction.nextWindow.command, "next-window")
        XCTAssertEqual(TmuxAction.previousWindow.command, "previous-window")
        XCTAssertEqual(TmuxAction.cyclePane.command, "select-pane -t +")
    }

    func testEightActions() {
        XCTAssertEqual(TmuxAction.allCases.count, 8)
    }
}
