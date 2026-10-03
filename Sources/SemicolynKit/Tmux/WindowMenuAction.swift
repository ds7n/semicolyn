// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// A pane/window action from the keybar dpad long-press menu. The App
/// (`PlainTmuxController.onWindowAction`) maps each case to a `TmuxAction` and sends
/// that action's private bound sequence (`gestureSequence`); the bound command acts on
/// the currently-active pane, which is the target.
public enum WindowMenuAction: CaseIterable, Sendable {
    case splitHorizontal   // pane to the right
    case splitVertical     // pane below
    case closePane
    case newWindow
    case zoom
}
