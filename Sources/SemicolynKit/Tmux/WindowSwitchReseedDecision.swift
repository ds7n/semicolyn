// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Pure decision: when a render applies a new active window, should the now-active
/// window's panes be force-reseeded (a fresh `capture-pane`)?
///
/// Switching tmux windows tears down the off-screen window's pane views and re-creates
/// empty ones on return, but each pane's `PaneSeedState` persists as `.seeded`, so the
/// normal `paneDidAppear` path treats the fresh view as already-seeded and never
/// re-captures. The returned-to window then renders blank (just a cursor) and its prior
/// screen + scrollback stay lost until a full re-attach (which re-seeds everything).
/// Forcing a reseed on a switch repaints it via the same pipeline attach uses.
///
/// The one thing to get right: reseed on a genuine window SWITCH, but NOT on the initial
/// attach. On attach `previous` is `nil` (no window was active yet) and the fresh panes
/// were already seeded by the normal appear path — reseeding them would double-issue a
/// `capture-pane`. A switch is exactly `previous != nil && new != previous`.
public struct WindowSwitchReseedDecision: Sendable {
    /// True iff moving from `previous` to `new` is a window switch that should reseed the
    /// now-active window's panes. False on the initial attach (`previous == nil`), when the
    /// active window is unchanged, and when there is no active window (`new == nil`).
    public static func shouldReseed<W: Equatable>(previous: W?, new: W?) -> Bool {
        guard let new else { return false }        // no active window → nothing to reseed
        guard let previous else { return false }   // initial attach → normal seed already ran
        return new != previous                     // a real switch to a different window
    }
}
