// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// How a single tap on a tmux pane is delivered. `.forwardClick` = send an SGR
/// mouse click so tmux (mouse on) selects the exact tapped pane; `.cyclePane`
/// = send the `cyclePane` private bound sequence to cycle focus (mouse off;
/// best-effort, exact for 2 panes).
public enum TapPaneRoute: Equatable, Sendable {
    case forwardClick
    case cyclePane
}

/// Pure tap-route decider: forward a click iff the remote requested mouse mode.
public func tapPaneRoute(mouseModeOn: Bool) -> TapPaneRoute {
    mouseModeOn ? .forwardClick : .cyclePane
}
