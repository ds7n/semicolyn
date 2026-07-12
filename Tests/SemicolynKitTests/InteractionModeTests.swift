// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class InteractionModeTests: XCTestCase {
    // EP: the 4 combinations of (isAltScreen, mouseReporting).
    func testNormalScreenNoMouseIsLocalScroll() {
        XCTAssertEqual(resolveMode(isAltScreen: false, mouseReporting: false), .localScroll)
    }
    func testNormalScreenWithMouseIsMouseReporting() {
        XCTAssertEqual(resolveMode(isAltScreen: false, mouseReporting: true), .mouseReporting)
    }
    func testAltScreenNoMouseIsAppOwnsInput() {
        XCTAssertEqual(resolveMode(isAltScreen: true, mouseReporting: false), .appOwnsInput)
    }
    // The precedence rule: alt-screen wins over mouse (Claude Code case).
    func testAltScreenWithMouseIsAppOwnsInputNotMouseReporting() {
        XCTAssertEqual(resolveMode(isAltScreen: true, mouseReporting: true), .appOwnsInput)
    }
}
