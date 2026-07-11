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
