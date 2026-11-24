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
        XCTAssertEqual(TmuxAction.scrollUp.command,
                       ##"if -F "#{?alternate_on,#{pane_in_mode},1}" "copy-mode -e ; send -X -N 5 scroll-up""##)
        XCTAssertEqual(TmuxAction.scrollDown.command,
                       ##"if -F "#{pane_in_mode}" "send -X -N 5 scroll-down""##)
    }

    /// The argv the launch passes to `bind`: plain commands split on spaces; the scroll
    /// commands keep their format and inner command string as ONE argument each.
    func testArguments() {
        XCTAssertEqual(TmuxAction.splitHorizontal.arguments, ["split-window", "-h"])
        XCTAssertEqual(TmuxAction.closePane.arguments, ["kill-pane"])
        XCTAssertEqual(TmuxAction.cyclePane.arguments, ["select-pane", "-t", "+"])
        XCTAssertEqual(TmuxAction.scrollUp.arguments,
                       ["if", "-F", "#{?alternate_on,#{pane_in_mode},1}", "copy-mode -e ; send -X -N 5 scroll-up"])
        XCTAssertEqual(TmuxAction.scrollDown.arguments,
                       ["if", "-F", "#{pane_in_mode}", "send -X -N 5 scroll-down"])
    }

    func testTenActions() {
        XCTAssertEqual(TmuxAction.allCases.count, 10)
    }
}
