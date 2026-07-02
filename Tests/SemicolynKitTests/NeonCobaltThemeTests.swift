// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Neon Cobalt color-fidelity guards. Core tier: assert the exact locked/derived
/// values so any palette drift (or a wrong role-map slot) fails the build. Values
/// come from mockups/drafts/themes/neon-cobalt.itermcolors via themes/build.py.
final class NeonCobaltThemeTests: XCTestCase {
    private let theme = Theme.neonCobalt

    // Accent is the periwinkle-cobalt, resolved from the ANSI blue slot (not a literal).
    func testAccentResolvesFromBlueSlot() {
        XCTAssertEqual(theme.accent.primary, ThemeColor("#5A6EFF"))
        XCTAssertEqual(theme.accent.primary, theme.ansi[.blue])
    }

    // Highlight is the derived hot-core (lighten of accent), authored into the theme.
    func testHighlight() {
        XCTAssertEqual(theme.accent.highlight, ThemeColor("#AAB3F7"))
    }

    // Status colors pin to their semantic slots: green/red/amber.
    func testStatusColorsPinToSlots() {
        XCTAssertEqual(theme.state.success, ThemeColor("#4EFDAC")) // green (2)
        XCTAssertEqual(theme.state.broken, ThemeColor("#FD4E66"))  // red (1)
        XCTAssertEqual(theme.state.warning, ThemeColor("#FDCF4E")) // yellow (3)
        XCTAssertEqual(theme.state.degraded, ThemeColor("#FDCF4E")) // yellow (3)
        XCTAssertEqual(theme.state.success, theme.ansi[.green])
        XCTAssertEqual(theme.state.broken, theme.ansi[.red])
    }

    // Accent (blue) and failure (red) must not collide — different roles, different hue.
    func testAccentAndBrokenDistinct() {
        XCTAssertNotEqual(theme.accent.primary, theme.state.broken)
    }

    // Terminal tokens: bg/fg/cursor and the alpha selection.
    func testTerminalTokens() {
        XCTAssertEqual(theme.terminal.bg, ThemeColor("#03040B"))
        XCTAssertEqual(theme.terminal.fg, ThemeColor("#C6CEF0"))
        XCTAssertEqual(theme.terminal.cursor, ThemeColor("#5A6EFF"))
        XCTAssertEqual(theme.terminal.cursorText, ThemeColor("#03040B"))
        XCTAssertEqual(theme.terminal.selection, ThemeColor("#5A6EFF", opacity: 0.30))
    }

    // Derived surfaces are distinct, ascending tint steps off the near-black navy bg.
    func testSurfaceRamp() {
        XCTAssertEqual(theme.surface.bg, ThemeColor("#050713"))
        XCTAssertEqual(theme.surface.panel, ThemeColor("#080B1F"))
        XCTAssertEqual(theme.surface.panelHigh, ThemeColor("#0E1438"))
        XCTAssertEqual(theme.surface.line, ThemeColor("#161D54"))
    }

    // The full 16-color palette is stored; spot-check both a status and a free slot.
    func testAnsiPaletteStored() {
        XCTAssertEqual(theme.ansi[.brightBlue], ThemeColor("#A3B0FF"))
        XCTAssertEqual(theme.ansi[.cyan], ThemeColor("#4EECFD"))
        XCTAssertEqual(theme.ansi.ordered().count, 16)
    }
}
