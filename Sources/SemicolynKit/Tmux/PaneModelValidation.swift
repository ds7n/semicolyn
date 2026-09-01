// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Unicode "Box Drawing" block. tmux draws pane borders with these; the on-tap
/// drift check confirms the model's predicted border cells actually hold one.
public func isBoxDrawing(_ scalar: Unicode.Scalar) -> Bool {
    (0x2500...0x257F).contains(scalar.value)
}

/// A border segment the pane model predicts: cells that should render box-drawing.
public struct PredictedBorder: Equatable, Sendable {
    public let cells: [Cell]
    public struct Cell: Equatable, Sendable { public let col: Int; public let row: Int
        public init(col: Int, row: Int) { self.col = col; self.row = row } }
    public init(cells: [(col: Int, row: Int)]) { self.cells = cells.map { Cell(col: $0.col, row: $0.row) } }
}

public enum DriftVerdict: Equatable, Sendable { case valid; case drift }

/// Targeted drift check: valid iff EVERY predicted border cell holds a box-drawing
/// scalar. Only predicted cells are inspected, so a stray box glyph an app draws
/// elsewhere cannot affect the verdict. A nil (out-of-range) cell is drift.
public func validateBorders(_ borders: [PredictedBorder],
                            cellAt: (_ col: Int, _ row: Int) -> Unicode.Scalar?) -> DriftVerdict {
    for border in borders {
        for c in border.cells {
            guard let s = cellAt(c.col, c.row), isBoxDrawing(s) else { return .drift }
        }
    }
    return .valid
}

/// Detect a pane border the model does NOT predict: a contiguous full-span run
/// of box-drawing in the INTERIOR of one of the model's rects (a column running
/// the rect's full height, or a row running its full width), which implies a
/// split tmux made outside our tracking. Targeted at rect interiors, NOT a blind
/// whole-screen scan, so an app's border glyph at a rect EDGE (a real predicted
/// border) is ignored. Over-eager by design (an app drawing a full-height line
/// inside its pane trips it), which is safe: it only triggers an authoritative
/// recovery re-query that self-corrects. `cellAt` returns the rendered scalar at
/// (col,row) or nil out of range.
public func detectUnpredictedBorder(rects: [PaneRect],
                                    gridCols: Int, gridRows: Int,
                                    cellAt: (_ col: Int, _ row: Int) -> Unicode.Scalar?) -> DriftVerdict {
    for rect in rects {
        let x = Int(rect.x), y = Int(rect.y)
        let width = Int(rect.width), height = Int(rect.height)

        // Full-height interior column: an unpredicted vertical split.
        if width > 2 {
            for c in (x + 1)..<(x + width - 1) {
                let allBoxDrawing = (y..<(y + height)).allSatisfy { r in
                    guard let s = cellAt(c, r) else { return false }
                    return isBoxDrawing(s)
                }
                if allBoxDrawing { return .drift }
            }
        }

        // Full-width interior row: an unpredicted horizontal split.
        if height > 2 {
            for r in (y + 1)..<(y + height - 1) {
                let allBoxDrawing = (x..<(x + width)).allSatisfy { c in
                    guard let s = cellAt(c, r) else { return false }
                    return isBoxDrawing(s)
                }
                if allBoxDrawing { return .drift }
            }
        }
    }
    return .valid
}
