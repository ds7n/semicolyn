// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ThemeCatalogTests: XCTestCase {
    func testCatalogOrderAndFlags() {
        XCTAssertEqual(Theme.catalog.count, 4)
        XCTAssertEqual(Theme.catalog[0].id, ThemeID("neonMidnight"))
        XCTAssertFalse(Theme.catalog[0].isPro)
        XCTAssertEqual(Theme.catalog[0].theme, .neonMidnight)
        XCTAssertEqual(Theme.catalog[1].id, ThemeID("bellBronze"))
        XCTAssertTrue(Theme.catalog[1].isPro)
        XCTAssertEqual(Theme.catalog[1].theme, .bellBronze)
        XCTAssertEqual(Theme.catalog[2].id, ThemeID("neonCobalt"))
        XCTAssertTrue(Theme.catalog[2].isPro)
        XCTAssertEqual(Theme.catalog[2].theme, .neonCobalt)
        XCTAssertEqual(Theme.catalog[3].id, ThemeID("glacier"))
        XCTAssertTrue(Theme.catalog[3].isPro)
        XCTAssertEqual(Theme.catalog[3].theme, .glacier)
    }

    // Gate: the new blue Pro themes unlock with Pro, fall back to default without.
    func testResolveNeonCobaltGate() {
        XCTAssertEqual(resolveTheme(selectedID: ThemeID("neonCobalt"), isPro: true), .neonCobalt)
        XCTAssertEqual(resolveTheme(selectedID: ThemeID("neonCobalt"), isPro: false), .neonMidnight)
    }

    func testResolveGlacierGate() {
        XCTAssertEqual(resolveTheme(selectedID: ThemeID("glacier"), isPro: true), .glacier)
        XCTAssertEqual(resolveTheme(selectedID: ThemeID("glacier"), isPro: false), .neonMidnight)
    }

    func testCatalogIDsAreUnique() {
        let ids = Theme.catalog.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testDefaultDescriptorIsFirstAndFree() {
        XCTAssertEqual(Theme.defaultDescriptor.id, ThemeID("neonMidnight"))
        XCTAssertFalse(Theme.defaultDescriptor.isPro)
    }

    func testAllDerivesFromCatalog() {
        XCTAssertEqual(Theme.all, Theme.catalog.map(\.theme))
    }

    // Gate: free theme always applies.
    func testResolveFreeThemeAlwaysApplies() {
        XCTAssertEqual(resolveTheme(selectedID: ThemeID("neonMidnight"), isPro: false), .neonMidnight)
        XCTAssertEqual(resolveTheme(selectedID: ThemeID("neonMidnight"), isPro: true), .neonMidnight)
    }

    // Gate: pro theme applies only with Pro.
    func testResolveProThemeWithProApplies() {
        XCTAssertEqual(resolveTheme(selectedID: ThemeID("bellBronze"), isPro: true), .bellBronze)
    }

    // Gate negative (security-relevant): pro theme without Pro falls back to default.
    func testResolveProThemeWithoutProFallsBackToDefault() {
        XCTAssertEqual(resolveTheme(selectedID: ThemeID("bellBronze"), isPro: false), .neonMidnight)
    }

    // Gate negative: unknown id falls back to default.
    func testResolveUnknownIDFallsBackToDefault() {
        XCTAssertEqual(resolveTheme(selectedID: ThemeID("does-not-exist"), isPro: true), .neonMidnight)
    }

    // resolveDescriptor reports the *applied* identity (not the raw selection).
    func testResolveDescriptorReportsAppliedIdentityOnLockedTheme() {
        let applied = resolveDescriptor(selectedID: ThemeID("bellBronze"), isPro: false)
        XCTAssertEqual(applied.id, ThemeID("neonMidnight"))
    }

    // Injection contract: fallback uses catalog[0] from the injected catalog, not global default.
    func testResolveDescriptorInjectedCatalogFallbackHonored() {
        let customCatalog: [ThemeDescriptor] = [
            ThemeDescriptor(id: ThemeID("customFree"), displayName: "Custom Free",
                            isPro: false, theme: .bellBronze),
            ThemeDescriptor(id: ThemeID("customPro"), displayName: "Custom Pro",
                            isPro: true, theme: .neonMidnight),
        ]
        let result = resolveDescriptor(selectedID: ThemeID("unknown"), isPro: false, catalog: customCatalog)
        XCTAssertEqual(result.id, ThemeID("customFree"))
    }

    func testThemeIDCodableRoundTrip() throws {
        let original = ThemeID("bellBronze")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ThemeID.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
