// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import SemicolynKit

final class SettingsSectionTests: XCTestCase {
    func testTipsAndDiagnosticsCasesExist() {
        XCTAssertEqual(SettingsSection.tips.rawValue, "tips")
        XCTAssertEqual(SettingsSection.diagnostics.rawValue, "diagnostics")
    }

    func testExperimentalIsGone() {
        XCTAssertNil(SettingsSection(rawValue: "experimental"))
    }
}
