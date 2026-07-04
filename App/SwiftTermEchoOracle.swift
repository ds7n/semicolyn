// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
#if canImport(SwiftTerm)
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

    init(resolveActiveView: @escaping @MainActor () -> TerminalView?) {
        self.resolveActiveView = resolveActiveView
    }

    func cursor() -> EchoCursor? {
        MainActor.assumeIsolated {
            guard let term = resolveActiveView()?.getTerminal() else { return nil }
            let pos = term.getCursorLocation()   // (x, y) column/row
            return EchoCursor(row: pos.y, col: pos.x)
        }
    }

    func cell(row: Int, col: Int) -> EchoCell? {
        MainActor.assumeIsolated {
            guard let term = resolveActiveView()?.getTerminal() else { return nil }
            // getCharData(col:row:) is 0-based; nil when out of range.
            guard let cd = term.getCharData(col: col, row: row) else { return nil }
            // CharData.getCharacter() yields the rendered Character; blank → nil.
            let ch = cd.getCharacter()
            if ch == "\u{0}" || ch == " " { return EchoCell(scalar: nil) }
            return EchoCell(scalar: ch.unicodeScalars.first)
        }
    }

    var isAlternateBuffer: Bool {
        MainActor.assumeIsolated {
            resolveActiveView()?.getTerminal().isCurrentBufferAlternate ?? false
        }
    }
}
#endif
