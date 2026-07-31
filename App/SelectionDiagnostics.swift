// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SwiftTerm

/// One-line snapshot of a terminal view's live selection state for the
/// invisible-highlight diagnostic (spec 3g). Reports the ACTIVE flag, the
/// selection grid range, and the configured highlight COLOR at a given phase
/// (after-set / after-redraw / on-repaint), so the device log shows exactly
/// where state diverges between normal-screen and alt-screen. Logs coordinates
/// and a color description only, never selected text content (privacy).
enum SelectionDiagnostics {
    /// `phase` is one of "set" | "redraw" | "repaint". `mode` is the caller's
    /// current interaction mode string (e.g. "localScroll" / "appOwnsInput").
    static func snapshot(_ view: TerminalView, phase: String, mode: String) -> String {
        let active = view.selectionActive
        let color = describe(view.selectedTextBackgroundColor)

        guard let sel = view.selection else {
            return "sel:diag phase=\(phase) mode=\(mode) active=\(active) range=nil span=0 color=\(color)"
        }

        let start = sel.start
        let end = sel.end
        let range = "(\(start.col),\(start.row))->(\(end.col),\(end.row))"
        let span: Int
        if start.row == end.row {
            span = end.col - start.col
        } else {
            let cols = view.getTerminal().cols
            span = (end.row - start.row) * cols + (end.col - start.col)
        }
        return "sel:diag phase=\(phase) mode=\(mode) active=\(active) range=\(range) span=\(span) color=\(color)"
    }

    /// Human-readable color + alpha so a transparent/unset highlight (candidate #2)
    /// is obvious in the log.
    private static func describe(_ c: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "rgba(%.2f,%.2f,%.2f,%.2f)", r, g, b, a)
    }
}
