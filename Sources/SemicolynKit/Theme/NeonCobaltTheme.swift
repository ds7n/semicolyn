// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

// Neon Cobalt, the "electric" blue theme (Piece 2 of the themed-ANSI roadmap).
// Palette source: neon-cobalt.itermcolors. Chrome (surfaces /
// text / highlight) is DERIVED from the palette by the local theme build script and baked in here;
// status + accent are pinned to ANSI slots via the role map. Regenerate the literals
// with `uv run python build.py --swift`.

private let neonCobaltANSI = ANSIPalette([
        ThemeColor("#0A0C1A"), ThemeColor("#FD4E66"), ThemeColor("#4EFDAC"), ThemeColor("#FDCF4E"),
        ThemeColor("#5A6EFF"), ThemeColor("#E64EFD"), ThemeColor("#4EECFD"), ThemeColor("#C6CEF0"),
        ThemeColor("#29305A"), ThemeColor("#F7929F"), ThemeColor("#92F7C8"), ThemeColor("#F7DC92"),
        ThemeColor("#A3B0FF"), ThemeColor("#E992F7"), ThemeColor("#92EDF7"), ThemeColor("#F0F3FF"),
])

extension Theme {
    public static let neonCobalt = Theme.fromANSI(
        ansi: neonCobaltANSI,
        roles: ANSIRoleMap(accentPrimary: .blue, success: .green,
                           degraded: .yellow, broken: .red, warning: .yellow),
        highlight: ThemeColor("#AAB3F7"),
        surface: .init(bg: ThemeColor("#050713"), panel: ThemeColor("#080B1F"),
                       panelHigh: ThemeColor("#0E1438"), line: ThemeColor("#161D54")),
        text: .init(primary: ThemeColor("#E6EAF9"), secondary: ThemeColor("#878995"),
                    muted: ThemeColor("#878995"), inverse: ThemeColor("#03040B")),
        terminal: .init(bg: ThemeColor("#03040B"), fg: ThemeColor("#C6CEF0"),
                        cursor: ThemeColor("#5A6EFF"), cursorText: ThemeColor("#03040B"),
                        selection: ThemeColor("#5A6EFF").alpha(0.30))
    )
}

// Light variant (light-theme-variants spec): anchored to the light app icon's bg and
// text, every ANSI color darkened to >= 4.5:1 on the light terminal bg (red darker than
// green for red/green color blindness). Values from the approved light palette mockup.
private let neonCobaltLightANSI = ANSIPalette([
    ThemeColor("#0E1438"), ThemeColor("#A00D21"), ThemeColor("#0A7D48"), ThemeColor("#76590A"),
    ThemeColor("#394BE6"), ThemeColor("#A00FB6"), ThemeColor("#096771"), ThemeColor("#585D78"),
    ThemeColor("#82859C"), ThemeColor("#B80F25"), ThemeColor("#0A7F49"), ThemeColor("#8E6B0B"),
    ThemeColor("#4961F0"), ThemeColor("#BD12D9"), ThemeColor("#0B7C89"), ThemeColor("#6B6F88"),
])

extension Theme {
    public static let neonCobaltLight = Theme.fromANSI(
        ansi: neonCobaltLightANSI,
        roles: ANSIRoleMap(accentPrimary: .blue, success: .green,
                           degraded: .yellow, broken: .red, warning: .yellow),
        highlight: ThemeColor("#A6AEF5"),
        surface: .init(bg: ThemeColor("#EEF0FF"), panel: ThemeColor("#D7DCFF"),
                       panelHigh: ThemeColor("#FBFBFF"), line: ThemeColor("#ACB5FF")),
        text: .init(primary: ThemeColor("#0E1438"), secondary: ThemeColor("#565C80"),
                    muted: ThemeColor("#565C80"), inverse: ThemeColor("#F6F7FF")),
        terminal: .init(bg: ThemeColor("#F6F7FF"), fg: ThemeColor("#353B5A"),
                        cursor: ThemeColor("#394BE6"), cursorText: ThemeColor("#F6F7FF"),
                        selection: ThemeColor("#394BE6").alpha(0.30))
    )
}
