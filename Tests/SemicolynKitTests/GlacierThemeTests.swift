// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Glacier color-fidelity guards. Core tier: assert the exact locked/derived values
/// so palette drift or a wrong role-map slot fails the build. Values come from
/// mockups/drafts/themes/glacier.itermcolors via themes/build.py.
final class GlacierThemeTests: XCTestCase {
    private let theme = Theme.glacier

    // Accent is the soft powder-blue, resolved from the ANSI blue slot.
    func testAccentResolvesFromBlueSlot() {
        XCTAssertEqual(theme.accent.primary, ThemeColor("#8AA6E8"))
        XCTAssertEqual(theme.accent.primary, theme.ansi[.blue])
    }

    func testHighlight() {
        XCTAssertEqual(theme.accent.highlight, ThemeColor("#CAD5F0"))
    }

    // Status colors pin to their semantic slots: soft rose/sage/gold.
    func testStatusColorsPinToSlots() {
        XCTAssertEqual(theme.state.success, ThemeColor("#9DDDB8")) // green (2)
        XCTAssertEqual(theme.state.broken, ThemeColor("#DD9DA1"))  // red (1)
        XCTAssertEqual(theme.state.warning, ThemeColor("#DDCC9D")) // yellow (3)
        XCTAssertEqual(theme.state.degraded, ThemeColor("#DDCC9D")) // yellow (3)
        XCTAssertEqual(theme.state.success, theme.ansi[.green])
        XCTAssertEqual(theme.state.broken, theme.ansi[.red])
    }

    func testAccentAndBrokenDistinct() {
        XCTAssertNotEqual(theme.accent.primary, theme.state.broken)
    }

    // Terminal tokens on the lighter slate base.
    func testTerminalTokens() {
        XCTAssertEqual(theme.terminal.bg, ThemeColor("#151B29"))
        XCTAssertEqual(theme.terminal.fg, ThemeColor("#B8BFCE"))
        XCTAssertEqual(theme.terminal.cursor, ThemeColor("#8AA6E8"))
        XCTAssertEqual(theme.terminal.cursorText, ThemeColor("#151B29"))
        XCTAssertEqual(theme.terminal.selection, ThemeColor("#8AA6E8", opacity: 0.30))
    }

    // Distinctly LIGHTER base than the dark themes — Glacier's defining trait.
    // brightBlack (line source) sits well above near-black; assert the slate ground.
    func testLighterSlateBase() {
        XCTAssertEqual(theme.surface.bg, ThemeColor("#181F30"))
        XCTAssertEqual(theme.surface.panel, ThemeColor("#1D263B"))
        XCTAssertEqual(theme.surface.panelHigh, ThemeColor("#27334F"))
        XCTAssertEqual(theme.surface.line, ThemeColor("#334267"))
    }

    func testAnsiPaletteStored() {
        XCTAssertEqual(theme.ansi[.magenta], ThemeColor("#CC9DDD")) // lavender
        XCTAssertEqual(theme.ansi[.cyan], ThemeColor("#9DD4DD"))    // soft teal
        XCTAssertEqual(theme.ansi.ordered().count, 16)
    }
}
