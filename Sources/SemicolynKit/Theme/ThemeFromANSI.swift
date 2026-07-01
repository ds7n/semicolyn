// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Which ANSI slot feeds each strictly-derived UI semantic role. `accent.highlight`
/// is intentionally absent — it is an authored decorative tint, not a slot.
public struct ANSIRoleMap: Equatable, Sendable {
    public let accentPrimary: ANSISlot
    public let success, degraded, broken, warning: ANSISlot

    public init(accentPrimary: ANSISlot, success: ANSISlot,
                degraded: ANSISlot, broken: ANSISlot, warning: ANSISlot) {
        self.accentPrimary = accentPrimary
        self.success = success
        self.degraded = degraded
        self.broken = broken
        self.warning = warning
    }
}

extension Theme {
    /// Builds a Theme whose accent-primary + state colors are RESOLVED from `ansi`
    /// via `roles` (strict derivation), while `highlight`, surfaces, text, and the
    /// terminal tokens are authored directly. bell/focus/keybar/predictor/banner
    /// are derived here — the single place that logic lives.
    public static func fromANSI(
        ansi: ANSIPalette, roles: ANSIRoleMap, highlight: ThemeColor,
        surface: Surface, text: Text, terminal: Terminal
    ) -> Theme {
        let accent = ansi[roles.accentPrimary]
        let success = ansi[roles.success]
        let degraded = ansi[roles.degraded]
        let broken = ansi[roles.broken]
        let warning = ansi[roles.warning]
        return Theme(
            surface: surface,
            text: text,
            accent: .init(primary: accent, highlight: highlight),
            state: .init(success: success, degraded: degraded, broken: broken, warning: warning),
            bell: .init(edge: accent),
            focus: .init(paneBorder: accent, paneBorderInactive: surface.line),
            keybar: .init(slotBg: surface.panel,
                          slotBgPromoted: accent.alpha(0.12),
                          slotBgArmed: accent.alpha(0.20),
                          slotBgLocked: accent.alpha(0.30)),
            predictor: .init(stripBg: surface.panel, suggestionBg: surface.panelHigh,
                             suggestionText: text.primary),
            banner: .init(amberBg: warning.alpha(0.15), redBg: broken.alpha(0.15),
                          neutralBg: surface.panel),
            terminal: terminal,
            ansi: ansi
        )
    }
}
