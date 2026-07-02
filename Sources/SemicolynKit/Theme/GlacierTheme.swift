// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

// Glacier — the "soft" blue theme (Piece 2 of the themed-ANSI roadmap): desaturated
// pastel (Nord/Catppuccin family) on a lighter slate base, low contrast. Palette source:
// mockups/drafts/themes/glacier.itermcolors. Chrome (surfaces / text / highlight) is
// DERIVED from the palette by themes/build.py and baked in here; status + accent are
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
