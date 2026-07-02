// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

// GENERATED from themes/neon-midnight.itermcolors by themes/build.py — chrome derived from the
// palette (surfaces/text/highlight), status + accent pinned to ANSI slots. Regenerate
// with `uv run python build.py --swift`; safe to keep in the tree once reviewed.

private let neonMidnightANSI = ANSIPalette([
        ThemeColor("#0B0E14"), ThemeColor("#E5455E"), ThemeColor("#5FB0A2"), ThemeColor("#F5A524"),
        ThemeColor("#5B8CFF"), ThemeColor("#B98CFF"), ThemeColor("#4FC7D6"), ThemeColor("#C9D1E0"),
        ThemeColor("#2A3346"), ThemeColor("#FF6F5E"), ThemeColor("#7CE0C4"), ThemeColor("#FFC860"),
        ThemeColor("#8AA6FF"), ThemeColor("#D0B0FF"), ThemeColor("#86ECF7"), ThemeColor("#F2F5FA"),
])

extension Theme {
    public static let neonMidnight = Theme.fromANSI(
        ansi: neonMidnightANSI,
        roles: ANSIRoleMap(accentPrimary: .brightRed, success: .green,
                           degraded: .yellow, broken: .red, warning: .yellow),
        highlight: ThemeColor("#F7B5AD"),
        surface: .init(bg: ThemeColor("#080B12"), panel: ThemeColor("#0D121D"),
                       panelHigh: ThemeColor("#161F32"), line: ThemeColor("#212F4B")),
        text: .init(primary: ThemeColor("#E9ECF3"), secondary: ThemeColor("#898C92"),
                    muted: ThemeColor("#898C92"), inverse: ThemeColor("#05070B")),
        terminal: .init(bg: ThemeColor("#05070B"), fg: ThemeColor("#CFD6E4"),
                        cursor: ThemeColor("#FF6F5E"), cursorText: ThemeColor("#05070B"),
                        selection: ThemeColor("#FF6F5E").alpha(0.30))
    )
}
