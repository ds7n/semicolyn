// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Parse the result lines of `TmuxCommand.listPaneCommands()` — each
/// `%<id> <pane_current_command>` — into `(PaneID, command)` pairs. Lines with no
/// valid `%N` token or no command are skipped (best-effort; never throws).
public func parsePaneCommandListing(_ lines: [String]) -> [(PaneID, String)] {
    var result: [(PaneID, String)] = []
    for line in lines {
        guard let spaceIdx = line.firstIndex(of: " ") else { continue }
        let token = line[line.startIndex..<spaceIdx]
        guard let pane = PaneID(token: token) else { continue }
        let command = String(line[line.index(after: spaceIdx)...])
        guard !command.isEmpty else { continue }
        result.append((pane, command))
    }
    return result
}
