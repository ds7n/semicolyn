// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// D-8: the "≡" corner button shows only when the keybar is not on screen.
final class SessionMenuTests: XCTestCase {
    private func visible(inShell: Bool = true, attached: Bool, hw: Bool, hide: Bool) -> Bool {
        sessionMenuButtonVisible(inShell: inShell, keybarAttached: attached,
                                 hardwareKeyboardConnected: hw, hideKeybarWithHardwareKeyboard: hide)
    }

    func testHiddenWhileKeybarIsOnScreen() {
        // Software keyboard up with the keybar riding on it.
        XCTAssertFalse(visible(attached: true, hw: false, hide: false))
        // The "hide with hardware keyboard" setting alone (no hardware keyboard) changes nothing.
        XCTAssertFalse(visible(attached: true, hw: false, hide: true))
        // Hardware keyboard attached, compact bar shown (setting off).
        XCTAssertFalse(visible(attached: true, hw: true, hide: false))
    }

    func testShownWhenKeyboardIsDown() {
        XCTAssertTrue(visible(attached: false, hw: false, hide: false))
        XCTAssertTrue(visible(attached: false, hw: true, hide: false))
        XCTAssertTrue(visible(attached: false, hw: true, hide: true))
    }

    func testShownWhenKeybarHiddenByHardwareKeyboardSetting() {
        XCTAssertTrue(visible(attached: true, hw: true, hide: true))
    }

    func testNeverShownOutsideAShell() {
        for attached in [false, true] {
            for hw in [false, true] {
                for hide in [false, true] {
                    XCTAssertFalse(visible(inShell: false, attached: attached, hw: hw, hide: hide))
                }
            }
        }
    }

    func testSessionTitle() {
        XCTAssertEqual(sessionMenuTitle(hostLabel: "prod-web", transport: .mosh), "prod-web · Mosh")
        XCTAssertEqual(sessionMenuTitle(hostLabel: "nas", transport: .et), "nas · Eternal Terminal")
        XCTAssertEqual(sessionMenuTitle(hostLabel: "pi", transport: .ssh), "pi · SSH")
    }

    func testActiveSessionTransport() {
        XCTAssertEqual(activeSessionTransport(moshActive: false, etActive: false), .ssh)
        XCTAssertEqual(activeSessionTransport(moshActive: true, etActive: false), .mosh)
        XCTAssertEqual(activeSessionTransport(moshActive: false, etActive: true), .et)
    }
}
