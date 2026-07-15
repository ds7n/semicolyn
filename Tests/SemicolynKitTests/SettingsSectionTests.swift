// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import SemicolynKit

final class SettingsSectionTests: XCTestCase {
    func testExperimentalCaseExists() {
        XCTAssertTrue(SettingsSection.allCases.contains(.experimental))
        XCTAssertEqual(SettingsSection.experimental.rawValue, "experimental")
    }
}
