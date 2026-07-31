// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SwiftTerm

/// One-line snapshot of a terminal view's live selection state for the
/// invisible-highlight diagnostic (spec 3g). Reports the ACTIVE flag, a
/// content-free selection-length proxy, and the configured highlight COLOR
/// at a given phase (after-set / after-redraw / on-repaint), so the device
/// log shows exactly where state diverges between normal-screen and
/// alt-screen. Logs a length count and a color description only, never
/// selected text content (privacy).
enum SelectionDiagnostics {
    /// `phase` is one of "set" | "redraw" | "repaint". `mode` is the caller's
    /// current interaction mode string (e.g. "localScroll" / "appOwnsInput").
    static func snapshot(_ view: TerminalView, phase: String, mode: String) -> String {
        let active = view.selectionActive
        let color = describe(view.selectedTextBackgroundColor)
        let selLen = view.getSelection()?.count ?? 0
        return "sel:diag phase=\(phase) mode=\(mode) active=\(active) selLen=\(selLen) color=\(color)"
    }

    /// Human-readable color + alpha so a transparent/unset highlight (candidate #2)
    /// is obvious in the log.
    private static func describe(_ c: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "rgba(%.2f,%.2f,%.2f,%.2f)", r, g, b, a)
    }
}
