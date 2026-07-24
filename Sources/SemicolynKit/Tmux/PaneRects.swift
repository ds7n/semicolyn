// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// A leaf pane positioned in pixels (no CoreGraphics dependency — the App layer
/// converts to `CGRect`). Cell coordinates × cell metrics, top-left origin.
public struct PaneRect: Equatable, Sendable {
    public let pane: PaneID
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public init(pane: PaneID, x: Double, y: Double, width: Double, height: Double) {
        self.pane = pane; self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// Map each leaf pane of `layout` to a pixel rect, given the terminal cell size.
/// tmux reports absolute cell geometry per leaf, so this is a direct scale; the
/// 1-cell divider tmux reserves between panes is left as a visual gap (the App
/// draws a 1pt border, so abutting rects read as separate panes). Order matches
/// `PaneLayout.panes` (depth-first, the order tmux lists panes).
public func paneRects(in layout: PaneLayout, cellWidth: Double, cellHeight: Double) -> [PaneRect] {
    layout.panes.map { entry in
        PaneRect(
            pane: entry.pane,
            x: Double(entry.geometry.x) * cellWidth,
            y: Double(entry.geometry.y) * cellHeight,
            width: Double(entry.geometry.w) * cellWidth,
            height: Double(entry.geometry.h) * cellHeight
        )
    }
}

/// Scale `rects` so their bounding box exactly fills `(targetWidth, targetHeight)`,
/// preserving each pane's relative position and proportion.
///
/// Why: pane frames from `paneRects` are sized from tmux's `%layout` (rows/cols × cell),
/// which LAGS the client size we just reported — after a keyboard show/hide or window
/// switch, tmux's layout still reflects the previous (smaller) client, so a pane framed
/// straight from it undershoots the visible area and leaves dead space below the terminal
/// content, above the keybar (device 2026-07-24). Fitting the rects to the container's
/// real usable area closes that gap regardless of tmux's settle lag. For a single pane
/// this is an exact fill; for a split it scales every rect by the same x/y factor so the
/// panes still tile without overlap or gaps.
///
/// Returns `rects` unchanged when the target or the current bounding box is degenerate
/// (non-positive), failing closed like the other pure helpers. The bounding box is taken
/// from the rects' extent (min origin → max far edge), so a non-zero top/left origin
/// (multi-pane) is honored.
public func fitPaneRects(_ rects: [PaneRect],
                         toWidth targetWidth: Double,
                         toHeight targetHeight: Double) -> [PaneRect] {
    guard targetWidth > 0, targetHeight > 0, !rects.isEmpty else { return rects }
    let minX = rects.map(\.x).min() ?? 0
    let minY = rects.map(\.y).min() ?? 0
    let maxX = rects.map { $0.x + $0.width }.max() ?? 0
    let maxY = rects.map { $0.y + $0.height }.max() ?? 0
    let boxW = maxX - minX
    let boxH = maxY - minY
    guard boxW > 0, boxH > 0 else { return rects }
    let sx = targetWidth / boxW
    let sy = targetHeight / boxH
    return rects.map { r in
        PaneRect(
            pane: r.pane,
            x: (r.x - minX) * sx,
            y: (r.y - minY) * sy,
            width: r.width * sx,
            height: r.height * sy
        )
    }
}
