// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SwiftTerm
import SemicolynKit

/// Off-screen `capture-pane` snapshots of tmux windows, so the live finger-drag window
/// transition can reveal a real preview of an adjacent window (whose live panes do not
/// exist locally under `-CC` until the switch commits). One hosting `UIView` per window;
/// each holds a SwiftTerm `TerminalView` per pane, positioned from the window's
/// `visibleLayout`. Fed by `TmuxRuntime.captureSnapshot` -> `onSnapshotCaptured`.
///
/// A reply for a pane whose window was closed is dropped (its `paneWindow` entry is
/// cleared in `rebuild`, so `applyCapture` guards it out). Replies for a live pane arrive
/// in issue order (tmux resolves command results FIFO), so the latest capture's bytes are
/// the ones that land.
@MainActor
final class WindowSnapshotStore {
    private let runtime: TmuxRuntime
    private let scrollbackLines: () -> Int
    private let makeSnapshotView: (PaneID) -> TerminalView

    /// Hosting container per window (holds that window's pane snapshot views).
    private var windowViews: [WindowID: UIView] = [:]
    /// The snapshot TerminalView per pane, and which window it belongs to.
    private var paneViews: [PaneID: TerminalView] = [:]
    private var paneWindow: [PaneID: WindowID] = [:]

    init(runtime: TmuxRuntime,
         scrollbackLines: @escaping () -> Int,
         makeSnapshotView: @escaping (PaneID) -> TerminalView) {
        self.runtime = runtime
        self.scrollbackLines = scrollbackLines
        self.makeSnapshotView = makeSnapshotView
        runtime.onSnapshotCaptured = { [weak self] pane, bytes in
            self?.applyCapture(pane, bytes)
        }
    }

    /// Fire a fresh `capture-pane` for every pane in every NON-active window. Called on
    /// connect and at each drag-start. The active window is already live, so it is skipped.
    func refreshNonActive(state: TmuxSessionState) {
        let lines = scrollbackLines()
        guard lines > 0 else { return }
        for window in state.windows where window.id != state.activeWindow {
            // `visibleLayout?.panes` yields (pane: PaneID, geometry: Geometry) leaves.
            for leaf in window.visibleLayout?.panes ?? [] {
                noteCapture(leaf.pane, window: window.id)
                runtime.captureSnapshot(pane: leaf.pane, lines: lines)
            }
        }
    }

    /// Drop hosting views for windows that no longer exist; clear their panes' `paneWindow`
    /// entries so any in-flight reply is dropped by `applyCapture`. Called on a window-list
    /// change.
    func rebuild(state: TmuxSessionState) {
        let live = Set(state.windows.map(\.id))
        for (win, view) in windowViews where !live.contains(win) {
            view.removeFromSuperview()
            windowViews[win] = nil
        }
        let livePanes = Set(state.windows.flatMap { win in
            (win.visibleLayout?.panes ?? []).map { $0.pane }
        })
        for pane in paneViews.keys where !livePanes.contains(pane) {
            paneViews[pane] = nil
            paneWindow[pane] = nil
        }
    }

    /// The hosting view for `window`'s snapshot, or nil if nothing captured yet.
    func snapshotView(for window: WindowID) -> UIView? { windowViews[window] }

    private func noteCapture(_ pane: PaneID, window: WindowID) {
        paneWindow[pane] = window
    }

    /// Apply a snapshot capture reply: feed the bytes into the pane's snapshot TerminalView,
    /// creating the view + its window host on first sight. Ignores a pane whose window is
    /// gone (dropped in `rebuild`).
    private func applyCapture(_ pane: PaneID, _ bytes: [UInt8]) {
        guard let window = paneWindow[pane] else { return }   // pane retired
        let host = windowViews[window] ?? {
            let v = UIView(); windowViews[window] = v; return v
        }()
        let view = paneViews[pane] ?? {
            let v = makeSnapshotView(pane)
            paneViews[pane] = v
            host.addSubview(v)
            return v
        }()
        // A snapshot view is a fresh, never-live preview and each capture REPLACES the
        // whole buffer, so a full clear before feeding is correct here (unlike the live
        // seeder, which must preserve the on-screen content and instead feeds ESC[3J).
        // Clear via the scrollback-erase escape (`feed` is the confirmed public path;
        // `feed(byteArray:)` is used by PaneHistorySeeder). Feeding a full capture over a
        // cleared buffer yields the previewed screen.
        view.feed(byteArray: [0x1b, 0x5b, 0x33, 0x4a][...])   // ESC [ 3 J (erase scrollback)
        if !bytes.isEmpty { view.feed(byteArray: bytes[...]) }
        DebugLog.shared.log(.seed, "snapshot applied pane=%\(pane.raw) win=@\(window.raw) bytes=\(bytes.count)")
    }

    /// Lay out `window`'s pane snapshot views inside its host at `bounds`, using the pane
    /// rects from `state`. Call right before revealing the host in the drag gap so the
    /// snapshot matches the current container geometry.
    func layout(window: WindowID, in state: TmuxSessionState, bounds: CGRect,
                cellWidth: Double, cellHeight: Double) {
        guard let host = windowViews[window], let win = state.window(window),
              let layout = win.visibleLayout else { return }
        host.frame = bounds
        // Reuse the same Kit helper the live container uses to place panes: it maps each
        // leaf's cell geometry to a pixel rect (top-left origin) via the cell metrics.
        for rect in paneRects(in: layout, cellWidth: cellWidth, cellHeight: cellHeight) {
            guard let view = paneViews[rect.pane] else { continue }
            view.frame = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        }
    }
}
