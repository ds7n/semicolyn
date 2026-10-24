// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// The plain-tmux action a hardware-keyboard window/pane shortcut drives, or nil when
/// it drives none. The App sends the action's private bound sequence through the same
/// path the gestures use (`PlainTmuxController`).
///
/// Only active while plain tmux is attached: with no tmux (raw shell, tmux opted out or
/// missing) every shortcut maps to nil, so it does nothing, as before.
///
/// The split names follow the catalog's iTerm2-style titles, which are the opposite of
/// tmux's flags: "Split Vertically" (`⌘D`, `⌘|`) draws a vertical divider, so the new
/// pane sits to the right (`split-window -h`, `TmuxAction.splitHorizontal`); "Split
/// Horizontally" (`⇧⌘D`, `⌘-`) puts it below (`split-window -v`).
///
/// `closeWindow`, `switchWindow(n)` and `prevPane` have no bound tmux action yet, so they
/// map to nil even with tmux attached. Non-tmux commands (paste, settings, ...) are
/// always nil here; the App handles them itself.
public func keyboardTmuxAction(for command: KeyboardCommand,
                               plainTmuxAttached: Bool) -> TmuxAction? {
    guard plainTmuxAttached else { return nil }
    switch command {
    case .newWindow:       return .newWindow
    case .nextWindow:      return .nextWindow
    case .prevWindow:      return .previousWindow
    case .nextPane:        return .cyclePane
    case .splitVertical:   return .splitHorizontal
    case .splitHorizontal: return .splitVertical
    case .closeWindow, .switchWindow, .prevPane,
         .clearScreen, .copy, .paste, .newConnection, .reconnect,
         .openLauncher, .settings, .tips:
        return nil
    }
}
