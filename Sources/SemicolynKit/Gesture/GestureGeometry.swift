// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Viewport point <-> cell arithmetic for the gesture engine.
public enum GestureGeometry {
    /// The cell under a viewport point, clamped to the grid. Absolute row = top visible row
    /// + viewport row. A zero cell size (layout not ready) maps to column 0 of the top row.
    public static func cell(at p: GesturePoint, in c: GestureContext) -> GestureCell {
        guard c.cellWidth > 0, c.cellHeight > 0 else { return GestureCell(col: 0, row: c.topRow) }
        let col = min(max(0, Int((p.x / c.cellWidth).rounded(.down))), max(c.cols - 1, 0))
        let viewportRow = min(max(0, Int((p.y / c.cellHeight).rounded(.down))), max(c.rows - 1, 0))
        return GestureCell(col: col, row: c.topRow + viewportRow)
    }

    /// A cell's rect in viewport coordinates.
    public static func handleRect(for cell: GestureCell, in c: GestureContext) -> SelectionHandleRect {
        SelectionHandleRect(x: Double(cell.col) * c.cellWidth,
                            y: Double(cell.row - c.topRow) * c.cellHeight,
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
