// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import SemicolynKit

/// M-57: the Settings tree (un-headed Appearance/Terminal, then Input, Connections,
/// Privacy, Help).
final class SettingsSectionTests: XCTestCase {
    func testGroupHeadersInOrder() {
        XCTAssertEqual(SettingsLayout.groups.map(\.header),
                       [nil, "Input", "Connections", "Privacy", "Help"])
    }

    func testGroupRowsInOrder() {
        XCTAssertEqual(SettingsLayout.groups.map(\.sections), [
            [.appearance, .terminal],
            [.keybar, .macros, .keyboard],
            [.defaults],
            [.privacy],
            [.tips, .diagnostics],
        ])
    }

    func testEverySectionAppearsExactlyOnce() {
        let listed = SettingsLayout.groups.flatMap(\.sections)
        XCTAssertEqual(listed.count, SettingsSection.allCases.count)
        XCTAssertEqual(Set(listed), Set(SettingsSection.allCases))
    }

    func testRowTitles() {
        XCTAssertEqual(SettingsLayout.groups.flatMap(\.sections).map(\.title), [
            "Appearance", "Terminal",
            "Keybar", "Macros", "Keyboard",
            "Connection Defaults",
            "Suggestions & Privacy",
            "Tips & Gestures", "Diagnostics",
        ])
    }

    func testSymbolsAreDistinct() {
        let symbols = SettingsSection.allCases.map(\.symbol)
        XCTAssertEqual(Set(symbols).count, symbols.count)
        XCTAssertEqual(SettingsSection.macros.symbol, "command")
    }

    func testExperimentalAndLauncherAreGone() {
        XCTAssertNil(SettingsSection(rawValue: "experimental"))
        XCTAssertNil(SettingsSection(rawValue: "launcher"))
    }
}
