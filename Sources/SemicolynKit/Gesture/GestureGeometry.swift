// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Viewport point <-> cell arithmetic for the gesture engine.
public enum GestureGeometry {
    /// The cell under a viewport point, clamped to the grid. Rows map in CONTENT space:
    /// absolute row = floor((y + contentOffsetY) / cellHeight), clamped to the viewport rows
    /// `topRow ... topRow + rows - 1` (the partial row sliver above the top row at the live
    /// bottom clamps to the top row). A zero cell size (layout not ready) maps to column 0 of
    /// the top row.
    public static func cell(at p: GesturePoint, in c: GestureContext) -> GestureCell {
        guard c.cellWidth > 0, c.cellHeight > 0 else { return GestureCell(col: 0, row: c.topRow) }
        let col = min(max(0, Int((p.x / c.cellWidth).rounded(.down))), max(c.cols - 1, 0))
        let contentRow = Int(((p.y + c.contentOffsetY) / c.cellHeight).rounded(.down))
        let row = min(max(c.topRow, contentRow), c.topRow + max(c.rows - 1, 0))
        return GestureCell(col: col, row: row)
    }

    /// A cell's rect in viewport coordinates (content y minus the content offset).
    public static func handleRect(for cell: GestureCell, in c: GestureContext) -> SelectionHandleRect {
        SelectionHandleRect(x: Double(cell.col) * c.cellWidth,
                            y: Double(cell.row) * c.cellHeight - c.contentOffsetY,
                            width: c.cellWidth, height: c.cellHeight)
    }

    /// Which selection handle (if any) is under `p`, with fingertip slop.
    public static func handle(at p: GesturePoint, in c: GestureContext) -> SelectionEnd? {
        guard let s = c.selection else { return nil }
        return hitTestHandle(point: SelectionHandlePoint(x: p.x, y: p.y),
                             startRect: handleRect(for: s.start, in: c),
                             endRect: handleRect(for: s.end, in: c),
                             slop: GestureThresholds.handleSlop)
    }

    public static func isInsideSelection(_ cell: GestureCell, in c: GestureContext) -> Bool {
        guard let s = c.selection else { return false }
        return isWithinSelection(col: cell.col, row: cell.row,
                                 start: (s.start.col, s.start.row), end: (s.end.col, s.end.row))
    }
}
