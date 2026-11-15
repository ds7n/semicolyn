// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

// Palette constants are file-private: only the semantic `Theme` is exported.
// Values verbatim from the neon-midnight theme spec.
// Story: neo → neon (neon gas glows orange-red) on a midnight blue-near-black
// night; the prompt `~` is the lit sign. Glow is bell-only (see BellHaloView),
// no persistent bloom lives in these tokens.

// Palette constants unchanged; the 16 ANSI colors are designed to sit on the
// midnight night. accent=coral lives in brightRed, error=crimson in red.
private let coral500      = ThemeColor("#FF6F5E")
private let coral300      = ThemeColor("#FFB7A6")
private let crimson500    = ThemeColor("#E5455E")
private let patina500     = ThemeColor("#5FB0A2")
private let amber500      = ThemeColor("#F5A524")
private let night0        = ThemeColor("#07090E")
private let nightPanel    = ThemeColor("#0E1118")
private let nightPanelHi  = ThemeColor("#161A24")
private let nightLine     = ThemeColor("#232A3A")
private let nightTerm     = ThemeColor("#05070B")
private let textPrimary   = ThemeColor("#E8EBF0")
private let textMuted     = ThemeColor("#8A93A3")
private let termFg        = ThemeColor("#CFD6E4")

// 16 ANSI colors for the night. Semantic slots carry the existing hues so
// derivation reproduces the shipped accent/state exactly; blue/magenta/cyan
// are cool neons tuned for the dark base; brights are lifted variants.
private let neonMidnightANSI = ANSIPalette([
    ThemeColor("#0B0E14"), // black
    crimson500,            // red    (error / crimson)
    patina500,             // green  (verdigris)
    amber500,              // yellow (amber)
    ThemeColor("#5B8CFF"), // blue
    ThemeColor("#B98CFF"), // magenta
    ThemeColor("#4FC7D6"), // cyan
    ThemeColor("#C9D1E0"), // white
    ThemeColor("#2A3346"), // brightBlack
    coral500,              // brightRed  (accent / coral)
    ThemeColor("#7CE0C4"), // brightGreen
    ThemeColor("#FFC860"), // brightYellow
    ThemeColor("#8AA6FF"), // brightBlue
    ThemeColor("#D0B0FF"), // brightMagenta
    ThemeColor("#86ECF7"), // brightCyan
    ThemeColor("#F2F5FA"), // brightWhite
])

extension Theme {
    public static let neonMidnight = Theme.fromANSI(
        ansi: neonMidnightANSI,
        roles: ANSIRoleMap(accentPrimary: .brightRed, success: .green,
                           degraded: .yellow, broken: .red, warning: .yellow),
        highlight: coral300,
        surface: .init(bg: night0, panel: nightPanel, panelHigh: nightPanelHi, line: nightLine),
        text: .init(primary: textPrimary, secondary: textMuted, muted: textMuted, inverse: nightTerm),
        terminal: .init(bg: nightTerm, fg: termFg,
                        cursor: coral500, cursorText: nightTerm, selection: coral500.alpha(0.30))
    )
}

// Light variant (light-theme-variants spec): anchored to the light app icon's bg and
// text, every ANSI color darkened to >= 4.5:1 on the light terminal bg (red darker than
// green for red/green color blindness). Values from the approved light palette mockup.
private let neonMidnightLightANSI = ANSIPalette([
    ThemeColor("#1C2230"), ThemeColor("#9F162B"), ThemeColor("#3B786D"), ThemeColor("#82540B"),
    ThemeColor("#1251E2"), ThemeColor("#7628EE"), ThemeColor("#1A6872"), ThemeColor("#5A5E67"),
    ThemeColor("#83848B"), ThemeColor("#C52A18"), ThemeColor("#1E7E63"), ThemeColor("#97670C"),
    ThemeColor("#3964EF"), ThemeColor("#8B47F0"), ThemeColor("#0B7D89"), ThemeColor("#6F7179"),
])

extension Theme {
    public static let neonMidnightLight = Theme.fromANSI(
        ansi: neonMidnightLightANSI,
        roles: ANSIRoleMap(accentPrimary: .brightRed, success: .green,
                           degraded: .yellow, broken: .red, warning: .yellow),
        highlight: ThemeColor("#E3A399"),
        surface: .init(bg: ThemeColor("#F7F3EF"), panel: ThemeColor("#EFE8E0"),
                       panelHigh: ThemeColor("#FDFCFB"), line: ThemeColor("#E1D2C3")),
        text: .init(primary: ThemeColor("#1C2230"), secondary: ThemeColor("#64656C"),
                    muted: ThemeColor("#64656C"), inverse: ThemeColor("#FBF8F6")),
        terminal: .init(bg: ThemeColor("#FBF8F6"), fg: ThemeColor("#393E4A"),
                        cursor: ThemeColor("#C52A18"), cursorText: ThemeColor("#FBF8F6"),
                        selection: ThemeColor("#C52A18").alpha(0.30))
    )
}
