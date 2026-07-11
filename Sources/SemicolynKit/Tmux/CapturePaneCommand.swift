// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Build the tmux control-mode `capture-pane` command that seeds a pane's scrollback
/// history (spec: tmux -CC native scrollback). Flags: `-p` print to stdout, `-e`
/// preserve escape sequences (so colors/attributes survive), `-S -<N>` start N lines
/// back into history. **No `-J`** — keep tmux's real line wrapping so seeded history
/// matches the live buffer width. **No `-a`** — alt-screen history is out of scope.
/// `N == Int.max` uses tmux's whole-history shorthand `-S -`. Returns `nil` when
/// `lines <= 0` (seeding disabled). No trailing newline (the transport appends one).
public func capturePaneCommand(paneID: PaneID, lines: Int) -> String? {
    guard lines > 0 else { return nil }
    let start = (lines == Int.max) ? "-" : "-\(lines)"
    return "capture-pane -p -e -S \(start) -t %\(paneID.raw)"
}

/// Reconstruct feedable history bytes from a `capture-pane` control-block body. tmux
/// returns one screen row per line and pads the bottom of the pane with trailing blank
/// lines; those are screen padding, not scrollback, so they are trimmed. Remaining lines
/// are joined with "\n" (with a trailing "\n" if any content remains) and UTF-8 encoded.
/// Body lines carry literal escape sequences (`capture-pane -e`) which pass through
/// unchanged. Empty input → empty bytes.
public func reconstructHistory(fromLines lines: [String]) -> [UInt8] {
    var end = lines.count
    while end > 0, lines[end - 1].allSatisfy(\.isWhitespace) { end -= 1 }
    guard end > 0 else { return [] }
    return Array((lines[0..<end].joined(separator: "\n") + "\n").utf8)
}
