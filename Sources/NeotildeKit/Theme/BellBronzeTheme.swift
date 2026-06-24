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

extension Theme {
    public static let bellBronze = Theme(
        surface: .init(bg: coolDarkAnchor, panel: coolDarkPanel,
                       panelHigh: coolDarkPanelHi, line: coolDarkLine),
        text: .init(primary: textPrimary, secondary: textMuted,
                    muted: textMuted, inverse: coolDarkAnchor),
        accent: .init(primary: bronze500, highlight: bronze300),
        state: .init(success: patina500, degraded: amber500,
                     broken: red500, warning: amber500),
        bell: .init(edge: bronze500),
        focus: .init(paneBorder: bronze500, paneBorderInactive: coolDarkLine),
        keybar: .init(slotBg: coolDarkPanel,
                      slotBgPromoted: bronze500.alpha(0.12),
                      slotBgArmed: bronze500.alpha(0.20),
                      slotBgLocked: bronze500.alpha(0.30)),
        predictor: .init(stripBg: coolDarkPanel, suggestionBg: coolDarkPanelHi,
                         suggestionText: textPrimary),
        banner: .init(amberBg: amber500.alpha(0.15), redBg: red500.alpha(0.15),
                      neutralBg: coolDarkPanel),
        terminal: .init(bg: ThemeColor("#0A0C10"), fg: ThemeColor("#CFD6E4"))
    )

    /// The v1 theme registry. Picker UI stays hidden while this has one entry.
    public static let all: [Theme] = [.bellBronze]
}
