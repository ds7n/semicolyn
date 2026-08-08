// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// `visibleTerminalHeight`, the terminal-usable height once the keybar/keyboard
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

    // Device 2026-08-02 (Claude Code alt-screen hidden-rows bug): bounds 417pt, keybar 56pt,
    // cell height 11.15 -> the grid must use the keybar-reduced height, not the full 417.
    // Full 417/11.15 = 37 rows (bottom ~5 rows render behind the keybar); 361/11.15 = 32 rows fit.
    func testDeviceKeybarReducedRowCount() {
        let usable = visibleTerminalHeight(rawHeight: 417, keybarHeight: 56)
        XCTAssertEqual(usable, 361, accuracy: 1e-9)
        let grid = terminalGrid(width: 402, height: usable, cellWidth: 5.66, cellHeight: 11.15)
        XCTAssertEqual(grid?.rows, 32)
        // Contrast: the buggy full-height path yields 37 (the hidden-rows count).
        let buggy = terminalGrid(width: 402, height: 417, cellWidth: 5.66, cellHeight: 11.15)
        XCTAssertEqual(buggy?.rows, 37)
    }

    // Keyboard-down (kbH sentinel -1) MUST leave the full height so the keyboard-down layout
    // is unchanged (regression guard for the fix's kbH<=0 branch).
    func testKeyboardDownFullHeightRowCount() {
        let usable = visibleTerminalHeight(rawHeight: 417, keybarHeight: -1)
        XCTAssertEqual(usable, 417, accuracy: 1e-9)
        XCTAssertEqual(terminalGrid(width: 402, height: usable, cellWidth: 5.66, cellHeight: 11.15)?.rows, 37)
    }

    // keyboardLayoutGuide gives the keyboard/keybar TOP in container coords; the pane bottom is
    // exactly there. A valid top (e.g. 361 in a 417 container) is the usable height directly.
    func testUsableFromKeyboardTopValid() {
        XCTAssertEqual(usableHeightFromKeyboardTop(rawHeight: 417, keyboardTopY: 361), 361, accuracy: 1e-9)
    }
    // Keyboard down (nil frame) -> full height.
    func testUsableFromKeyboardTopNil() {
        XCTAssertEqual(usableHeightFromKeyboardTop(rawHeight: 417, keyboardTopY: nil), 417, accuracy: 1e-9)
    }
    // Degenerate (top <= 0) -> full height (fail open, no zero/negative pane).
    func testUsableFromKeyboardTopNonPositive() {
        XCTAssertEqual(usableHeightFromKeyboardTop(rawHeight: 417, keyboardTopY: 0), 417, accuracy: 1e-9)
        XCTAssertEqual(usableHeightFromKeyboardTop(rawHeight: 417, keyboardTopY: -5), 417, accuracy: 1e-9)
    }
    // Top beyond the container height (guide reported larger) -> clamp to rawHeight.
    func testUsableFromKeyboardTopBeyond() {
        XCTAssertEqual(usableHeightFromKeyboardTop(rawHeight: 417, keyboardTopY: 500), 417, accuracy: 1e-9)
    }
    // Compose to the row count: 361 top, 11.15 cell -> 32 rows (the correct fit).
    func testUsableFromKeyboardTopComposesToRows() {
        let usable = usableHeightFromKeyboardTop(rawHeight: 417, keyboardTopY: 361)
        XCTAssertEqual(terminalGrid(width: 402, height: usable, cellWidth: 5.66, cellHeight: 11.15)?.rows, 32)
    }

    // MARK: keybarSafeAreaReservation (2026-08-08 root-cause fix)
    // The bottom safe-area reservation for the keybar accessory. The build-121 diagnostic
    // proved accH (the accessory's off-screen content measurement) is the one stable signal;
    // this helper is the whole reservation policy that both containers apply.

    // First responder + measured accH -> reserve exactly accH (device: accH 56 -> 56).
    func testReservationFirstResponderReservesAccH() {
        XCTAssertEqual(keybarSafeAreaReservation(accessoryHeight: 56, isFirstResponder: true), 56, accuracy: 1e-9)
    }
    // Not first responder (keyboard down, no accessory shown) -> reserve nothing, even if a
    // stale accH is passed. This is the state where guideTop==bounds; reservation must be 0.
    func testReservationNotFirstResponderReservesZero() {
        XCTAssertEqual(keybarSafeAreaReservation(accessoryHeight: 56, isFirstResponder: false), 0, accuracy: 1e-9)
    }
    // accH sentinel -1 (firstResponderKeybarHeight() when no accessory) -> 0.
    func testReservationSentinelNegativeReservesZero() {
        XCTAssertEqual(keybarSafeAreaReservation(accessoryHeight: -1, isFirstResponder: true), 0, accuracy: 1e-9)
    }
    // BVA at 0: accH exactly 0 -> 0 (no negative, no spurious reservation).
    func testReservationZeroAccHReservesZero() {
        XCTAssertEqual(keybarSafeAreaReservation(accessoryHeight: 0, isFirstResponder: true), 0, accuracy: 1e-9)
    }
    // The three build-121 device samples: bounds - reservation must equal the correct keybar top.
    // (bounds 453/499/431, accH 56 -> reserved band 56 -> usable 397/443/375.)
    func testReservationDeviceSamplesComposeToCorrectUsable() {
        for (bounds, expectedUsable) in [(453.0, 397.0), (499.0, 443.0), (431.0, 375.0)] {
            let reserved = keybarSafeAreaReservation(accessoryHeight: 56, isFirstResponder: true)
            XCTAssertEqual(bounds - reserved, expectedUsable, accuracy: 1e-9)
        }
    }
}
