// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// The command line as typed, with a cursor, so a line edited in place (Left,
/// Right, Home, End, Delete, Ctrl-A/E/K/U/W) can still be learned at Enter. It
/// mirrors the common emacs-mode bindings of bash and zsh; where a shell differs
/// (zsh's Ctrl-U kills the whole line, its Ctrl-W stops at `/`), the result no
/// longer matches the screen and the commit check rejects the line.
///
/// It only ever holds bytes the user typed. Anything it cannot follow (a Tab
/// completion, a paste, history recall, Meta keys, other controls) makes it
/// unusable until the line ends, so text it never saw is never learned from it.
struct LineEditBuffer: Equatable, Sendable {
    private var scalars: [Unicode.Scalar] = []
    private var cursor = 0
    /// True once the cursor moved or text was killed since the line started.
    private(set) var edited = false
    /// False once something the buffer cannot follow happened on this line.
    private(set) var usable = true
    /// True when the first character typed on the line was a space (L4a opt-out).
    private(set) var typedWithLeadingSpace = false

    /// The text left of the cursor.
    var beforeCursor: String { Self.string(scalars[..<cursor]) }
    /// The text from the cursor to the end of the line.
    var afterCursor: String { Self.string(scalars[cursor...]) }
    /// The whole line.
    var text: String { Self.string(scalars[...]) }

    mutating func insert(_ scalar: Unicode.Scalar) {
        if scalars.isEmpty && !edited && scalar == " " { typedWithLeadingSpace = true }
        scalars.insert(scalar, at: cursor)
        cursor += 1
    }

    /// Backspace: delete the character left of the cursor.
    mutating func deleteBackward() {
        guard cursor > 0 else { return }
        cursor -= 1
        scalars.remove(at: cursor)
    }

    /// Delete key: delete the character under the cursor.
    mutating func deleteForward() {
        edited = true
        guard cursor < scalars.count else { return }
        scalars.remove(at: cursor)
    }

    mutating func moveLeft() { edited = true; cursor = max(0, cursor - 1) }
    mutating func moveRight() { edited = true; cursor = min(scalars.count, cursor + 1) }
    mutating func moveToStart() { edited = true; cursor = 0 }
    mutating func moveToEnd() { edited = true; cursor = scalars.count }

    /// Ctrl-K: kill from the cursor to the end of the line.
    mutating func killToEnd() {
        edited = true
        scalars.removeSubrange(cursor...)
    }

    /// Ctrl-U (bash `unix-line-discard`): kill from the line start to the cursor.
    mutating func killToStart() {
        edited = true
        scalars.removeSubrange(..<cursor)
        cursor = 0
    }

    /// Ctrl-W (bash `unix-word-rubout`): kill the spaces, then the non-spaces, left
    /// of the cursor.
    mutating func killWordBackward() {
        edited = true
        var start = cursor
        while start > 0, scalars[start - 1] == " " { start -= 1 }
        while start > 0, scalars[start - 1] != " " { start -= 1 }
        scalars.removeSubrange(start..<cursor)
        cursor = start
    }

    /// Stop following this line: what is on screen is no longer what was typed here.
    mutating func markUnusable() { usable = false }

    /// Start a new line.
    mutating func clear() { self = LineEditBuffer() }

    private static func string(_ slice: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: slice)
        return String(view)
    }
}
