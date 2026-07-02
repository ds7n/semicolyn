// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

// GENERATED from themes/neon-cobalt.itermcolors by themes/build.py — chrome derived from the
// palette (surfaces/text/highlight), status + accent pinned to ANSI slots. Regenerate
// with `uv run python build.py --swift`; safe to keep in the tree once reviewed.

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
