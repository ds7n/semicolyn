// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Resolve a tap at cell (col,row) to the pane whose rect contains it, or nil
/// (tap on a border cell or outside all rects). Half-open rects: a rect owns
/// cols [x, x+width) and rows [y, y+height).
public func resolveTappedPane(col: Int, row: Int, in model: PaneModel) -> PaneID? {
    for rect in model.rects {
        let colAsDouble = Double(col)
        let rowAsDouble = Double(row)
        if colAsDouble >= rect.x && colAsDouble < rect.x + rect.width &&
           rowAsDouble >= rect.y && rowAsDouble < rect.y + rect.height {
            return rect.pane
        }
    }
    return nil
}
