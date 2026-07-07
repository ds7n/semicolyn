// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// The arrow-key movement to walk the terminal cursor from its current cell to a
/// tapped cell. Same row → pure horizontal (col delta as left/right). Different row
/// → best-effort: the row delta as up/down runs, THEN the col delta as left/right
/// runs (cross-line taps can misfire on wrapped lines / multi-line prompts / vim —
/// documented as best-effort; the reliable case is same-line editing). Returns `[]`
/// when the tap lands on the current cell. Delegates the signed-delta → runs step to
/// the existing `arrowEvents(cols:rows:)` so tap and drag share one arrow encoder.
public func cursorTapArrows(fromCol: Int, fromRow: Int, toCol: Int, toRow: Int) -> [ArrowRun] {
    let colDelta = toCol - fromCol
    let rowDelta = toRow - fromRow
    if rowDelta == 0 {
        return arrowEvents(cols: colDelta, rows: 0)
    }
    // Row first, then column (best-effort cross-line).
    return arrowEvents(cols: 0, rows: rowDelta) + arrowEvents(cols: colDelta, rows: 0)
}
