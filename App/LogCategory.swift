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

    /// UserDefaults key backing the per-category toggle.
    var storageKey: String { "diagnostics.logcat.\(rawValue)" }

    /// Human label for the settings row.
    var label: String { rawValue.capitalized }

    /// Categories ON by default: low-volume, high-diagnostic-value. The high-volume /
    /// niche ones (render/input/predictor/keybar) default OFF (opt-in when needed).
    static let defaultEnabled: Set<LogCategory> = [.lifecycle, .connect, .tmux, .gesture, .seed]

    var defaultOn: Bool { Self.defaultEnabled.contains(self) }
}
