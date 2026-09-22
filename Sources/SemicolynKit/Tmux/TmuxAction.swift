// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// A plain-tmux gesture action. Its raw value is the stable key used in the
/// per-host persisted action->key map; `command` is the command-mode FALLBACK
/// (no `-t` = active pane) used only when no key binding is discovered.
public enum TmuxAction: String, CaseIterable, Sendable {
    case splitHorizontal
    case splitVertical
    case closePane
    case newWindow
    case zoom
    case nextWindow
    case previousWindow
    case cyclePane

    /// The tmux command this action performs (command-mode fallback string).
    public var command: String {
        switch self {
        case .splitHorizontal: return "split-window -h"
        case .splitVertical:   return "split-window -v"
        case .closePane:       return "kill-pane"
        case .newWindow:       return "new-window"
        case .zoom:            return "resize-pane -Z"
        case .nextWindow:      return "next-window"
        case .previousWindow:  return "previous-window"
        case .cyclePane:       return "select-pane -t +"
        }
    }
}
