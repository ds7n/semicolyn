// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class LightThemeTests: XCTestCase {
    func testNeonMidnightLightAnchors() {
        XCTAssertEqual(Theme.neonMidnightLight.surface.bg.hex, "#F7F3EF")
        XCTAssertEqual(Theme.neonMidnightLight.accent.primary.hex, "#C52A18")
    }

    func testBellBronzeLightAnchors() {
        XCTAssertEqual(Theme.bellBronzeLight.surface.bg.hex, "#F6EFE4")
        XCTAssertEqual(Theme.bellBronzeLight.accent.primary.hex, "#8A5B2D")
    }

    func testNeonCobaltLightAnchors() {
        XCTAssertEqual(Theme.neonCobaltLight.surface.bg.hex, "#EEF0FF")
        XCTAssertEqual(Theme.neonCobaltLight.accent.primary.hex, "#394BE6")
    }

    func testGlacierLightAnchors() {
        XCTAssertEqual(Theme.glacierLight.surface.bg.hex, "#E6EBF4")
        XCTAssertEqual(Theme.glacierLight.accent.primary.hex, "#3B5CB4")
    }

    func testThemeForVariantReturnsMatchingHalf() {
        for d in Theme.catalog {
            XCTAssertEqual(d.theme(for: .dark), d.dark, d.id.raw)
            XCTAssertEqual(d.theme(for: .light), d.light, d.id.raw)
            XCTAssertNotEqual(d.light, d.dark, d.id.raw)
        }
    }

    func testLightIsLighterThanDark() {
        for d in Theme.catalog {
            XCTAssertGreaterThan(d.light.surface.bg.relativeLuminance, d.dark.surface.bg.relativeLuminance, d.id.raw)
            XCTAssertGreaterThan(d.light.terminal.bg.relativeLuminance, d.dark.terminal.bg.relativeLuminance, d.id.raw)
        }
    }

    func testCatalogLightMembers() {
        XCTAssertEqual(Theme.catalog.map(\.light),
                       [.neonMidnightLight, .bellBronzeLight, .neonCobaltLight, .glacierLight])
    }

    func testResolveThemeLightVariant() {
        XCTAssertEqual(resolveTheme(selectedID: ThemeID("glacier"), isPro: true, variant: .light), .glacierLight)
    }

    func testResolveThemeGateFallsBackWithinVariant() {
        XCTAssertEqual(resolveTheme(selectedID: ThemeID("glacier"), isPro: false, variant: .light), .neonMidnightLight)
    }

    func testResolveThemeDefaultsToDark() {
        XCTAssertEqual(resolveTheme(selectedID: ThemeID("glacier"), isPro: true), .glacier)
    }

    func testDisplayedDescriptorPreviewLightVariant() {
        let previewed = displayedDescriptor(selectedID: ThemeID("neonMidnight"), previewID: ThemeID("bellBronze"),
                                            isPro: false)
        XCTAssertEqual(previewed.theme(for: .light), .bellBronzeLight)
        let saved = displayedDescriptor(selectedID: ThemeID("neonMidnight"), previewID: nil, isPro: false)
        XCTAssertEqual(saved.theme(for: .light), .neonMidnightLight)
    }

    /// The light derivation keeps the dark theme's role mapping (accent from the same slot).
    func testLightAccentComesFromSameSlotAsDark() {
        XCTAssertEqual(Theme.neonMidnightLight.accent.primary, Theme.neonMidnightLight.ansi[.brightRed])
        XCTAssertEqual(Theme.bellBronzeLight.accent.primary, Theme.bellBronzeLight.ansi[.yellow])
        XCTAssertEqual(Theme.bellBronzeLight.state.warning, Theme.bellBronzeLight.ansi[.brightYellow])
        XCTAssertEqual(Theme.neonCobaltLight.accent.primary, Theme.neonCobaltLight.ansi[.blue])
        XCTAssertEqual(Theme.glacierLight.accent.primary, Theme.glacierLight.ansi[.blue])
    }
}
