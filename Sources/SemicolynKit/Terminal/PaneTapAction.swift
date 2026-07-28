// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// What a single tap should do on a tmux pane, given whether that pane is
/// currently the active (focused) pane, its interaction mode, and whether a
/// text selection is active. The single source of truth for single-tap routing.
///
/// A tap on an INACTIVE pane always focuses it (in every mode); the tap is
/// consumed by the focus-switch and nothing is forwarded to the remote. A tap
/// on the ACTIVE pane runs the existing per-mode behavior.
public enum PaneTapAction: Equatable, Sendable {
    /// Inactive pane: focus it (`select-pane`), consume the tap.
    case focusPane
    /// Active pane in `.localScroll`: the existing tap behavior (place / clear).
    case active(TapAction)
    /// Active pane in an app-owned mode (`.appOwnsInput` / `.mouseReporting`):
    /// yield (SwiftTerm forwards the click, or nothing happens).
    case yield
}

/// Pure decider for a single tap on a pane. See `PaneTapAction`.
public func paneTapAction(isActivePane: Bool,
                          mode: InteractionMode,
                          hasSelection: Bool) -> PaneTapAction {
    guard isActivePane else { return .focusPane }
    switch mode {
    case .localScroll:
        return .active(tapAction(hasSelection: hasSelection))
    case .appOwnsInput, .mouseReporting:
        return .yield
    }
}
