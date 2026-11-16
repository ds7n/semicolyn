// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

// Palette constants are file-private: only the semantic `Theme` is exported.
// Values verbatim from the design-tokens spec.
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
    public static let all: [Theme] = catalog.map(\.dark)
}

// Light variant (light-theme-variants spec): anchored to the light app icon's bg and
// text, every ANSI color darkened to >= 4.5:1 on the light terminal bg (red darker than
// green for red/green color blindness). Values from the approved light palette mockup.
private let bellBronzeLightANSI = ANSIPalette([
    ThemeColor("#1F2530"), ThemeColor("#982020"), ThemeColor("#40766D"), ThemeColor("#8A5B2D"),
    ThemeColor("#375E9D"), ThemeColor("#734B9B"), ThemeColor("#33656E"), ThemeColor("#5A5D64"),
    ThemeColor("#848588"), ThemeColor("#B51717"), ThemeColor("#387A6E"), ThemeColor("#9A640C"),
    ThemeColor("#356DCA"), ThemeColor("#8D55BF"), ThemeColor("#2E7987"), ThemeColor("#6E7075"),
])

extension Theme {
    public static let bellBronzeLight = Theme.fromANSI(
        ansi: bellBronzeLightANSI,
        roles: ANSIRoleMap(accentPrimary: .yellow, success: .green,
                           degraded: .brightYellow, broken: .red, warning: .brightYellow),
        highlight: ThemeColor("#CBB49B"),
        surface: .init(bg: ThemeColor("#F6EFE4"), panel: ThemeColor("#F0E5D3"),
                       panelHigh: ThemeColor("#FDFBF8"), line: ThemeColor("#E5D2B2")),
        text: .init(primary: ThemeColor("#1F2530"), secondary: ThemeColor("#646466"),
                    muted: ThemeColor("#646466"), inverse: ThemeColor("#FAF6F0")),
        terminal: .init(bg: ThemeColor("#FAF6F0"), fg: ThemeColor("#373C45"),
                        cursor: ThemeColor("#8A5B2D"), cursorText: ThemeColor("#FAF6F0"),
                        selection: ThemeColor("#8A5B2D").alpha(0.30))
    )
}
