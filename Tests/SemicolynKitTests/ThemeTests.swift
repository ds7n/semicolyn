// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ThemeTests: XCTestCase {
    func testBellBronzeAccentIsBronze500() {
        XCTAssertEqual(Theme.bellBronze.accent.primary, ThemeColor("#D49A5C"))
    }

    func testSharedReferenceIsDriftProof() {
        // bell.edge and accent.primary both map to bronze500 — same value.
        XCTAssertEqual(Theme.bellBronze.bell.edge, Theme.bellBronze.accent.primary)
    }

    func testAlphaProducesOpacityVariant() {
        let promoted = Theme.bellBronze.keybar.slotBgPromoted
        XCTAssertEqual(promoted, ThemeColor("#D49A5C", opacity: 0.12))
    }

    func testRegistryOrderMidnightBronzeCobaltGlacier() {
        XCTAssertEqual(Theme.all.count, 4)
        XCTAssertEqual(Theme.all[0], Theme.neonMidnight)   // default is first
        XCTAssertEqual(Theme.all[1], Theme.bellBronze)     // bronze retained, second
        XCTAssertEqual(Theme.all[2], Theme.neonCobalt)     // electric blue, third
        XCTAssertEqual(Theme.all[3], Theme.glacier)        // soft blue, fourth
    }

    func testNeonMidnightAccentIsCoral() {
        XCTAssertEqual(Theme.neonMidnight.accent.primary, ThemeColor("#FF6F5E"))
        XCTAssertEqual(Theme.neonMidnight.accent.highlight, ThemeColor("#FFB7A6"))
    }

    func testNeonMidnightBellEdgeMatchesAccent() {
        XCTAssertEqual(Theme.neonMidnight.bell.edge, Theme.neonMidnight.accent.primary)
    }

    func testNeonMidnightErrorIsDistinctFromAccent() {
        // The coral-vs-error separation: error must be its own cooler crimson.
        XCTAssertEqual(Theme.neonMidnight.state.broken, ThemeColor("#E5455E"))
        XCTAssertNotEqual(Theme.neonMidnight.state.broken, Theme.neonMidnight.accent.primary)
    }

    func testNeonMidnightSurfacesAreDarkerNight() {
        XCTAssertEqual(Theme.neonMidnight.surface.bg, ThemeColor("#07090E"))
        XCTAssertEqual(Theme.neonMidnight.terminal.bg, ThemeColor("#05070B"))
    }

    func testNeonMidnightSuccessIsVerdigris() {
        XCTAssertEqual(Theme.neonMidnight.state.success, ThemeColor("#5FB0A2"))
    }

    func testNeonMidnightKeybarLadder() {
        XCTAssertEqual(Theme.neonMidnight.keybar.slotBgPromoted, ThemeColor("#FF6F5E", opacity: 0.12))
        XCTAssertEqual(Theme.neonMidnight.keybar.slotBgArmed,    ThemeColor("#FF6F5E", opacity: 0.20))
        XCTAssertEqual(Theme.neonMidnight.keybar.slotBgLocked,   ThemeColor("#FF6F5E", opacity: 0.30))
    }

    func testRgbaParsesHexAndOpacity() {
        let c = ThemeColor("#D49A5C", opacity: 0.5).rgba()
        XCTAssertEqual(c.red,   Double(0xD4) / 255, accuracy: 0.0001)
        XCTAssertEqual(c.green, Double(0x9A) / 255, accuracy: 0.0001)
        XCTAssertEqual(c.blue,  Double(0x5C) / 255, accuracy: 0.0001)
        XCTAssertEqual(c.opacity, 0.5, accuracy: 0.0001)
    }

    func testRgbaBoundaryHexValues() {
        // Boundary-value analysis: the extremes of the channel range.
        let black = ThemeColor("#000000").rgba()
        XCTAssertEqual(black.red, 0, accuracy: 0.0001)
        XCTAssertEqual(black.green, 0, accuracy: 0.0001)
        XCTAssertEqual(black.blue, 0, accuracy: 0.0001)

        let white = ThemeColor("#FFFFFF").rgba()
        XCTAssertEqual(white.red, 1, accuracy: 0.0001)
        XCTAssertEqual(white.green, 1, accuracy: 0.0001)
        XCTAssertEqual(white.blue, 1, accuracy: 0.0001)
    }

    func testRgbaMalformedHexFallsBackToZero() {
        // Invalid partition: a non-hex string yields the documented (0,0,0)
        // fallback rather than crashing.
        let c = ThemeColor("#ZZTOP!", opacity: 0.8).rgba()
        XCTAssertEqual(c.red, 0, accuracy: 0.0001)
        XCTAssertEqual(c.green, 0, accuracy: 0.0001)
        XCTAssertEqual(c.blue, 0, accuracy: 0.0001)
        XCTAssertEqual(c.opacity, 0.8, accuracy: 0.0001)
    }

    func testNeonMidnightAnsiCoralAndCrimsonSlots() {
        // accent(coral) lives in brightRed; error(crimson) in red — kept distinct.
        XCTAssertEqual(Theme.neonMidnight.ansi[.brightRed], ThemeColor("#FF6F5E"))
        XCTAssertEqual(Theme.neonMidnight.ansi[.red], ThemeColor("#E5455E"))
    }

    func testNeonMidnightAnsiHasSixteen() {
        XCTAssertEqual(Theme.neonMidnight.ansi.ordered().count, 16)
    }

    func testNeonMidnightTerminalCursorIsAccent() {
        XCTAssertEqual(Theme.neonMidnight.terminal.cursor, ThemeColor("#FF6F5E"))
    }

    func testBellBronzeAnsiYellowIsBronze() {
        // Bronze is the theme's warm hue → occupies the yellow slot; accent refs it.
        XCTAssertEqual(Theme.bellBronze.ansi[.yellow], ThemeColor("#D49A5C"))
        XCTAssertEqual(Theme.bellBronze.accent.primary, ThemeColor("#D49A5C"))
    }

    func testBellBronzeAnsiHasSixteen() {
        XCTAssertEqual(Theme.bellBronze.ansi.ordered().count, 16)
    }
}
