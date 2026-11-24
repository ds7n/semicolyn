// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Whether a scroll gesture drives tmux copy mode through the private scroll bindings
/// (`TmuxAction.scrollUp` / `.scrollDown`) instead of sending wheel or arrow bytes.
///
/// Only with tmux on screen, the terminal NOT reporting the mouse (tmux's `mouse` option
/// is off, so tmux ignores wheel bytes) and the wheel scroll setting. tmux `mouse on`
/// keeps the wheel bytes it already handles, and the arrow-key fallback setting keeps
/// arrows. The user's tmux options are never changed.
public func usesTmuxScrollBinding(tmuxOnScreen: Bool, mouseReporting: Bool, keys: AltScrollKeys) -> Bool {
    tmuxOnScreen && !mouseReporting && keys == .wheel
}

/// The bytes for one scroll-gesture step through the tmux scroll bindings, sent in ONE
/// write. Positive `lines` (finger down) = older history = `scrollUp`; negative =
/// `scrollDown`; zero = nothing. Each sequence scrolls 5 lines (tmux's own wheel step).
///
/// At most TWO sequences: tmux treats keys that arrive within `assume-paste-time` (1ms)
/// of each other as a paste and skips their bindings from the third on, so extra copies
/// in one write would be lost (wheel events are exempt from that, keys are not).
public func plainTmuxScrollBytes(lines: Int) -> [UInt8] {
    guard lines != 0 else { return [] }
    let action: TmuxAction = lines > 0 ? .scrollUp : .scrollDown
    let count = Int(min(lines.magnitude, 2))
    return Array(repeating: action.gestureSequence, count: count).flatMap { $0 }
}
