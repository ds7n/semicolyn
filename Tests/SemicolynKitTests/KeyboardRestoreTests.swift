// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// The keyboard-restore decision covers every (isFirstResponder, keyboardVisible) pair.
/// The device bug (build 172) was the (true, false) case: a sheet presented from the keybar
/// hides the keyboard WITHOUT resigning first responder, so `becomeFirstResponder` is a
/// no-op and the only recovery is `reloadInputViews`.
final class KeyboardRestoreTests: XCTestCase {
    func testFocusedButKeyboardHiddenReloadsInputViews() {
        XCTAssertEqual(keyboardRestoreAction(isFirstResponder: true, keyboardVisible: false),
                       .reloadInputViews)
    }

    func testFocusedAndKeyboardVisibleDoesNothing() {
        XCTAssertEqual(keyboardRestoreAction(isFirstResponder: true, keyboardVisible: true), .none)
    }

    func testNotFocusedBecomesFirstResponder() {
        XCTAssertEqual(keyboardRestoreAction(isFirstResponder: false, keyboardVisible: false),
                       .becomeFirstResponder)
    }

    /// Not first responder while an accessory still reports a window is a transitional state
    /// (focus moved elsewhere); reclaiming focus is still the right move.
    func testNotFocusedButAccessoryAttachedStillBecomesFirstResponder() {
        XCTAssertEqual(keyboardRestoreAction(isFirstResponder: false, keyboardVisible: true),
                       .becomeFirstResponder)
    }
}
