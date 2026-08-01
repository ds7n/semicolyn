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
    /// Active pane: the tap behavior (place / clear / re-summon). A live selection is
    /// handled this way in every mode; with no selection this only applies in `.localScroll`.
    case active(TapAction)
    /// Active pane in an app-owned mode (`.appOwnsInput` / `.mouseReporting`):
    /// yield (SwiftTerm forwards the click, or nothing happens).
    case yield
}

/// Pure decider for a single tap on a pane. See `PaneTapAction`.
public func paneTapAction(isActivePane: Bool,
                          mode: InteractionMode,
                          hasSelection: Bool,
                          tapInsideSelection: Bool) -> PaneTapAction {
    guard isActivePane else { return .focusPane }
    // A live selection's tap-to-(re-summon/clear) applies in every mode, before the
    // app-owned yield: double-tap can create a selection on the alt-screen too.
    if hasSelection {
        return .active(tapAction(hasSelection: true, tapInsideSelection: tapInsideSelection))
    }
    switch mode {
    case .localScroll:
        return .active(tapAction(hasSelection: false, tapInsideSelection: false))
    case .appOwnsInput, .mouseReporting:
        return .yield
    }
}
