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
    /// Five lines (tmux's own wheel step) toward older history in tmux copy mode, for the
    /// scroll gesture when tmux's `mouse` option is off (tmux ignores wheel bytes then).
    /// Enters copy mode (`-e`: it exits again at the bottom) only off the alternate
    /// screen, so a full-screen program keeps the swipe; copy mode that is already open
    /// always scrolls.
    case scrollUp
    /// Five lines back toward the live screen, only while the pane is in copy mode (at the
    /// bottom, `copy-mode -e` exits). Outside a mode it does nothing.
    case scrollDown

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
        case .scrollUp, .scrollDown:
            return arguments.map { $0.contains(" ") || $0.contains("#") ? "\"\($0)\"" : $0 }
                .joined(separator: " ")
        }
    }

    /// `command` as the argv the launch passes to `bind`: plain commands split on spaces;
    /// the scroll commands keep their format and inner command string as ONE argument each
    /// (`if-shell` parses that string itself). No argument contains `@`, a quote, `$`,
    /// a backquote or a backslash (the launch joins them with `@` inside a double-quoted
    /// shell word).
    public var arguments: [String] {
        switch self {
        case .scrollUp:
            return ["if", "-F", "#{?alternate_on,#{pane_in_mode},1}", "copy-mode -e ; send -X -N 5 scroll-up"]
        case .scrollDown:
            return ["if", "-F", "#{pane_in_mode}", "send -X -N 5 scroll-down"]
        default:
            return command.split(separator: " ").map(String.init)
        }
    }
}
