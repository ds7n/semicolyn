// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class SettingsGateTests: XCTestCase {
    // In-session: every section enabled.
    func testAllSectionsEnabledInSession() {
        for s in SettingsSection.allCases {
            XCTAssertTrue(SettingsGate.isEnabled(s, in: .inSession),
                          "\(s) should be enabled in-session")
        }
    }
    // Pre-connect: keybar + launcher disabled; the other five enabled.
    func testKeybarDisabledPreConnect() {
        XCTAssertFalse(SettingsGate.isEnabled(.keybar, in: .preConnect))
    }
    func testLauncherDisabledPreConnect() {
        XCTAssertFalse(SettingsGate.isEnabled(.launcher, in: .preConnect))
    }
    func testAppearanceEnabledPreConnect() {
        XCTAssertTrue(SettingsGate.isEnabled(.appearance, in: .preConnect))
    }
    func testTerminalEnabledPreConnect() {
        XCTAssertTrue(SettingsGate.isEnabled(.terminal, in: .preConnect))
    }
    func testDefaultsEnabledPreConnect() {
        XCTAssertTrue(SettingsGate.isEnabled(.defaults, in: .preConnect))
    }
    func testPrivacyEnabledPreConnect() {
        XCTAssertTrue(SettingsGate.isEnabled(.privacy, in: .preConnect))
    }
    func testDiagnosticsEnabledPreConnect() {
        XCTAssertTrue(SettingsGate.isEnabled(.diagnostics, in: .preConnect))
    }
    // Section vocabulary is stable (guards accidental add/remove).
    func testSectionCount() {
        XCTAssertEqual(SettingsSection.allCases.count, 7)
    }
}
