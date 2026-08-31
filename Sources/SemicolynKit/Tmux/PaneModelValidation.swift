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
