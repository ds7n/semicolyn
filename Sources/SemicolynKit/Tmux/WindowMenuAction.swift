// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// A pane/window action from the keybar dpad long-press menu. Each maps to tmux's
/// DEFAULT single-key prefix binding, sent as `<prefix><key>` (never command-mode,
/// no `-t`): the binding acts on the currently-active pane, which is the target.
public enum WindowMenuAction: CaseIterable, Sendable {
    case splitHorizontal   // pane to the right
    case splitVertical     // pane below
    case closePane
    case newWindow
    case zoom

    /// The tmux default prefix key for this action.
    public var prefixKey: Character {
        switch self {
        case .splitHorizontal: return "%"
        case .splitVertical:   return "\""
        case .closePane:       return "x"
        case .newWindow:       return "c"
        case .zoom:            return "z"
        }
    }
}
