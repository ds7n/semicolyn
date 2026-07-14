// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftTerm
import SemicolynKit

/// How a `recompute` learns a pane's alternate-screen truth.
enum AltSource {
    /// A real `?1049` transition (SwiftTerm `bufferActivated`): the live flag is
    /// authoritative now, so adopt and persist it.
    case liveTransition
    /// A non-alt event (`mouseModeChanged`) or an attach prime: keep the tracked flag,
    /// do not overwrite it from the (possibly stale) live flag.
    case keepTracked
    /// A raw (non-tmux) pane: the live emulator flag is always reliable, use it directly.
    case rawLive
}

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
    // Authoritative alternate-screen flag per TMUX pane (PaneID != nil). SEEDED by the
    // attach-time #{alternate_on} query (setAltScreenOverride) and updated ONLY on a real
    // `?1049` transition (a `.liveTransition` recompute), so a pane already on the alternate
    // screen before this -CC client attached (its `?1049h` predated our stream, and tmux
    // never replays it) stays correct until a real exit transition. NOT consume-once: the
    // build-46 device trace showed consume-once reverts to the permanently-wrong live flag.
    // Raw (non-tmux) panes never populate this (their live flag is reliable).
    private var altState: [PaneID?: Bool] = [:]
    /// Fired when a pane's mode actually changes (deduped). App wires this to the
    /// pane's gesture controller (isScrollEnabled + routing) and mouse-dot — all
    /// `@MainActor` UI state, so the closure is `@MainActor`; `recompute` (always on
    /// the main thread) invokes it via `assumeIsolated`.
    var onChange: @MainActor (PaneID?, InteractionMode) -> Void = { _, _ in }

    init() {}

    func mode(for pane: PaneID?) -> InteractionMode { modes[pane] ?? .localScroll }

    /// Recompute a pane's `InteractionMode`. Idempotent; only fires `onChange` on a real
    /// mode change. `altSource` decides how the alternate-screen input is derived (see
    /// `AltSource`): the tracked `altState` is the source of truth for tmux panes, updated
    /// only on a live `?1049` transition.
    func recompute(for pane: PaneID?, terminal: Terminal, altSource: AltSource) {
        let liveAlt = terminal.isCurrentBufferAlternate
        let isAlt: Bool
        switch altSource {
        case .rawLive:
            isAlt = liveAlt
        case .liveTransition:
            altState[pane] = liveAlt        // ?1049 just parsed: adopt and persist the live truth
            isAlt = liveAlt
        case .keepTracked:
            isAlt = altState[pane] ?? liveAlt   // tracked wins; fall to live only if never seeded
        }
        let next = resolveMode(isAltScreen: isAlt,
                               mouseReporting: terminal.mouseMode != .off)
        if modes[pane] != next {
            modes[pane] = next
            // recompute is always called on the main thread (SwiftUI/SwiftTerm view
            // callbacks). Both the @MainActor logger and the @MainActor `onChange`
            // (which touches isScrollEnabled / mouseDot UI state) run under one hop.
            let label: String
            switch altSource {
            case .rawLive: label = "raw"
            case .liveTransition: label = "live"
            case .keepTracked: label = altState[pane] != nil ? "tracked" : "live"
            }
            MainActor.assumeIsolated {
                DebugLog.shared.log(.gesture, "mode[\(pane.map { "%\($0.raw)" } ?? "raw")] -> \(next) (altSrc=\(label))")
                onChange(pane, next)
            }
        }
    }

    // Single-pane conveniences for the raw mount.
    var mode: InteractionMode { mode(for: nil) }
    func recompute(terminal: Terminal, altSource: AltSource) {
        recompute(for: nil, terminal: terminal, altSource: altSource)
    }

    /// Seed the attach-time alternate-screen truth for `pane` (from tmux's `#{alternate_on}`)
    /// into the persistent `altState`, then recompute. The seed is authoritative for this tmux
    /// pane until a real `?1049` transition (a `.liveTransition` recompute) updates it.
    func setAltScreenOverride(for pane: PaneID?, isAlt: Bool, terminal: Terminal) {
        altState[pane] = isAlt
        recompute(for: pane, terminal: terminal, altSource: .keepTracked)
    }

    /// Drop a destroyed pane's tracked mode so a later pane reusing the same
    /// `PaneID` recomputes from scratch (the dedup in `recompute` must not compare
    /// against a dead pane's stale value). Call from the mount's pane-removal path.
    func forget(_ pane: PaneID?) {
        modes[pane] = nil
        altState[pane] = nil
    }
}
