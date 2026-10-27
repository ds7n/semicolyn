// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

// Commit-time echo check: at Enter, the rendered text just before the cursor must
// end with what was typed, or the line is not learned. A password typed at a
// non-echoing (or masking) prompt never appears on screen, so it fails here on
// every transport (SSH, plain tmux, Mosh, ET), with no per-keystroke settle timer.

/// The commit-row check for a line split by Tab completions. After a Tab the
/// tracker's line restarts at the post-Tab text, so each typed segment is checked
/// against the row read when it ended (at its Tab, and at Enter), and the line is
/// confirmed only when every segment with text is. A row read at Enter alone could
/// confirm at most the last segment.
public struct SegmentedRowVerdict: Equatable, Sendable {
    private var confirmed: Bool?

    public init() {}

    /// The combined verdict: nil when no segment had text, else whether all were echoed.
    public var verdict: Bool? { confirmed }

    /// Fold one segment: `typed` is the text typed since the line start or the last
    /// Tab, `renderedBeforeCursor` the row read as it ended (nil when unreadable,
    /// which fails the line). A segment with no text is ignored.
    public mutating func noteSegment(typed: String, renderedBeforeCursor: String?) {
        guard !trimmingTrailingSpaces(typed).isEmpty else { return }
        let echoed = renderedBeforeCursor.map {
            rowConfirmsEcho(typedLine: typed, renderedBeforeCursor: $0)
        } ?? false
        confirmed = (confirmed ?? true) && echoed
    }

    /// Fail the line: a segment could not be checked (its text and the Tab arrived
    /// in one chunk, so the row was read before the text reached it).
    public mutating func noteUnverifiable() { confirmed = false }

    public mutating func reset() { confirmed = nil }
}

/// True when `renderedBeforeCursor` (the screen text immediately before the
/// cursor at commit) shows `typedLine` echoed.
///
/// Trailing spaces are trimmed from both. An empty or all-space `typedLine` is
/// never confirmed. The match is an exact, case-sensitive suffix match; typed
/// lines of at least 4 characters also confirm when only their last character is
/// missing (one byte still in flight at commit).
public func rowConfirmsEcho(typedLine: String, renderedBeforeCursor: String) -> Bool {
    let typed = trimmingTrailingSpaces(typedLine)
    guard !typed.isEmpty else { return false }
    let rendered = trimmingTrailingSpaces(renderedBeforeCursor)
    if rendered.hasSuffix(typed) { return true }
    guard typed.count >= 4 else { return false }
    return rendered.hasSuffix(String(typed.dropLast()))
}

/// The rendered text before the cursor: the cursor row from column 0 up to (not
/// including) the cursor. Earlier rows are prepended (oldest first, while fewer
/// than `maxChars` characters are gathered) ONLY for a real wrap: the cursor is
/// past column 0, the cursor-row prefix is not all blank, and each prepended row
/// is full (its last cell is non-blank). Otherwise only the cursor row is read,
/// so text left on an earlier row (a printed token above a silent `read -s`) can
/// never stand in for an echo. Blank cells read as spaces.
///
/// Returns nil (fail-safe: no verdict) when the cursor or `columns` is
/// unreadable, the cursor lies outside the grid, or any needed cell is unreadable.
public func renderedTextBeforeCursor(oracle: EchoOracle, maxChars: Int) -> String? {
    guard let cursor = oracle.cursor(), let columns = oracle.columns else { return nil }
    guard columns > 0, cursor.row >= 0, cursor.col >= 0, cursor.col <= columns else { return nil }
    guard var text = readRow(oracle: oracle, row: cursor.row, upTo: cursor.col) else { return nil }
    // No wrap evidence on the cursor row (an empty prefix at col 0, or an
    // all-blank one): never look above it.
    guard text.unicodeScalars.contains(where: { $0 != " " }) else { return text }
    var row = cursor.row - 1
    while text.count < maxChars, row >= 0 {
        guard let earlier = readRow(oracle: oracle, row: row, upTo: columns) else { return nil }
        // A row ending in a blank did not wrap into the next one: stop the chain.
        guard earlier.unicodeScalars.last != " " else { break }
        text = earlier + text
        row -= 1
    }
    return text
}

/// Columns `0..<end` of `row` as text (blank cells as spaces), or nil if any
/// cell is unreadable.
private func readRow(oracle: EchoOracle, row: Int, upTo end: Int) -> String? {
    var scalars = String.UnicodeScalarView()
    for col in 0..<end {
        guard let cell = oracle.cell(row: row, col: col) else { return nil }
        scalars.append(cell.scalar ?? " ")
    }
    return String(scalars)
}

/// Drop trailing ASCII spaces.
private func trimmingTrailingSpaces(_ s: String) -> String {
    var out = s
    while out.last == " " { out.removeLast() }
    return out
}
