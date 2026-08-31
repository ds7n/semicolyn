// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Incremental, pure tracker of a tmux window's pane layout (cell units), driven
/// forward by the commands WE issue (split/zoom/select) so the renderer never has
/// to wait on a round-trip `%layout-change` for its own actions. The recovery-path
/// init rebuilds the same shape from a parsed `PaneLayout` (e.g. on attach, or when
/// a spontaneous `%layout-change` arrives that we did not predict).
public struct PaneModel: Equatable, Sendable {
    public private(set) var rects: [PaneRect]        // current panes in the active window (cell units)
    public private(set) var activePane: PaneID
    public private(set) var activeWindow: WindowID
    public let gridCols: Int
    public let gridRows: Int

    /// Pre-zoom rects, stashed on `applyZoomToggle` so a second toggle restores them.
    /// `nil` when not zoomed.
    private var stashedRects: [PaneRect]?
    private var zoomed: Bool { stashedRects != nil }

    /// Start from a known single-pane window filling the grid.
    public init(window: WindowID, pane: PaneID, gridCols: Int, gridRows: Int) {
        self.activeWindow = window
        self.activePane = pane
        self.gridCols = gridCols
        self.gridRows = gridRows
        self.rects = [PaneRect(pane: pane, x: 0, y: 0, width: Double(gridCols), height: Double(gridRows))]
        self.stashedRects = nil
    }

    /// Rebuild the model's rects from a parsed tmux layout (recovery path).
    public init(window: WindowID, activePane: PaneID, layout: PaneLayout, gridCols: Int, gridRows: Int) {
        self.activeWindow = window
        self.activePane = activePane
        self.gridCols = gridCols
        self.gridRows = gridRows
        self.rects = paneRects(in: layout, cellWidth: 1, cellHeight: 1)
        self.stashedRects = nil
    }

    // MARK: - Deterministic mutators from a command WE issued

    /// `resize-pane -Z`: the active pane fills the grid; a second toggle restores
    /// the pre-zoom rects. No-op if there is only one pane (nothing to zoom into).
    public mutating func applyZoomToggle() {
        if let stashed = stashedRects {
            rects = stashed
            stashedRects = nil
            return
        }
        guard rects.count > 1, let active = rects.first(where: { $0.pane == activePane }) else { return }
        stashedRects = rects
        rects = [PaneRect(pane: active.pane, x: 0, y: 0, width: Double(gridCols), height: Double(gridRows))]
    }

    /// `select-pane -t id`: only the active-pane pointer changes.
    public mutating func applySelectPane(_ id: PaneID) {
        activePane = id
    }

    /// `select-window -t id`: switching windows replaces the whole tracked layout,
    /// so this is a full rebuild from the target window's known layout, same as the
    /// recovery-path init. Any pending zoom stash is discarded (it belonged to the
    /// window being left).
    public mutating func applySelectWindow(_ id: WindowID, layout: PaneLayout, activePane: PaneID) {
        activeWindow = id
        self.activePane = activePane
        rects = paneRects(in: layout, cellWidth: 1, cellHeight: 1)
        stashedRects = nil
    }

    /// `split-window` on the active pane. Splits the active pane's rect in half
    /// along `dir`, inserting a 1-cell border between the two resulting rects.
    ///
    /// PINNED SPLIT-ROUNDING RULE (unit-test-pinned; device-verify against real
    /// tmux in the Phase 1 device pass, adjust here if tmux rounds the other way):
    /// the EXISTING pane keeps the left/top half, rounded UP (ceil); the NEW pane
    /// takes the right/bottom half, rounded DOWN (floor); one cell between them is
    /// reserved for tmux's border. E.g. splitting an 80-col pane `.sideBySide`:
    /// left (existing) keeps cols 0..39 (width 40), border at col 40, right (new)
    /// gets cols 41..79 (width 39): 40 + 1 + 39 == 80.
    public mutating func applySplit(_ dir: SplitDirection, newPane: PaneID) {
        guard let index = rects.firstIndex(where: { $0.pane == activePane }) else { return }
        let active = rects[index]

        switch dir {
        case .sideBySide:
            let usable = active.width - 1   // 1 cell reserved for the border
            let existingWidth = (usable / 2).rounded(.up)
            let newWidth = usable - existingWidth
            let existingRect = PaneRect(pane: active.pane, x: active.x, y: active.y,
                                         width: existingWidth, height: active.height)
            let newRect = PaneRect(pane: newPane, x: active.x + existingWidth + 1, y: active.y,
                                    width: newWidth, height: active.height)
            rects[index] = existingRect
            rects.insert(newRect, at: index + 1)
        case .stacked:
            let usable = active.height - 1  // 1 cell reserved for the border
            let existingHeight = (usable / 2).rounded(.up)
            let newHeight = usable - existingHeight
            let existingRect = PaneRect(pane: active.pane, x: active.x, y: active.y,
                                         width: active.width, height: existingHeight)
            let newRect = PaneRect(pane: newPane, x: active.x, y: active.y + existingHeight + 1,
                                    width: active.width, height: newHeight)
            rects[index] = existingRect
            rects.insert(newRect, at: index + 1)
        }
        stashedRects = nil   // a split invalidates any stale pre-zoom stash
    }

    // MARK: - Predicted borders

    /// Border cells the current rects imply (for validateBorders): the interior
    /// edges between adjacent rects. Cell units. Derived purely from rect
    /// adjacency (not tracked incrementally): for each pair of rects, a shared
    /// vertical edge (A's right edge abuts B's left edge) contributes the column
    /// between them across their overlapping row span; a shared horizontal edge
    /// (A's bottom edge abuts B's top edge) contributes the row between them
    /// across their overlapping column span. One pane -> no borders.
    public var predictedBorders: [PredictedBorder] {
        guard rects.count > 1 else { return [] }
        var borders: [PredictedBorder] = []
        for i in rects.indices {
            for j in rects.indices where j != i {
                let a = rects[i]
                let b = rects[j]

                // Vertical border: a's right edge abuts b's left edge, one cell apart.
                if b.x - (a.x + a.width) == 1 {
                    let rowStart = max(a.y, b.y)
                    let rowEnd = min(a.y + a.height, b.y + b.height)
                    if rowStart < rowEnd {
                        let col = Int(a.x + a.width)
                        let cells = stride(from: Int(rowStart), to: Int(rowEnd), by: 1).map { (col: col, row: $0) }
                        borders.append(PredictedBorder(cells: cells))
                    }
                }

                // Horizontal border: a's bottom edge abuts b's top edge, one cell apart.
                if b.y - (a.y + a.height) == 1 {
                    let colStart = max(a.x, b.x)
                    let colEnd = min(a.x + a.width, b.x + b.width)
                    if colStart < colEnd {
                        let row = Int(a.y + a.height)
                        let cells = stride(from: Int(colStart), to: Int(colEnd), by: 1).map { (col: $0, row: row) }
                        borders.append(PredictedBorder(cells: cells))
                    }
                }
            }
        }
        return borders
    }
}
