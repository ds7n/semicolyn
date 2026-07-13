// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftTerm
import SemicolynKit

/// Holds each pane's tracked `InteractionMode`, recomputed from terminal state on
/// `bufferActivated` / `mouseModeChanged` (delivered via the `PaneTerminalView`
/// subclass overrides, NOT render-polling). Both mount sites own one so the mode
/// derivation lives in exactly one place. Keyed by `PaneID?` — nil = the single raw
/// (non-tmux) pane.
/// Not `@MainActor`: this is a plain main-thread-only helper owned by the (nonisolated)
/// mount `Coordinator`s. Marking it `@MainActor` forced a boundary hop at every access
/// from those nonisolated coordinators (init, `mode`, `onChange`, `recompute`), which is
/// noise — the tracker is only ever touched on the main thread as part of SwiftUI /
/// SwiftTerm view callbacks. Leaving it nonisolated keeps all those call sites clean; the
/// single `@MainActor` dependency it has (the `DebugLog` logger) is wrapped locally below.
final class PaneModeTracker {
    // Keyed by PaneID? — nil is the single raw (non-tmux) pane. PaneID is UInt32-backed
    // (no room for a sentinel), so the optional key is the clean single-pane spelling.
    private var modes: [PaneID?: InteractionMode] = [:]
    /// Fired when a pane's mode actually changes (deduped). App wires this to the
    /// pane's gesture controller (isScrollEnabled + routing) and mouse-dot — all
    /// `@MainActor` UI state, so the closure is `@MainActor`; `recompute` (always on
    /// the main thread) invokes it via `assumeIsolated`.
    var onChange: @MainActor (PaneID?, InteractionMode) -> Void = { _, _ in }

    init() {}

    func mode(for pane: PaneID?) -> InteractionMode { modes[pane] ?? .localScroll }

    /// Recompute from live terminal state. Idempotent; only fires `onChange` on a
    /// real transition.
    func recompute(for pane: PaneID?, terminal: Terminal) {
        let next = resolveMode(isAltScreen: terminal.isCurrentBufferAlternate,
                               mouseReporting: terminal.mouseMode != .off)
        if modes[pane] != next {
            modes[pane] = next
            // recompute is always called on the main thread (SwiftUI/SwiftTerm view
            // callbacks). Both the @MainActor logger and the @MainActor `onChange`
            // (which touches isScrollEnabled / mouseDot UI state) run under one hop.
            MainActor.assumeIsolated {
                DebugLog.shared.log(.gesture, "mode[\(pane.map { "%\($0.raw)" } ?? "raw")] -> \(next)")
                onChange(pane, next)
            }
        }
    }

    // Single-pane conveniences for the raw mount.
    var mode: InteractionMode { mode(for: nil) }
    func recompute(terminal: Terminal) { recompute(for: nil, terminal: terminal) }

    /// Drop a destroyed pane's tracked mode so a later pane reusing the same
    /// `PaneID` recomputes from scratch (the dedup in `recompute` must not compare
    /// against a dead pane's stale value). Call from the mount's pane-removal path.
    func forget(_ pane: PaneID?) {
        modes[pane] = nil
    }
}
