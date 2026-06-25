// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

// Palette constants are file-private: only the semantic `Theme` is exported.
// Values verbatim from docs/superpowers/specs/2026-06-25-neon-midnight-theme-design.md.
// Story: neo → neon (neon gas glows orange-red) on a midnight blue-near-black
// night; the prompt `~` is the lit sign. Glow is bell-only (see BellHaloView) —
// no persistent bloom lives in these tokens.
private let coral500      = ThemeColor("#FF6F5E")   // neon accent (the glow's color)
private let coral300      = ThemeColor("#FFB7A6")   // highlight / hot core
private let night0        = ThemeColor("#07090E")   // ground — darker blue-night
private let nightPanel    = ThemeColor("#0E1118")
private let nightPanelHi  = ThemeColor("#161A24")
private let nightLine     = ThemeColor("#232A3A")
private let nightTerm     = ThemeColor("#05070B")   // terminal bg (deepest night)
private let patina500     = ThemeColor("#5FB0A2")   // verdigris success (cool complement)
private let amber500      = ThemeColor("#F5A524")
private let crimson500    = ThemeColor("#E5455E")   // unlit, cooler error red
private let textPrimary   = ThemeColor("#E8EBF0")
private let textMuted     = ThemeColor("#8A93A3")
private let termFg        = ThemeColor("#CFD6E4")

extension Theme {
    public static let neonMidnight = Theme(
        surface: .init(bg: night0, panel: nightPanel,
                       panelHigh: nightPanelHi, line: nightLine),
        text: .init(primary: textPrimary, secondary: textMuted,
                    muted: textMuted, inverse: nightTerm),
        accent: .init(primary: coral500, highlight: coral300),
        state: .init(success: patina500, degraded: amber500,
                     broken: crimson500, warning: amber500),
        bell: .init(edge: coral500),
        focus: .init(paneBorder: coral500, paneBorderInactive: nightLine),
        keybar: .init(slotBg: nightPanel,
                      slotBgPromoted: coral500.alpha(0.12),
                      slotBgArmed: coral500.alpha(0.20),
                      slotBgLocked: coral500.alpha(0.30)),
        predictor: .init(stripBg: nightPanel, suggestionBg: nightPanelHi,
                         suggestionText: textPrimary),
        banner: .init(amberBg: amber500.alpha(0.15), redBg: crimson500.alpha(0.15),
                      neutralBg: nightPanel),
        terminal: .init(bg: nightTerm, fg: termFg)
    )
}
