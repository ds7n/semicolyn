// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class PrivacyPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "PrivacyPreferencesTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    // MARK: clipboard options

    // The user's copy stays on this device unless sharing is on.
    func testAppCopyLocalOnlyUnlessSharing() {
        XCTAssertEqual(clipboardWriteOptions(source: .app, shareAcrossDevices: false, clearAfter: .never),
                       ClipboardWriteOptions(localOnly: true, expiresAfter: nil))
        XCTAssertEqual(clipboardWriteOptions(source: .app, shareAcrossDevices: true, clearAfter: .never),
                       ClipboardWriteOptions(localOnly: false, expiresAfter: nil))
    }

    // Adversarial: a server's OSC 52 copy never leaves the device, even with sharing on.
    func testServerCopyAlwaysLocalOnly() {
        XCTAssertEqual(clipboardWriteOptions(source: .server, shareAcrossDevices: true, clearAfter: .never),
                       ClipboardWriteOptions(localOnly: true, expiresAfter: nil))
    }

    // Each clear-after choice maps to its lifetime in seconds, for both sources.
    func testClearAfterSeconds() {
        let expected: [ClipboardClearAfter: Int?] = [.never: nil, .oneMinute: 60,
                                                    .fiveMinutes: 300, .tenMinutes: 600]
        for (choice, seconds) in expected {
            for source in [ClipboardSource.app, .server] {
                XCTAssertEqual(clipboardWriteOptions(source: source, shareAcrossDevices: false,
                                                     clearAfter: choice).expiresAfter, seconds,
                               "\(choice) \(source)")
            }
        }
    }

    // MARK: app-switcher cover

    func testCoverUpWheneverNotActive() {
        XCTAssertFalse(privacyCoverVisible(.active, enabled: true))
        XCTAssertTrue(privacyCoverVisible(.inactive, enabled: true))
        XCTAssertTrue(privacyCoverVisible(.background, enabled: true))
    }

    func testCoverNeverUpWhenDisabled() {
        for activity in [AppActivity.active, .inactive, .background] {
            XCTAssertFalse(privacyCoverVisible(activity, enabled: false))
        }
    }

    // MARK: stored settings

    // Nothing stored: cover on, sharing off, never clear, third-party keyboards off.
    func testDefaultsWhenUnset() {
        let prefs = PrivacyPreferences(defaults: defaults)
        XCTAssertTrue(prefs.hideInAppSwitcher)
        XCTAssertFalse(prefs.shareCopiesAcrossDevices)
        XCTAssertEqual(prefs.clearCopiedAfter, .never)
        XCTAssertFalse(prefs.allowThirdPartyKeyboards)
    }

    // Stored values are read back (each opposite to its default).
    func testStoredValuesRead() {
        defaults.set(false, forKey: PrivacyPreferences.Key.hideInAppSwitcher)
        defaults.set(true, forKey: PrivacyPreferences.Key.shareCopiesAcrossDevices)
        defaults.set(300, forKey: PrivacyPreferences.Key.clearCopiedAfter)
        defaults.set(true, forKey: PrivacyPreferences.Key.allowThirdPartyKeyboards)
        let prefs = PrivacyPreferences(defaults: defaults)
        XCTAssertFalse(prefs.hideInAppSwitcher)
        XCTAssertTrue(prefs.shareCopiesAcrossDevices)
        XCTAssertEqual(prefs.clearCopiedAfter, .fiveMinutes)
        XCTAssertTrue(prefs.allowThirdPartyKeyboards)
    }

    // An unknown duration or a wrong-typed value falls back to the default.
    func testBadStoredValuesFallBack() {
        defaults.set(42, forKey: PrivacyPreferences.Key.clearCopiedAfter)
        defaults.set("yes", forKey: PrivacyPreferences.Key.allowThirdPartyKeyboards)
        let prefs = PrivacyPreferences(defaults: defaults)
        XCTAssertEqual(prefs.clearCopiedAfter, .never)
        XCTAssertFalse(prefs.allowThirdPartyKeyboards)
    }
}
