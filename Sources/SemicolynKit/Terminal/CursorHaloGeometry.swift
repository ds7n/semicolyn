// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Where the cursor-placement halo sits, in pane-local points.
public struct CursorHaloPlacement: Equatable, Sendable {
    public let centerX: Double
    public let centerY: Double
    public let radius: Double
    /// True when the cursor row is outside the visible window (scrolled into scrollback) —
    /// drives the offscreen `⌖` indicator instead of the halo.
    public let isOffscreen: Bool
    public init(centerX: Double, centerY: Double, radius: Double, isOffscreen: Bool) {
        self.centerX = centerX
        self.centerY = centerY
        self.radius = radius
        self.isOffscreen = isOffscreen
    }
}

/// Halo center for a cursor at `(cursorCol, cursorRow)` (cell coords), placed at the cell
/// center and clamped so a `radius`-radius disc stays within the pane ("halo only on the
/// focused pane, clamped to pane geometry"). Returns nil for degenerate (non-positive) cell,
/// pane, or radius dimensions — failing closed like `terminalGrid`.
public func cursorHaloPlacement(cursorCol: Int, cursorRow: Int,
                                cellWidth: Double, cellHeight: Double,
                                paneWidth: Double, paneHeight: Double,
                                visibleRows: Int, radius: Double) -> CursorHaloPlacement? {
    guard cellWidth > 0, cellHeight > 0, paneWidth > 0, paneHeight > 0, radius > 0 else { return nil }
    let rawX = (Double(cursorCol) + 0.5) * cellWidth
    let rawY = (Double(cursorRow) + 0.5) * cellHeight
    let cx = clampIntoPane(rawX, radius, paneWidth - radius)
    let cy = clampIntoPane(rawY, radius, paneHeight - radius)
    let offscreen = cursorRow < 0 || cursorRow >= visibleRows
    return CursorHaloPlacement(centerX: cx, centerY: cy, radius: radius, isOffscreen: offscreen)
}

/// Clamp into `[lo, hi]`; if the pane is narrower than the disc (`lo > hi`), center it.
private func clampIntoPane(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
    guard lo <= hi else { return (lo + hi) / 2 }
    return min(max(v, lo), hi)
}
