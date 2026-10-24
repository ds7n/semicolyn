// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftTerm
import SemicolynKit

/// Holds the terminal's tracked `InteractionMode`, recomputed from terminal state on
/// `bufferActivated` / `mouseModeChanged` (delivered via the `PaneTerminalView`
/// subclass overrides, NOT render-polling). The mount owns one so the mode
/// derivation lives in exactly one place. There is a single terminal view (raw shell
/// or plain tmux), and its live emulator alternate-screen flag is always reliable.
/// Not `@MainActor`: this is a plain main-thread-only helper owned by the (nonisolated)
/// mount `Coordinator`. Marking it `@MainActor` forced a boundary hop at every access
/// from that nonisolated coordinator (init, `mode`, `onChange`, `recompute`), which is
/// noise: the tracker is only ever touched on the main thread as part of SwiftUI /
/// SwiftTerm view callbacks. Leaving it nonisolated keeps all those call sites clean; the
/// single `@MainActor` dependency it has (the `DebugLog` logger) is wrapped locally below.
final class PaneModeTracker {
    private(set) var mode: InteractionMode = .localScroll
    /// Whether `mode` has been computed at least once (so the first recompute always fires
    /// `onChange`, even when it resolves to the default).
    private var primed = false
    /// Fired when the mode actually changes (deduped). App wires this to the mouse-dot
    /// and gesture context, all `@MainActor` UI state, so the closure is `@MainActor`;
    /// `recompute` (always on the main thread) invokes it via `assumeIsolated`.
    var onChange: @MainActor (InteractionMode) -> Void = { _ in }

    init() {}

    /// Recompute the `InteractionMode` from the live emulator state. Idempotent; only
    /// fires `onChange` on a real mode change.
    func recompute(terminal: Terminal) {
        let next = resolveMode(isAltScreen: terminal.isCurrentBufferAlternate,
                               mouseReporting: terminal.mouseMode != .off)
        guard !primed || mode != next else { return }
        primed = true
        mode = next
        // recompute is always called on the main thread (SwiftUI/SwiftTerm view
        // callbacks). Both the @MainActor logger and the @MainActor `onChange`
        // (which touches mouseDot UI state) run under one hop.
        MainActor.assumeIsolated {
            DebugLog.shared.log(.gesture, "mode[raw] -> \(next) (altSrc=raw)")
            onChange(next)
        }
    }
}
