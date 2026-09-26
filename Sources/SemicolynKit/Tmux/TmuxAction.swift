// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// A plain-tmux gesture action. Each is bound at launch to a private escape sequence
/// (see `TmuxGestureBindings.swift`); `command` is what that binding runs (no `-t` =
/// the active pane).
public enum TmuxAction: String, CaseIterable, Sendable {
    case splitHorizontal
    case splitVertical
    case closePane
    case newWindow
    case zoom
    case nextWindow
    case previousWindow
    case cyclePane

    /// The tmux command this action's private binding runs.
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
