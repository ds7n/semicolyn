// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Diagnostic log categories. Each is independently enable/disable-able in
/// Settings → Diagnostics and persisted via `@AppStorage`. Gating happens BEFORE the
/// log message autoclosure is evaluated, so a disabled category costs nothing.
enum LogCategory: String, CaseIterable, Sendable {
    case lifecycle   // connect/attach/disconnect, app fg/bg, transport switch
    case connect     // auth, hostkey, mosh fallback, reconnect
    case tmux        // control-mode send / %reply / state-apply / pane register
    case render      // pane/window render — log-on-change only
    case gesture     // tap/pan/long-press/pinch handlers + classify decisions
    case input       // keystroke structural events (length/backspace/modifier), NOT content
    case predictor   // suggestion lifecycle + secret-exclusion gates
    case keybar      // accessory sizing, macro resolution, live-edit apply
    case seed        // tmux history seeding
    case sizing      // cell/grid metrics, tmux client-size, raw %output width probe (staircase bug)

    /// UserDefaults key backing the per-category toggle.
    var storageKey: String { "diagnostics.logcat.\(rawValue)" }

    /// Human label for the settings row.
    var label: String { rawValue.capitalized }

    /// One-line description shown under the toggle in Settings → Diagnostics, so a
    /// tester knows what each category records before enabling it.
    var summary: String {
        switch self {
        case .lifecycle: return "Connect, attach, disconnect, app foreground/background, transport switch."
        case .connect:   return "Auth, host-key trust, Mosh fallback, reconnect."
        case .tmux:      return "tmux control-mode sends, %replies, state-apply, pane registration."
        case .render:    return "Pane/window render events (logged only on change). Verbose."
        case .gesture:   return "Tap, pan, long-press, pinch handlers and swipe-vs-scroll classification."
        case .input:     return "Keystroke structure (length, backspace, modifiers) — never key content. Verbose."
        case .predictor: return "Suggestion lifecycle and secret-exclusion gates. Verbose."
        case .keybar:    return "Accessory sizing, macro resolution, live-edit apply. Verbose."
        case .seed:      return "tmux scrollback history seeding."
        case .sizing:    return "Cell/grid metrics, tmux client size, and raw %output line widths (staircase/wrap bug). Verbose; shows terminal text structure but not typed input."
        }
    }

    /// Categories ON by default: low-volume, high-diagnostic-value. The high-volume /
    /// niche ones (gesture/render/input/predictor/keybar) default OFF (opt-in when needed).
    static let defaultEnabled: Set<LogCategory> = [.lifecycle, .connect, .tmux, .seed]

    var defaultOn: Bool { Self.defaultEnabled.contains(self) }
}
