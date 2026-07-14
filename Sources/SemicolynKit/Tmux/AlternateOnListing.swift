// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Parses the reply to ``TmuxCommand/queryAlternateOn()``: each line is
/// `%<id> <0|1>` (pane id + `#{alternate_on}`). Returns one entry per WELL-FORMED
/// line, preserving order; malformed lines (missing `%`, non-numeric id, flag that
/// is neither `0` nor `1`) are skipped rather than fatal, because a control-mode
/// reply is untrusted external input. `1` = alternate screen (`true`), `0` = normal.
public func parseAlternateOnListing(_ lines: [String]) -> [(pane: PaneID, isAlt: Bool)] {
    var result: [(pane: PaneID, isAlt: Bool)] = []
    for line in lines {
        let parts = line.split(separator: " ")
        guard parts.count == 2 else { continue }
        guard parts[0].first == "%",
              let raw = UInt32(parts[0].dropFirst()) else { continue }
        let isAlt: Bool
        switch parts[1] {
        case "1": isAlt = true
        case "0": isAlt = false
        default: continue
        }
        result.append((pane: PaneID(raw: raw), isAlt: isAlt))
    }
    return result
}
