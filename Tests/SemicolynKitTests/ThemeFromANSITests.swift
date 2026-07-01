// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ThemeFromANSITests: XCTestCase {
    private func palette() -> ANSIPalette {
        // Distinct, recognizable colors per slot.
        ANSIPalette([
            ThemeColor("#101010"), // black 0
            ThemeColor("#E5455E"), // red 1  (crimson)
            ThemeColor("#5FB0A2"), // green 2
            ThemeColor("#F5A524"), // yellow 3 (amber)
            ThemeColor("#6E80FF"), // blue 4
            ThemeColor("#B98CFF"), // magenta 5
            ThemeColor("#33C9DC"), // cyan 6
            ThemeColor("#E8ECF5"), // white 7
            ThemeColor("#2A2A2A"), // brightBlack 8
            ThemeColor("#FF6F5E"), // brightRed 9 (coral)
            ThemeColor("#7CF0BE"), // brightGreen 10
            ThemeColor("#FFC860"), // brightYellow 11
            ThemeColor("#9FADFF"), // brightBlue 12
            ThemeColor("#D0B0FF"), // brightMagenta 13
            ThemeColor("#7FE0FF"), // brightCyan 14
            ThemeColor("#FFFFFF"), // brightWhite 15
        ])
    }

    private func makeTheme() -> Theme {
        Theme.fromANSI(
            ansi: palette(),
            roles: ANSIRoleMap(accentPrimary: .brightRed, success: .green,
                               degraded: .yellow, broken: .red, warning: .yellow),
            highlight: ThemeColor("#FFB7A6"),
            surface: .init(bg: ThemeColor("#07090E"), panel: ThemeColor("#0E1118"),
                           panelHigh: ThemeColor("#161A24"), line: ThemeColor("#232A3A")),
            text: .init(primary: ThemeColor("#E8EBF0"), secondary: ThemeColor("#8A93A3"),
                        muted: ThemeColor("#8A93A3"), inverse: ThemeColor("#05070B")),
            terminal: .init(bg: ThemeColor("#05070B"), fg: ThemeColor("#CFD6E4"))
        )
    }

    func testAccentPrimaryResolvesFromSlot() {
        // accent.primary must equal the brightRed slot (coral), NOT a raw literal.
        XCTAssertEqual(makeTheme().accent.primary, ThemeColor("#FF6F5E"))
    }

    func testHighlightIsAuthoredNotDerived() {
        XCTAssertEqual(makeTheme().accent.highlight, ThemeColor("#FFB7A6"))
    }

    func testStateColorsResolveFromSlots() {
        let t = makeTheme()
        XCTAssertEqual(t.state.success, ThemeColor("#5FB0A2")) // green slot
        XCTAssertEqual(t.state.broken, ThemeColor("#E5455E"))  // red slot
        XCTAssertEqual(t.state.warning, ThemeColor("#F5A524")) // yellow slot
        XCTAssertEqual(t.state.degraded, ThemeColor("#F5A524")) // yellow slot
    }

    func testAccentAndBrokenAreDistinct() {
        // The coral-vs-crimson separation must survive derivation.
        let t = makeTheme()
        XCTAssertNotEqual(t.accent.primary, t.state.broken)
    }

    func testBellAndFocusDeriveFromAccent() {
        let t = makeTheme()
        XCTAssertEqual(t.bell.edge, t.accent.primary)
        XCTAssertEqual(t.focus.paneBorder, t.accent.primary)
        XCTAssertEqual(t.focus.paneBorderInactive, t.surface.line)
    }

    func testKeybarLadderDerivesFromAccent() {
        let t = makeTheme()
        XCTAssertEqual(t.keybar.slotBgPromoted, ThemeColor("#FF6F5E", opacity: 0.12))
        XCTAssertEqual(t.keybar.slotBgArmed,    ThemeColor("#FF6F5E", opacity: 0.20))
        XCTAssertEqual(t.keybar.slotBgLocked,   ThemeColor("#FF6F5E", opacity: 0.30))
    }

    func testAnsiPaletteIsStored() {
        XCTAssertEqual(makeTheme().ansi[.brightBlue], ThemeColor("#9FADFF"))
    }

    func testTerminalDefaultsForNewFields() {
        // cursor/cursorText/selection default when omitted.
        let term = Theme.Terminal(bg: ThemeColor("#05070B"), fg: ThemeColor("#CFD6E4"))
        XCTAssertEqual(term.cursor, ThemeColor("#CFD6E4"))        // defaults to fg
        XCTAssertEqual(term.cursorText, ThemeColor("#05070B"))   // defaults to bg
        XCTAssertEqual(term.selection, ThemeColor("#CFD6E4", opacity: 0.30)) // fg @ 30%
    }
}
