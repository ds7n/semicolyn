// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Flat, platform-agnostic bundle of everything the terminal view is colored by.
/// The App bridge consumes this without touching `Theme` internals.
public struct TerminalPalette: Equatable, Sendable {
    public let fg, bg, cursor, cursorText, selection: ThemeColor
    public let ansi16: [ThemeColor]

    public init(fg: ThemeColor, bg: ThemeColor, cursor: ThemeColor,
                cursorText: ThemeColor, selection: ThemeColor, ansi16: [ThemeColor]) {
        self.fg = fg; self.bg = bg; self.cursor = cursor
        self.cursorText = cursorText; self.selection = selection; self.ansi16 = ansi16
    }
}

extension Theme {
    /// The terminal-facing view of this theme: fg/bg/cursor/cursorText/selection
    /// plus the ordered 16 ANSI colors.
    public func terminalPalette() -> TerminalPalette {
        TerminalPalette(fg: terminal.fg, bg: terminal.bg, cursor: terminal.cursor,
                        cursorText: terminal.cursorText, selection: terminal.selection,
                        ansi16: ansi.ordered())
    }
}
