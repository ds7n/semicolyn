// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// WCAG contrast floors from the light-theme-variants spec, checked for all eight
/// variants so neither a light palette nor a later dark tweak can regress readability.
final class ThemeContrastFloorTests: XCTestCase {
    /// Shipped dark colors that miss a floor; out of scope for the light-variants work.
    private let knownExceptions: Set<String> = ["glacier dark secondary on panel"]

    private var variants: [(name: String, theme: Theme, isLight: Bool)] {
        Theme.catalog.flatMap { d in
            [("\(d.id.raw) dark", d.dark, false), ("\(d.id.raw) light", d.light, true)]
        }
    }

    private func assertFloor(_ pair: String, _ fg: ThemeColor, _ bg: ThemeColor, _ floor: Double,
                             theme: String, file: StaticString = #filePath, line: UInt = #line) {
        guard !knownExceptions.contains("\(theme) \(pair)") else { return }
        let ratio = contrastRatio(fg, bg)
        XCTAssertGreaterThanOrEqual(ratio, floor, String(format: "%@ %@: %.2f < %.1f", theme, pair, ratio, floor),
                                    file: file, line: line)
    }

    func testPrimaryTextFloor() {
        for v in variants {
            assertFloor("text on bg", v.theme.text.primary, v.theme.surface.bg, 7, theme: v.name)
            assertFloor("text on panel", v.theme.text.primary, v.theme.surface.panel, 7, theme: v.name)
        }
    }

    func testSecondaryTextFloor() {
        for v in variants {
            assertFloor("secondary on bg", v.theme.text.secondary, v.theme.surface.bg, 4.5, theme: v.name)
            assertFloor("secondary on panel", v.theme.text.secondary, v.theme.surface.panel, 4.5, theme: v.name)
        }
    }

    func testAccentFloor() {
        for v in variants {
            assertFloor("accent on bg", v.theme.accent.primary, v.theme.surface.bg, 4.5, theme: v.name)
            assertFloor("accent on panel", v.theme.accent.primary, v.theme.surface.panel, 4.5, theme: v.name)
            assertFloor("accent on terminal", v.theme.accent.primary, v.theme.terminal.bg, 4.5, theme: v.name)
        }
    }

    func testTerminalForegroundFloor() {
        for v in variants {
            assertFloor("terminal fg", v.theme.terminal.fg, v.theme.terminal.bg, 7, theme: v.name)
        }
    }

    func testANSITextFloor() {
        let slots = Array(1...7) + Array(9...15)
        for v in variants {
            for i in slots {
                let slot = ANSISlot(rawValue: i)!
                assertFloor("ANSI \(i)", v.theme.ansi[slot], v.theme.terminal.bg, 4.5, theme: v.name)
            }
        }
    }

    func testLightBrightBlackFloor() {
        for v in variants where v.isLight {
            assertFloor("ANSI 8", v.theme.ansi[.brightBlack], v.theme.terminal.bg, 3, theme: v.name)
        }
    }

    func testCursorTextFloor() {
        for v in variants {
            assertFloor("cursor text", v.theme.terminal.cursorText, v.theme.terminal.cursor, 4.5, theme: v.name)
        }
    }

    func testSuggestionFloor() {
        for v in variants {
            assertFloor("suggestion", v.theme.predictor.suggestionText, v.theme.predictor.suggestionBg, 4.5,
                        theme: v.name)
        }
    }

    /// Red darker than green keeps a diff readable by lightness for red/green color blindness.
    func testLightRedDarkerThanGreen() {
        for v in variants where v.isLight {
            XCTAssertLessThan(v.theme.ansi[.red].relativeLuminance, v.theme.ansi[.green].relativeLuminance, v.name)
            XCTAssertLessThan(v.theme.ansi[.brightRed].relativeLuminance,
                              v.theme.ansi[.brightGreen].relativeLuminance, v.name)
        }
    }

    func testKnownExceptionIsStillReal() {
        // If Glacier dark is ever fixed, drop the exception instead of carrying a stale one.
        XCTAssertLessThan(contrastRatio(Theme.glacier.text.secondary, Theme.glacier.surface.panel), 4.5)
    }
}
