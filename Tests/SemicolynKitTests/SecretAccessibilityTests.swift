// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Security audit M4: credentials are readable only while the device is unlocked.
final class SecretAccessibilityTests: XCTestCase {
    private let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private func access(_ ref: SecretRef) -> SecretAccessibility {
        secretAccessibility(forAccount: keychainAccount(for: ref))
    }

    // Credentials: the class that matters.
    func testPrivateKeyIsWhenUnlocked() {
        XCTAssertEqual(access(.privateKey(identityID: id)), .whenUnlocked)
    }

    func testPasswordIsWhenUnlocked() {
        XCTAssertEqual(access(.password(id: id)), .whenUnlocked)
    }

    func testPassphraseIsWhenUnlocked() {
        XCTAssertEqual(access(.passphrase(identityID: id)), .whenUnlocked)
    }

    // Read at launch (possibly before unlock) or for reattach; none signs anyone in.
    func testRecordKeyStaysAfterFirstUnlock() {
        XCTAssertEqual(access(.recordKey), .afterFirstUnlock)
    }

    func testHostKeysStayAfterFirstUnlock() {
        XCTAssertEqual(access(.hostKeys(hostID: id)), .afterFirstUnlock)
    }

    func testResumeSecretStaysAfterFirstUnlock() {
        XCTAssertEqual(access(.resumeSecret(sessionID: id)), .afterFirstUnlock)
    }

    // Adversarial: anything not recognised fails toward the stricter class, including
    // near-misses of the relaxed names.
    func testUnknownAccountIsWhenUnlocked() {
        XCTAssertEqual(secretAccessibility(forAccount: "somethingNew/\(id)"), .whenUnlocked)
        XCTAssertEqual(secretAccessibility(forAccount: ""), .whenUnlocked)
    }

    func testNearMissesOfRelaxedAccountsAreWhenUnlocked() {
        XCTAssertEqual(secretAccessibility(forAccount: "recordKeyX"), .whenUnlocked)
        XCTAssertEqual(secretAccessibility(forAccount: "recordkey"), .whenUnlocked)
        XCTAssertEqual(secretAccessibility(forAccount: "hostKeys"), .whenUnlocked)
        XCTAssertEqual(secretAccessibility(forAccount: "xhostKeys/\(id)"), .whenUnlocked)
        XCTAssertEqual(secretAccessibility(forAccount: "privateKey/hostKeys/\(id)"), .whenUnlocked)
    }
}
