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
