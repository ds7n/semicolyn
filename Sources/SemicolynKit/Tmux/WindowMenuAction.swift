// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// A pane/window action from the keybar dpad long-press menu. Each maps to a tmux
/// COMMAND run via command mode (`<prefix> : <command> Enter`), NOT a default key
/// binding: command mode is keybinding-independent, so an action works even when the
/// user's tmux config rebinds or unbinds the default key (device 2026-09-20: a config
/// binding split to |/- left the default %/" keys inert). No `-t` target means the
/// command acts on the currently-active pane, which is the intended target.
public enum WindowMenuAction: CaseIterable, Sendable {
    case splitHorizontal   // pane to the right
    case splitVertical     // pane below
    case closePane
    case newWindow
    case zoom

    /// The tmux command for this action (no `-t`: active pane).
    public var command: String {
        switch self {
        case .splitHorizontal: return "split-window -h"
        case .splitVertical:   return "split-window -v"
        case .closePane:       return "kill-pane"
        case .newWindow:       return "new-window"
        case .zoom:            return "resize-pane -Z"
        }
    }
}
