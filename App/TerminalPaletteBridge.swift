// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SwiftTerm
import SemicolynKit

extension SwiftTerm.Color {
    /// Bridges a `ThemeColor` to a SwiftTerm 16-bit-channel `Color`.
    /// Reuses the unit-tested `rgba()` parser; opacity is dropped (opaque terminal).
    convenience init(themeColor: ThemeColor) {
        let c = themeColor.rgba()
        self.init(red: UInt16(c.red * 65535),
                  green: UInt16(c.green * 65535),
                  blue: UInt16(c.blue * 65535))
    }
}

/// Applies a theme's terminal palette to a live SwiftTerm view: installs the 16
/// ANSI colors and sets fg/bg/cursor/cursor-text/selection. Selection is TRUE
/// REVERSE-VIDEO (a straight fg<->bg swap), not the theme's translucent
/// `selection` color: selected-text background is the terminal foreground color
/// and selected-text foreground is the terminal background color, so the
/// selection is opaque and always contrasts, matching classic terminal
/// reverse-video rather than a muddy alpha overlay. Called at view creation and
/// whenever the observed theme changes.
func applyPalette(_ palette: TerminalPalette, to view: TerminalView) {
    view.installColors(palette.ansi16.map { SwiftTerm.Color(themeColor: $0) })
    view.nativeForegroundColor = UIColor(Color(palette.fg))
    view.nativeBackgroundColor = UIColor(Color(palette.bg))
    view.caretColor = UIColor(Color(palette.cursor))
    view.caretTextColor = UIColor(Color(palette.cursorText))
    view.selectedTextBackgroundColor = UIColor(Color(palette.fg))
    view.selectedTextForegroundColor = UIColor(Color(palette.bg))
}
