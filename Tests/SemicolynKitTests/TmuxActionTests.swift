// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// TmuxAction's command is the command-mode FALLBACK string (no -t = active pane),
/// used only when no key binding is discovered for the action.
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

    func testRawValuesStableForPersistence() {
        // Raw values are the persisted map keys; they must be stable strings.
        XCTAssertEqual(TmuxAction.splitHorizontal.rawValue, "splitHorizontal")
        XCTAssertEqual(TmuxAction.allCases.count, 8)
    }
}
