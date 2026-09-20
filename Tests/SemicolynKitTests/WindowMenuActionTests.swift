// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Each window-menu action maps to a tmux COMMAND (run via command mode
/// `<prefix> : <command> Enter`), NOT a default key binding. Command mode is
/// keybinding-independent, so it works even when the user's tmux config rebinds
/// split/kill/etc. (device 2026-09-20: a config binding split to |/- meant the
/// default %/" keys did nothing). No `-t` target = the active pane.
final class WindowMenuActionTests: XCTestCase {
    func testEachActionMapsToItsCommand() {
        XCTAssertEqual(WindowMenuAction.splitHorizontal.command, "split-window -h")
        XCTAssertEqual(WindowMenuAction.splitVertical.command, "split-window -v")
        XCTAssertEqual(WindowMenuAction.closePane.command, "kill-pane")
        XCTAssertEqual(WindowMenuAction.newWindow.command, "new-window")
        XCTAssertEqual(WindowMenuAction.zoom.command, "resize-pane -Z")
    }

    // Guard: every action yields a non-empty command (CaseIterable keeps this honest
    // if a new case is added without a command mapping).
    func testAllActionsHaveACommand() {
        for a in WindowMenuAction.allCases {
            XCTAssertFalse(a.command.isEmpty, "\(a) must map to a tmux command")
        }
    }
}
