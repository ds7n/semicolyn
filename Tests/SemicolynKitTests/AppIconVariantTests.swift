// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class AppIconVariantTests: XCTestCase {
    func testCatalogIntegrity() {
        let c = AppIconVariant.catalog
        XCTAssertEqual(c.map(\.id), ["midnight-dark", "midnight-light", "bronze-dark", "bronze-light",
                                     "cobalt-dark", "cobalt-light", "glacier-dark", "glacier-light"])
        XCTAssertEqual(c.filter { $0.alternateIconName == nil }.map(\.id), ["midnight-dark"])
        XCTAssertEqual(Set(c.compactMap(\.alternateIconName)).count, 7)
        XCTAssertEqual(c.filter(\.isSupporter).map(\.id),
                       ["bronze-dark", "bronze-light", "cobalt-dark", "cobalt-light",
                        "glacier-dark", "glacier-light"])
        XCTAssertEqual(AppIconVariant.defaultIcon.id, "midnight-dark")
    }

    func testAssetNamesMatchTheRenderScript() {
        let row = AppIconVariant.catalog.first { $0.id == "bronze-light" }
        XCTAssertEqual(row?.displayName, "Bronze Light")
        XCTAssertEqual(row?.alternateIconName, "AppIcon-BronzeLight")
        XCTAssertEqual(row?.previewAssetName, "IconPreview-BronzeLight")
        XCTAssertEqual(AppIconVariant.defaultIcon.previewAssetName, "IconPreview-MidnightDark")
    }

    func testVisibleIconsAppStore() {
        XCTAssertEqual(visibleIcons(channel: .appStore).map(\.id), ["midnight-dark", "midnight-light"])
    }

    func testVisibleIconsUnknownMatchesAppStore() {
        XCTAssertEqual(visibleIcons(channel: .unknown).map(\.id), ["midnight-dark", "midnight-light"])
    }

    func testVisibleIconsTestFlightAllEight() {
        XCTAssertEqual(visibleIcons(channel: .testFlight).map(\.id), AppIconVariant.catalog.map(\.id))
    }

    func testNilNameResolvesToDefault() {
        XCTAssertEqual(resolveIcon(currentAlternateName: nil, unlocked: false).id, "midnight-dark")
    }

    func testFreeAlternateKeptWhenLocked() {
        XCTAssertEqual(resolveIcon(currentAlternateName: "AppIcon-MidnightLight", unlocked: false).id,
                       "midnight-light")
    }

    func testSupporterIconRevertsWhenLocked() {
        XCTAssertEqual(resolveIcon(currentAlternateName: "AppIcon-BronzeLight", unlocked: false).id,
                       "midnight-dark")
    }

    func testSupporterIconKeptWhenUnlocked() {
        XCTAssertEqual(resolveIcon(currentAlternateName: "AppIcon-BronzeLight", unlocked: true).id,
                       "bronze-light")
    }

    func testUnknownAlternateNameResolvesToDefault() {
        XCTAssertEqual(resolveIcon(currentAlternateName: "AppIcon-Retired", unlocked: true).id,
                       "midnight-dark")
    }
}
