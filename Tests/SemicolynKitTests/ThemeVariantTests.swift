// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ThemeVariantTests: XCTestCase {
    func testSystemFollowsDarkPhone() { XCTAssertEqual(resolveVariant(mode: .system, systemIsDark: true), .dark) }
    func testSystemFollowsLightPhone() { XCTAssertEqual(resolveVariant(mode: .system, systemIsDark: false), .light) }
    func testForcedLightOnDarkPhone() { XCTAssertEqual(resolveVariant(mode: .light, systemIsDark: true), .light) }
    func testForcedLightOnLightPhone() { XCTAssertEqual(resolveVariant(mode: .light, systemIsDark: false), .light) }
    func testForcedDarkOnLightPhone() { XCTAssertEqual(resolveVariant(mode: .dark, systemIsDark: false), .dark) }
    func testForcedDarkOnDarkPhone() { XCTAssertEqual(resolveVariant(mode: .dark, systemIsDark: true), .dark) }

    func testPickerOrder() {
        XCTAssertEqual(AppearanceMode.allCases, [.system, .light, .dark])
    }

    func testDisplayNames() {
        XCTAssertEqual(AppearanceMode.allCases.map(\.displayName), ["System", "Light", "Dark"])
    }

    func testRawValuesRoundTrip() {
        XCTAssertEqual(AppearanceMode.allCases.map(\.rawValue), ["system", "light", "dark"])
        XCTAssertEqual(AppearanceMode(rawValue: "light"), .light)
    }

    func testUnknownRawValueIsNil() {
        XCTAssertNil(AppearanceMode(rawValue: "sepia"))
    }

    func testDefaultIsSystem() {
        XCTAssertEqual(AppearanceMode.defaultMode, .system)
    }
}
