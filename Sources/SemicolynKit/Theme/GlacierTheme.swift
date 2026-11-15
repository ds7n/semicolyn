// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

// Glacier, the "soft" blue theme (Piece 2 of the themed-ANSI roadmap): desaturated
// pastel (Nord/Catppuccin family) on a lighter slate base, low contrast. Palette source:
// glacier.itermcolors. Chrome (surfaces / text / highlight) is
// DERIVED from the palette by the local theme build script and baked in here; status + accent are
// pinned to ANSI slots. Regenerate the literals with `uv run python build.py --swift`.

private let glacierANSI = ANSIPalette([
        ThemeColor("#202636"), ThemeColor("#DD9DA1"), ThemeColor("#9DDDB8"), ThemeColor("#DDCC9D"),
        ThemeColor("#8AA6E8"), ThemeColor("#CC9DDD"), ThemeColor("#9DD4DD"), ThemeColor("#B8BFCE"),
        ThemeColor("#414B68"), ThemeColor("#E7C5C7"), ThemeColor("#C5E7D4"), ThemeColor("#E7DEC5"),
        ThemeColor("#C0CDEC"), ThemeColor("#DEC5E7"), ThemeColor("#C5E3E7"), ThemeColor("#E4E9F2"),
])

extension Theme {
    public static let glacier = Theme.fromANSI(
        ansi: glacierANSI,
        roles: ANSIRoleMap(accentPrimary: .blue, success: .green,
                           degraded: .yellow, broken: .red, warning: .yellow),
        highlight: ThemeColor("#CAD5F0"),
        surface: .init(bg: ThemeColor("#181F30"), panel: ThemeColor("#1D263B"),
                       panelHigh: ThemeColor("#27334F"), line: ThemeColor("#334267")),
        text: .init(primary: ThemeColor("#D0D5DF"), secondary: ThemeColor("#818793"),
                    muted: ThemeColor("#818793"), inverse: ThemeColor("#151B29")),
        terminal: .init(bg: ThemeColor("#151B29"), fg: ThemeColor("#B8BFCE"),
                        cursor: ThemeColor("#8AA6E8"), cursorText: ThemeColor("#151B29"),
                        selection: ThemeColor("#8AA6E8").alpha(0.30))
    )
}

// Light variant (light-theme-variants spec): anchored to the light app icon's bg and
// text, every ANSI color darkened to >= 4.5:1 on the light terminal bg (red darker than
// green for red/green color blindness). Values from the approved light palette mockup.
private let glacierLightANSI = ANSIPalette([
    ThemeColor("#27334F"), ThemeColor("#882F35"), ThemeColor("#2A794B"), ThemeColor("#6C5925"),
    ThemeColor("#3B5CB4"), ThemeColor("#8738A3"), ThemeColor("#26646E"), ThemeColor("#515C73"),
    ThemeColor("#7C8496"), ThemeColor("#963E43"), ThemeColor("#337B52"), ThemeColor("#806C35"),
    ThemeColor("#436AC6"), ThemeColor("#9A4EB6"), ThemeColor("#357780"), ThemeColor("#646D82"),
])

extension Theme {
    public static let glacierLight = Theme.fromANSI(
        ansi: glacierLightANSI,
        roles: ANSIRoleMap(accentPrimary: .blue, success: .green,
                           degraded: .yellow, broken: .red, warning: .yellow),
        highlight: ThemeColor("#A2B2DA"),
        surface: .init(bg: ThemeColor("#E6EBF4"), panel: ThemeColor("#D6DEED"),
                       panelHigh: ThemeColor("#F9FAFC"), line: ThemeColor("#B8C6E0")),
        text: .init(primary: ThemeColor("#27334F"), secondary: ThemeColor("#555F78"),
                    muted: ThemeColor("#555F78"), inverse: ThemeColor("#F1F4F9")),
        terminal: .init(bg: ThemeColor("#F1F4F9"), fg: ThemeColor("#2F3B56"),
                        cursor: ThemeColor("#3B5CB4"), cursorText: ThemeColor("#F1F4F9"),
                        selection: ThemeColor("#3B5CB4").alpha(0.30))
    )
}
