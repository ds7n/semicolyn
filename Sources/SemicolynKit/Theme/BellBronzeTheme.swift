// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

// Palette constants are file-private: only the semantic `Theme` is exported.
// Values verbatim from docs/superpowers/specs/2026-06-17-design-tokens-design.md.
private let bronze500       = ThemeColor("#D49A5C")
private let bronze300       = ThemeColor("#F2C58A")
private let coolDarkAnchor  = ThemeColor("#0E1116")
private let coolDarkPanel   = ThemeColor("#161A22")
private let coolDarkPanelHi = ThemeColor("#1F2530")
private let coolDarkLine    = ThemeColor("#2A323F")
private let patina500       = ThemeColor("#5FA89C")
private let amber500        = ThemeColor("#F5A524")
private let red500          = ThemeColor("#E06B6B")
private let textPrimary     = ThemeColor("#E8EBF0")
private let textMuted       = ThemeColor("#8A93A3")

// Bronze is the warm accent → yellow slot = bronze. degraded/warning use a
// separate amber slot (brightYellow) so bronze-accent and amber-warning stay
// visibly distinct, matching the shipped theme.
private let bellBronzeANSI = ANSIPalette([
    ThemeColor("#0A0C10"), // black
    red500,                // red    (error)
    patina500,             // green
    bronze500,             // yellow (bronze / accent)
    ThemeColor("#5E86C7"), // blue
    ThemeColor("#A98BC7"), // magenta
    ThemeColor("#5FA8B5"), // cyan
    ThemeColor("#C9D1DE"), // white
    ThemeColor("#2A323F"), // brightBlack
    ThemeColor("#F08A8A"), // brightRed
    ThemeColor("#7FC4B7"), // brightGreen
    amber500,              // brightYellow (amber / warning)
    ThemeColor("#8AAAE0"), // brightBlue
    ThemeColor("#C8ADE0"), // brightMagenta
    ThemeColor("#8FCDD9"), // brightCyan
    ThemeColor("#F2F5FA"), // brightWhite
])

extension Theme {
    public static let bellBronze = Theme.fromANSI(
        ansi: bellBronzeANSI,
        roles: ANSIRoleMap(accentPrimary: .yellow, success: .green,
                           degraded: .brightYellow, broken: .red, warning: .brightYellow),
        highlight: bronze300,
        surface: .init(bg: coolDarkAnchor, panel: coolDarkPanel,
                       panelHigh: coolDarkPanelHi, line: coolDarkLine),
        text: .init(primary: textPrimary, secondary: textMuted, muted: textMuted, inverse: coolDarkAnchor),
        terminal: .init(bg: ThemeColor("#0A0C10"), fg: ThemeColor("#CFD6E4"),
                        cursor: bronze500, cursorText: ThemeColor("#0A0C10"),
                        selection: bronze500.alpha(0.30))
    )

    // Neon Midnight is the default (first); Bell-bronze retained as a switchable
    // alternate (candidate Pro cosmetic).
    public static let all: [Theme] = catalog.map(\.theme)
}
