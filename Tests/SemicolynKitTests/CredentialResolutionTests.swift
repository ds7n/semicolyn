// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Decides how `SessionView` should obtain credentials before connecting. The
/// backend (`ConnectionViewModel.authenticate`) already prefers publickey when the
/// host has a usable identity; this pure helper mirrors that precedence so the UI
/// does not force a password prompt on a key-configured host (the "key auth coming
/// in 2b" regression). Inputs are the two facts the app tier can cheaply establish.
final class CredentialResolutionTests: XCTestCase {
    // A usable key present → connect via key, regardless of a stored password.
    func testUsableKeyConnectsWithKeyEvenIfPasswordStored() {
        XCTAssertEqual(
            credentialResolution(hasUsableKey: true, hasStoredPassword: true),
            .connectWithKey)
    }

    // Usable key, no stored password → still key (this is the regression case:
    // previously fell through to the password prompt).
    func testUsableKeyNoPasswordConnectsWithKey() {
        XCTAssertEqual(
            credentialResolution(hasUsableKey: true, hasStoredPassword: false),
            .connectWithKey)
    }

    // No key but a stored password → auto-connect with the stored password.
    func testNoKeyStoredPasswordConnectsWithStoredPassword() {
        XCTAssertEqual(
            credentialResolution(hasUsableKey: false, hasStoredPassword: true),
            .connectWithStoredPassword)
    }

    // No key and no stored password → the only case that prompts for a password.
    func testNoKeyNoPasswordPromptsForPassword() {
        XCTAssertEqual(
            credentialResolution(hasUsableKey: false, hasStoredPassword: false),
            .promptForPassword)
    }
}
