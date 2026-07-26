// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SwiftTerm
import SemicolynKit

/// Orchestrates tmux -CC history seeding for each pane: on first render, capture the
/// pane's scrollback from tmux and feed it into SwiftTerm BEFORE live output; buffer
/// `%output` that races the capture (via `PaneSeedState`); re-seed on resync.
@MainActor
final class PaneHistorySeeder {
    private let runtime: TmuxRuntime
    private let scrollbackLines: () -> Int
    private let viewForPane: (PaneID) -> TerminalView?
    private var states: [PaneID: PaneSeedState] = [:]
    /// Panes whose history was just applied and still need a scroll-to-bottom once the
    /// terminal's row count has SETTLED to the container grid. Confirmed root cause of the
    /// switched-window keybar gap (geometry log 2026-07-26): the pane FRAME is correct
    /// (gapPx=0), but `applyHistory` leaves the terminal's viewport SHORT of the true bottom
    /// (e.g. topRow=192 when maxScrollback=214) — SwiftTerm's feed + the later async tmux
    /// resize strand yDisp below yBase for panes reattaching into large scrollback. First
    /// connect has small content that fits, so it never strands; reconnect re-seeds the same
    /// large scrollback and strands identically (why only a full restart "fixed" it). The
    /// container drains this set via `bottomAlignAfterResize` (fired from SwiftTerm
    /// `sizeChanged`) when a pane's terminal rows reach the settled grid, forcing
    /// topRow = maxScrollback.
    private var pendingBottomAlign: Set<PaneID> = []

    init(runtime: TmuxRuntime,
         scrollbackLines: @escaping () -> Int,
         viewForPane: @escaping (PaneID) -> TerminalView?) {
        self.runtime = runtime
        self.scrollbackLines = scrollbackLines
        self.viewForPane = viewForPane

        runtime.onHistoryCaptured = { [weak self] pane, history in
            self?.applyHistory(pane, history)
        }
        runtime.onResyncAll = { [weak self] in
            self?.resyncAll()
        }
    }

    /// Call when a pane first renders. Issues the capture if the pane still needs one.
    /// If seeding is disabled or the capture can't be sent (`captureHistory` returns
    /// nil — e.g. `scrollbackLines <= 0`), transition straight to `.seeded` so live
    /// output passes through instead of being buffered forever (a blank pane). This is
    /// the spec's "0 → skip, show live-only" behavior; `completeSeed(history: [])` from
    /// `.unseeded` flushes any already-buffered output and marks the pane seeded.
    func paneDidAppear(_ pane: PaneID) {
        var state = states[pane] ?? PaneSeedState()
        let needsSeed = state.needsSeed
        if needsSeed {
            let lines = scrollbackLines()
            let queued = runtime.captureHistory(pane: pane, lines: lines) != nil
            if queued {
                state.beginSeeding()
            } else {
                // No capture will arrive → don't strand output. Feed any buffered bytes
                // straight to the view and mark seeded (live-only).
                let flush = state.completeSeed(history: [])
                if !flush.isEmpty, let view = viewForPane(pane) {
                    view.feed(byteArray: flush[...])
                }
            }
            DebugLog.shared.log(.seed, decisionLine(
                "seed:request",
                inputs: [("pane", "%\(pane.raw)"), ("needsSeed", "\(needsSeed)"), ("lines", "\(lines)")],
                outputs: [("captureQueued", "\(queued)")],
                reason: queued ? "capture-sent" : "no-capture(lines<=0 or disabled)"))
        } else {
            DebugLog.shared.log(.seed, decisionLine(
                "seed:request",
                inputs: [("pane", "%\(pane.raw)"), ("needsSeed", "\(needsSeed)")],
                outputs: [("captureQueued", "false")],
                reason: "already-seeded"))
        }
        states[pane] = state
    }

    /// Drop a pane's seed state when its view is torn down (window switch / reattach).
    /// Switching tmux windows destroys the off-screen window's pane views and re-creates
    /// fresh empty ones on return. The seed state must NOT persist across that: if it stayed
    /// `.seeded`, the next `paneDidAppear` (fired by `registerPane` when the fresh view
    /// mounts) would treat the empty view as already-seeded and skip the capture → the
    /// returned-to window renders blank until a full re-attach. Forgetting it here makes the
    /// remount seed EXACTLY like a first connect: one `paneDidAppear` → one `capture-pane`.
    ///
    /// This replaced an earlier `recapture()` that reset the state AND issued its own capture
    /// from `apply()` — but `registerPane` already calls `paneDidAppear` on the fresh view, so
    /// that was a SECOND capture whose reply double-fed the history (content duplicated →
    /// viewport scrolled deep into the dup'd scrollback → the live prompt sat mid-buffer, not
    /// at the screen bottom → a gap above the keybar on switched-to windows; first connect,
    /// which seeds once, never had it — device 2026-07-26). One reset here, zero extra
    /// captures, is the single-seed path both cases now share.
    func forgetSeedState(_ pane: PaneID) {
        pendingBottomAlign.remove(pane)   // its view is going away; drop any pending align
        guard states[pane] != nil else { return }
        states[pane] = nil
        DebugLog.shared.log(.seed, decisionLine(
            "seed:forget",
            inputs: [("pane", "%\(pane.raw)")],
            outputs: [("reset", "true")],
            reason: "view-torn-down"))
    }

    /// Route live pane output through the seed state (buffer during seed, else feed).
    func routeOutput(_ pane: PaneID, _ bytes: [UInt8]) -> [UInt8] {
        var state = states[pane] ?? PaneSeedState()
        let out = state.onOutput(bytes)
        states[pane] = state
        return out
    }

    // MARK: Private

    private func applyHistory(_ pane: PaneID, _ history: [UInt8]) {
        var state = states[pane] ?? PaneSeedState()
        let flush = state.completeSeed(history: history)
        states[pane] = state
        guard let view = viewForPane(pane) else {
            DebugLog.shared.log(.seed, "seed applyHistory pane=%\(pane.raw) NO VIEW (dropped \(flush.count)B)")
            return
        }
        let t = view.getTerminal()
        // Public-API-only proxies (buffer.lines/yBase are internal to SwiftTerm):
        //   contentSize.height = lines.count × cellHeight (drives scrollability directly);
        //   getTopVisibleRow() > 0 iff there IS scrollback above the viewport;
        //   frame confirms the view is laid out (cellDimension 0 → contentSize 0).
        DebugLog.shared.log(.seed, "seed applyHistory pane=%\(pane.raw) flush=\(flush.count)B "
            + "pre: rows=\(t.rows) topRow=\(t.getTopVisibleRow()) "
            + "contentSize=\(view.contentSize) frame=\(view.frame.size)")
        clearScrollback(view)
        if !flush.isEmpty { view.feed(byteArray: flush[...]) }
        // Scroll to the bottom now (best-effort) AND mark the pane so the container re-aligns
        // once the terminal's rows SETTLE to the grid. Feeding leaves the viewport short of the
        // true bottom when the pane reattaches into large scrollback and the tmux resize lands
        // AFTER the feed (geometry log 2026-07-26: topRow=192 vs maxScrollback=214) → the gap.
        // A single scroll here isn't enough because the row count is still mid-settle; the
        // container's `bottomAlignIfRowsSettled` finishes the job when rows == grid.
        view.scroll(toPosition: 1.0)
        pendingBottomAlign.insert(pane)
        // Post-feed snapshot: distinguishes "fed but into viewport (contentSize≈frame →
        // no scrollback)" from "view not laid out (frame/contentSize 0)" from "fed OK".
        DebugLog.shared.log(.seed, "seed applyHistory pane=%\(pane.raw) "
            + "post: rows=\(t.rows) topRow=\(t.getTopVisibleRow()) contentSize=\(view.contentSize)")
    }

    /// Called when a pane's terminal ROW COUNT changes (SwiftTerm `sizeChanged` → a tmux resize
    /// landed), with `settledRows` = the row count the container currently wants (its last grid).
    /// While the pane is freshly-seeded and pending, EVERY resize re-scrolls it to the true
    /// bottom — the switched-window resize arrives as a SEQUENCE (e.g. 62 → 37 → 32), and any
    /// one of them can re-strand the viewport, so aligning only once is not enough. The pane is
    /// cleared from pending only when its rows reach `settledRows` (the animation is done), so a
    /// later user scroll-up is preserved. This is the fix for the keybar gap: the seed leaves
    /// `topRow` short of `maxScrollback` because the resize lands after the feed (geometry log
    /// 2026-07-26: topRow=192 vs a 214 bottom). No-op if the pane isn't pending.
    func bottomAlignAfterResize(_ pane: PaneID, settledRows: Int) {
        guard pendingBottomAlign.contains(pane), let view = viewForPane(pane) else { return }
        view.scroll(toPosition: 1.0)
        let t = view.getTerminal()
        let done = (t.rows == settledRows)
        if done { pendingBottomAlign.remove(pane) }
        DebugLog.shared.log(.seed, decisionLine(
            "seed:bottomAlign",
            inputs: [("pane", "%\(pane.raw)"), ("rows", "\(t.rows)"), ("settledRows", "\(settledRows)")],
            outputs: [("topRow", "\(t.getTopVisibleRow())"), ("cleared", "\(done)")],
            reason: done ? "rows-settled" : "resize-step"))
    }

    private func resyncAll() {
        for pane in states.keys {
            var s = states[pane] ?? PaneSeedState()
            s.resync()
            states[pane] = s
        }
        let visiblePanes = states.keys.filter { viewForPane($0) != nil }
        DebugLog.shared.log(.seed, decisionLine(
            "seed:resync",
            inputs: [],
            outputs: [("reset", "\(states.count)"), ("recaptured", "\(visiblePanes.count)")],
            reason: "resync"))
        // Re-capture panes that currently have a view (visible).
        for pane in visiblePanes {
            paneDidAppear(pane)
        }
    }

    /// Clear SwiftTerm's scrollback so a (re)seed doesn't duplicate history, without
    /// touching the live viewport. `resetToInitialState()` was considered (see the
    /// task brief) but is a full RIS: it resets buffer contents AND the scroll area,
    /// wiping the live screen too — too aggressive for a reseed while the pane may
    /// already be showing live content.
    ///
    /// Instead, feed the terminal `ESC [ 3 J` (CSI `Ps J` with `Ps = 3`, "Erase Saved
    /// Lines" / xterm scrollback-clear) through the same `feed(byteArray:)` path the
    /// class already uses for live output. SwiftTerm's `cmdEraseInDisplay` handles
    /// `p == 3` by trimming `buffer.lines` down to just the viewport rows and rebasing
    /// `yBase`/`yDisp` — it does not call `resetBufferLine` on any row, so the visible
    /// screen content is untouched. That handler is internal to SwiftTerm, so it can
    /// only be reached by feeding the escape sequence, not called directly.
    private func clearScrollback(_ view: TerminalView) {
        view.feed(byteArray: [0x1b, 0x5b, 0x33, 0x4a][...])   // ESC [ 3 J
    }
}
