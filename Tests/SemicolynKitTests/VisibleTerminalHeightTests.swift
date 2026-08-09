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

    // MARK: rawTerminalChildHeight (2026-08-09 window-space fix)
    // After ~7 fixes that subtracted from an unstable `bounds`, the child height is derived from
    // the keybar accessory's REAL top in window space (accessoryTopY) relative to the container
    // top (containerTopY). The function is PURELY the arithmetic `accessoryTopY - containerTopY`
    // plus a validity guard: it is device-agnostic (no hardcoded phone/font dimensions in the
    // logic, the container reads accessoryTopY/containerTopY/containerHeight/accessoryHeight live
    // on whatever device it runs on). The concrete numbers below are SAMPLE inputs captured from
    // one device (build 124: containerTopY=62, accessoryTopY 493 @ app-switch / 510 @ first-connect,
    // the transient mid-animation value 874 == window height that MUST be rejected). They verify
    // the arithmetic + guard, NOT any device-specific assumption baked into the function.

    // App-switch / gap state (the bug we are fixing): accessoryTopY 493, containerTopY 62,
    // containerHeight 431 -> child 431. Filling this bounds is correct (no gap, no hidden rows).
    func testChildHeightAppSwitchState() throws {
        let h = try XCTUnwrap(rawTerminalChildHeight(accessoryTopY: 493, containerTopY: 62,
                                                     containerHeight: 431, accessoryHeight: 56, isFirstResponder: true))
        XCTAssertEqual(h, 431, accuracy: 1e-9)
    }
    // First-connect state: accessoryTopY 510, containerTopY 62, containerHeight 499 -> child 448.
    // (The old accH-subtraction gave 443; 448 reaches the accessory's real frame top.)
    func testChildHeightFirstConnectState() throws {
        let h = try XCTUnwrap(rawTerminalChildHeight(accessoryTopY: 510, containerTopY: 62,
                                                     containerHeight: 499, accessoryHeight: 56, isFirstResponder: true))
        XCTAssertEqual(h, 448, accuracy: 1e-9)
    }
    // The mid-animation transient (accessoryTopY == window height, above the container's bottom
    // edge at 62+431=493) MUST be rejected so the caller holds its last-known-good height.
    func testChildHeightRejectsMidAnimationTransient() {
        let h = rawTerminalChildHeight(accessoryTopY: 874, containerTopY: 62,
                                       containerHeight: 431, accessoryHeight: 56, isFirstResponder: true)
        XCTAssertNil(h)
    }
    // Not first responder (keyboard down, no accessory) -> nil (caller fills bounds / full height).
    func testChildHeightNilWhenNotFirstResponder() {
        XCTAssertNil(rawTerminalChildHeight(accessoryTopY: 493, containerTopY: 62,
                                            containerHeight: 431, accessoryHeight: 56, isFirstResponder: false))
    }
    // Nil accessoryTopY (accessory not reachable this pass) -> nil (hold last-known-good).
    func testChildHeightNilWhenNoAccessoryTop() {
        XCTAssertNil(rawTerminalChildHeight(accessoryTopY: nil, containerTopY: 62,
                                            containerHeight: 431, accessoryHeight: 56, isFirstResponder: true))
    }
    // accH sentinel -1 -> nil (no trustworthy accessory).
    func testChildHeightNilWhenSentinelAccH() {
        XCTAssertNil(rawTerminalChildHeight(accessoryTopY: 493, containerTopY: 62,
                                            containerHeight: 431, accessoryHeight: -1, isFirstResponder: true))
    }
    // BVA: keybar top exactly at the container's bottom edge (accessoryTopY == containerTopY +
    // containerHeight) is the interior boundary -> accepted, child == containerHeight (full).
    func testChildHeightBoundaryAtContainerBottomAccepted() throws {
        let h = try XCTUnwrap(rawTerminalChildHeight(accessoryTopY: 493, containerTopY: 62,
                                                     containerHeight: 431, accessoryHeight: 56, isFirstResponder: true))
        XCTAssertEqual(h, 431, accuracy: 1e-9)   // 62+431 == 493, boundary accepted
    }
    // BVA: keybar top one point BELOW the container bottom (494 > 62+431) -> rejected.
    func testChildHeightBoundaryBelowContainerBottomRejected() {
        XCTAssertNil(rawTerminalChildHeight(accessoryTopY: 494, containerTopY: 62,
                                            containerHeight: 431, accessoryHeight: 56, isFirstResponder: true))
    }
    // BVA: keybar top at/above the container top -> rejected (nonsensical, no positive height).
    func testChildHeightRejectsTopAtOrAboveContainerTop() {
        XCTAssertNil(rawTerminalChildHeight(accessoryTopY: 62, containerTopY: 62,
                                            containerHeight: 431, accessoryHeight: 56, isFirstResponder: true))
        XCTAssertNil(rawTerminalChildHeight(accessoryTopY: 40, containerTopY: 62,
                                            containerHeight: 431, accessoryHeight: 56, isFirstResponder: true))
    }
}
