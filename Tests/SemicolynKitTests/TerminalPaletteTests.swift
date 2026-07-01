// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class TerminalPaletteTests: XCTestCase {
    func testBundlesTerminalTokensAndSixteenAnsi() {
        let p = Theme.neonMidnight.terminalPalette()
        XCTAssertEqual(p.bg, Theme.neonMidnight.terminal.bg)
        XCTAssertEqual(p.fg, Theme.neonMidnight.terminal.fg)
        XCTAssertEqual(p.cursor, Theme.neonMidnight.terminal.cursor)
        XCTAssertEqual(p.cursorText, Theme.neonMidnight.terminal.cursorText)
        XCTAssertEqual(p.selection, Theme.neonMidnight.terminal.selection)
        XCTAssertEqual(p.ansi16.count, 16)
        XCTAssertEqual(p.ansi16, Theme.neonMidnight.ansi.ordered())
    }
}
