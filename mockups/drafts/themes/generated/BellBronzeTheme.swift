// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

// GENERATED from themes/bell-bronze.itermcolors by themes/build.py — chrome derived from the
// palette (surfaces/text/highlight), status + accent pinned to ANSI slots. Regenerate
// with `uv run python build.py --swift`; safe to keep in the tree once reviewed.

private let bellBronzeANSI = ANSIPalette([
        ThemeColor("#1A150E"), ThemeColor("#E06B6B"), ThemeColor("#5FA89C"), ThemeColor("#D49A5C"),
        ThemeColor("#5E86C7"), ThemeColor("#A98BC7"), ThemeColor("#5FA8B5"), ThemeColor("#D8CFBE"),
        ThemeColor("#3A3324"), ThemeColor("#F08A8A"), ThemeColor("#7FC4B7"), ThemeColor("#F5A524"),
        ThemeColor("#8AAAE0"), ThemeColor("#C8ADE0"), ThemeColor("#8FCDD9"), ThemeColor("#F2ECDE"),
])

extension Theme {
    public static let bellBronze = Theme.fromANSI(
        ansi: bellBronzeANSI,
        roles: ANSIRoleMap(accentPrimary: .yellow, success: .green,
                           degraded: .brightYellow, broken: .red, warning: .brightYellow),
        highlight: ThemeColor("#F2C58A"),
        surface: .init(bg: ThemeColor("#17130D"), panel: ThemeColor("#1F1A12"),
                       panelHigh: ThemeColor("#29231A"), line: ThemeColor("#3A3225")),
        text: .init(primary: ThemeColor("#ECE4D5"), secondary: ThemeColor("#9E9382"),
                    muted: ThemeColor("#9E9382"), inverse: ThemeColor("#120F09")),
        terminal: .init(bg: ThemeColor("#120F09"), fg: ThemeColor("#D8CFBE"),
                        cursor: ThemeColor("#D49A5C"), cursorText: ThemeColor("#120F09"),
                        selection: ThemeColor("#D49A5C").alpha(0.30))
    )
}
