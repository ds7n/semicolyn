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

/// Character class for sub-word selection boundaries.
public enum CharClass: Sendable {
    case word
    case space
    case punct
}

/// The punctuation set that breaks a sub-word selection (double-tap), matching iOS/desktop
/// double-click. Single source of truth: the App classifier and any docs read this.
public let selectionPunctuation: Set<Character> = [
    ".", "-", "/", "_", ",", ":", ";", "=", "@", "~",
    "(", ")", "[", "]", "{", "}", "<", ">",
    "|", "&", "!", "?", "*", "\"", "'"
]

/// Sub-word bounds on a single terminal row: from the tapped column, extend left and right
/// while the character CLASS stays equal to the tapped cell's class. `classOf(i)` returns the
/// class of column `i` and MUST return `.space` for out-of-range `i` (so the run stops at the
/// row edges). `col` is clamped into `0..<cols`. A tap on a `.space` cell yields the degenerate
/// `(col, col)`. Returns the inclusive `(start, end)` column range.
///
/// Pure and view-free (Linux-testable); the App supplies `classOf` backed by `getCharData`.
public func subWordBounds(cols: Int, col: Int,
                          classOf: (Int) -> CharClass) -> (start: Int, end: Int) {
    let maxCol = max(cols - 1, 0)
    let clamped = min(max(col, 0), maxCol)
    let tapped = classOf(clamped)
    if tapped == .space { return (clamped, clamped) }

    var lo = clamped
    var hi = clamped
    while lo > 0, classOf(lo - 1) == tapped { lo -= 1 }
    while hi < maxCol, classOf(hi + 1) == tapped { hi += 1 }
    return (lo, hi)
}
