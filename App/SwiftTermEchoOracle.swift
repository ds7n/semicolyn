// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
#if canImport(SwiftTerm)
import Foundation
import SwiftTerm
import SemicolynKit

/// App-tier `EchoOracle` backed by the *active pane's* live SwiftTerm terminal.
/// Maps the rendered grid onto the pure Kit protocol so the L1 detector's logic
/// stays Linux-tested. macOS-CI-only: this file does not build on the Linux job.
///
/// Resolves the active view on EACH sample via `resolveActiveView` (the active
/// pane changes across tmux windows/panes; a fixed capture would read the wrong
/// grid after a pane switch). Every accessor is defensive: a nil view, SwiftTerm
/// API drift, or out-of-range read returns nil / false, which the detector
/// treats as "not echoed" (suppress).
///
/// The resolver is `@MainActor`-bound (it reads `paneViews` on the view model);
/// the detector only calls it from the main-actor settle closure, so this stays
/// on-actor. Marked `@unchecked Sendable` because the closure is main-isolated in
/// practice; it is never invoked off the main actor.
struct SwiftTermEchoOracle: EchoOracle, @unchecked Sendable {
    let resolveActiveView: @MainActor () -> TerminalView?
    /// One copy of the viewport per main-loop turn: the detector reads hundreds of cells
    /// in a burst, and on SwiftTerm 2 each read would otherwise copy the screen.
    private let viewportCache = ViewportCache()

    init(resolveActiveView: @escaping @MainActor () -> TerminalView?) {
        self.resolveActiveView = resolveActiveView
    }

    func cursor() -> EchoCursor? {
        MainActor.assumeIsolated {
            guard let view = resolveActiveView() else { return nil }
            let pos = view.cursorCell
            return EchoCursor(row: pos.row, col: pos.col)
        }
    }

    func cell(row: Int, col: Int) -> EchoCell? {
        MainActor.assumeIsolated {
            guard let view = resolveActiveView() else { return nil }
            let rows = viewportCache.rows(for: view) { view.viewportCellTexts() }
            guard row >= 0, row < rows.count, col >= 0, col < rows[row].count else { return nil }
            return echoCell(fromCellText: rows[row][col])
        }
    }

    var isAlternateBuffer: Bool {
        MainActor.assumeIsolated {
            resolveActiveView()?.inputModes.isAlternateBuffer ?? false
        }
    }

    var columns: Int? {
        MainActor.assumeIsolated { resolveActiveView()?.gridSize.cols }
    }
}

/// The viewport's cell texts, copied once and dropped at the end of the main-loop turn,
/// so the next keystroke's reads see fresh output. Main-thread only (every caller is
/// inside `MainActor.assumeIsolated`), hence `@unchecked Sendable`.
private final class ViewportCache: @unchecked Sendable {
    private var view: ObjectIdentifier?
    private var cached: [[String]]?

    func rows(for terminal: AnyObject, copy: () -> [[String]]) -> [[String]] {
        let id = ObjectIdentifier(terminal)
        if let cached, view == id { return cached }
        let fresh = copy()
        view = id
        cached = fresh
        DispatchQueue.main.async { [weak self] in self?.cached = nil }
        return fresh
    }
}
#endif
