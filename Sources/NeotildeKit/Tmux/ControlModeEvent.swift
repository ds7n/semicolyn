// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum CommandOutcome: Equatable, Sendable {
    case ok([String])
    case error([String])
}

public enum ControlModeEvent: Equatable, Sendable {
    case output(pane: PaneID, data: [UInt8])
    case commandResult(number: Int, outcome: CommandOutcome)
    case windowAdd(WindowID)
    case windowClose(WindowID)
    case windowRenamed(WindowID, name: String)
    case windowPaneChanged(WindowID, active: PaneID)
    case layoutChange(WindowID, layout: PaneLayout, visible: PaneLayout, flags: String)
    case sessionChanged(SessionID, name: String)
    case sessionWindowChanged(SessionID, active: WindowID)
    case sessionsChanged
    case exit(reason: String?)
    case unknown(verb: String, raw: String)
    case malformed(raw: String, reason: String)
}
