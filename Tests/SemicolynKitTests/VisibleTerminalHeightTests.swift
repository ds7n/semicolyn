// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// `visibleTerminalHeight` — the terminal-usable height once the keybar/keyboard
/// accessory's reserved bottom band is removed. Device #1 (2026-07-20): the tmux
/// grid was computed from raw container bounds that INCLUDED the keybar, so the
/// terminal rendered behind the bar. This is the one Linux-testable piece of that
/// fix: it encodes the keyboard-down sentinel (keybarHeight <= 0 -> no subtraction)
/// and the never-negative floor.
final class VisibleTerminalHeightTests: XCTestCase {
    func testSubtractsKeybarWhenPresent() {
        // Device-repro numbers: bounds height 413, keybar 74 -> 339 usable.
        XCTAssertEqual(visibleTerminalHeight(rawHeight: 413, keybarHeight: 74), 339, accuracy: 1e-9)
    }

    func testKeyboardDownSentinelNotSubtracted() {
        // firstResponderKeybarHeight() returns -1 when no pane is first responder
        // (keyboard dismissed -> no accessory); the full height must be used then.
        XCTAssertEqual(visibleTerminalHeight(rawHeight: 413, keybarHeight: -1), 413, accuracy: 1e-9)
    }

    func testZeroKeybarNotSubtracted() {
        XCTAssertEqual(visibleTerminalHeight(rawHeight: 413, keybarHeight: 0), 413, accuracy: 1e-9)
    }

    func testNeverNegative() {
        // A keybar taller than the whole area floors at 0, never negative (terminalGrid
        // then fail-closes on the non-positive height).
        XCTAssertEqual(visibleTerminalHeight(rawHeight: 50, keybarHeight: 74), 0, accuracy: 1e-9)
    }

    func testComposesWithTerminalGridToCorrectRowCount() {
        // The end-to-end device fix: 413pt bounds, 74pt keybar, 10pt cell -> 33 rows
        // (not the buggy 41 that raw 413/10 produced).
        let usable = visibleTerminalHeight(rawHeight: 413, keybarHeight: 74)
        let grid = terminalGrid(width: 402, height: usable, cellWidth: 5, cellHeight: 10)
        XCTAssertEqual(grid?.rows, 33)
        XCTAssertEqual(grid?.cols, 80)
    }
}
