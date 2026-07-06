// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// One row of `TmuxCommand.listWindowsForLayout()` output, parsed.
public struct ParsedWindow: Equatable, Sendable {
    public let id: WindowID
    public let active: Bool
    public let layout: PaneLayout
    public init(id: WindowID, active: Bool, layout: PaneLayout) {
        self.id = id; self.active = active; self.layout = layout
    }
}

/// Parse `list-windows -F "#{window_id} #{window_active} #{window_layout}"` output:
/// each row is `@<n> <0|1> <layout>`. Best-effort — a row with a bad window token,
/// a non-`0|1` active flag, or an unparseable layout is skipped (never throws).
/// Mirrors ``parsePaneCommandListing(_:)``.
public func parseWindowListing(_ lines: [String]) -> [ParsedWindow] {
    var result: [ParsedWindow] = []
    for line in lines {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let id = WindowID(token: parts[0]),
              parts[1] == "0" || parts[1] == "1",
              let layout = PaneLayout.parse(parts[2]) else { continue }
        result.append(ParsedWindow(id: id, active: parts[1] == "1", layout: layout))
    }
    return result
}

/// Turn parsed windows into the control-mode events that populate
/// ``TmuxSessionState`` — a `windowAdd` + `layoutChange` per window, and a single
/// `sessionWindowChanged` to the active window (last active wins if several are
/// flagged). Feeding these through `state.apply(_:)` keeps all state mutation in
/// the one canonical path.
public func windowListingEvents(_ windows: [ParsedWindow], sessionID: SessionID) -> [ControlModeEvent] {
    var events: [ControlModeEvent] = []
    var active: WindowID?
    for w in windows {
        events.append(.windowAdd(w.id))
        events.append(.layoutChange(w.id, layout: w.layout, visible: w.layout, flags: ""))
        if w.active { active = w.id }
    }
    if let active { events.append(.sessionWindowChanged(sessionID, active: active)) }
    return events
}
