// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Compute the character window the loupe shows: up to `span` chars centered on the cursor,
/// clamped to the row, plus the caret's index within that window. Pure so the loupe's text
/// layout is unit-tested without rendering. Returns `("", 0)` for an empty row or non-positive
/// span.
public func loupeText(rowChars: [Character], cursorCol: Int, span: Int) -> (text: String, caretIndex: Int) {
    guard span > 0, !rowChars.isEmpty else { return ("", 0) }
    let n = rowChars.count
    var start = cursorCol - span / 2
    if start < 0 { start = 0 }
    if start + span > n { start = max(0, n - span) }
    let end = min(n, start + span)
    let window = Array(rowChars[start..<end])
    let caret = max(0, min(cursorCol - start, window.count))
    return (String(window), caret)
}
