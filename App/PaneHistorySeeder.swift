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
        // Post-feed snapshot: distinguishes "fed but into viewport (contentSize≈frame →
        // no scrollback)" from "view not laid out (frame/contentSize 0)" from "fed OK".
        DebugLog.shared.log(.seed, "seed applyHistory pane=%\(pane.raw) "
            + "post: rows=\(t.rows) topRow=\(t.getTopVisibleRow()) contentSize=\(view.contentSize)")
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
