// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Word bounds on a single terminal row: from a tapped column, walk left and
/// right over contiguous word cells. `isWordChar(i)` reports whether column `i`
/// holds a word glyph (non-space); it must return false for out-of-range `i`.
/// `col` is clamped into `0..<cols` first. Returns the inclusive `(start, end)`
/// column range. A tap on a non-word cell yields a degenerate `(col, col)`.
///
/// Pure and view-free so it is Linux-testable; the App layer supplies
/// `isWordChar` backed by SwiftTerm's `getCharData`.
public func wordBounds(cols: Int, col: Int,
                       isWordChar: (Int) -> Bool) -> (start: Int, end: Int) {
    let maxCol = max(cols - 1, 0)
    let clamped = min(max(col, 0), maxCol)

    // If the tapped cell is not a word character, return degenerate range.
    guard isWordChar(clamped) else { return (clamped, clamped) }

    var lo = clamped
    var hi = clamped
    while lo > 0, isWordChar(lo - 1) { lo -= 1 }
    while hi < maxCol, isWordChar(hi + 1) { hi += 1 }
    return (lo, hi)
}
