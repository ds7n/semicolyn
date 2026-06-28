// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// One tmux window: a named pane-geometry tree with an active pane.
public struct TmuxWindow: Equatable, Sendable {
    public let id: WindowID
    public var name: String
    public var layout: PaneLayout?          // full window layout (nil until first %layout-change)
    public var visibleLayout: PaneLayout?   // what to render (differs when a pane is zoomed)
    public var activePane: PaneID?

    public init(id: WindowID, name: String = "", layout: PaneLayout? = nil,
                visibleLayout: PaneLayout? = nil, activePane: PaneID? = nil) {
        self.id = id
        self.name = name
        self.layout = layout
        self.visibleLayout = visibleLayout
        self.activePane = activePane
    }
}

/// Structural state of the single tmux session Semicolyn is attached to. Mutated only
/// by applying control-mode events; terminal content lives elsewhere (SwiftTerm).
public struct TmuxSessionState: Equatable, Sendable {
    public private(set) var sessionID: SessionID?
    public private(set) var sessionName: String?
    public private(set) var windows: [TmuxWindow]
    public private(set) var activeWindow: WindowID?
    public private(set) var ended: Bool
    public private(set) var exitReason: String?

    public init() {
        sessionID = nil
        sessionName = nil
        windows = []
        activeWindow = nil
        ended = false
        exitReason = nil
    }

    /// The window with `id`, or nil if absent.
    public func window(_ id: WindowID) -> TmuxWindow? { windows.first { $0.id == id } }

    private func index(of id: WindowID) -> Int? { windows.firstIndex { $0.id == id } }

    /// Apply one control-mode event, updating structural state. Non-structural
    /// events and events for unknown windows are ignored.
    public mutating func apply(_ event: ControlModeEvent) {
        switch event {
        case let .windowAdd(w):
            if index(of: w) == nil { windows.append(TmuxWindow(id: w)) }
        case let .windowClose(w):
            windows.removeAll { $0.id == w }
            if activeWindow == w { activeWindow = nil }
        case let .windowRenamed(w, name):
            if let i = index(of: w) { windows[i].name = name }
        case let .windowPaneChanged(w, pane):
            if let i = index(of: w) { windows[i].activePane = pane }
        case let .layoutChange(w, layout, visible, _):
            if let i = index(of: w) {
                windows[i].layout = layout
                windows[i].visibleLayout = visible
            }
        case let .sessionChanged(s, name):
            sessionID = s
            sessionName = name
        case let .sessionWindowChanged(s, w):
            if sessionID == nil || sessionID == s { activeWindow = w }
        case let .exit(reason):
            ended = true
            exitReason = reason
        case .sessionsChanged, .output, .commandResult, .unknown, .malformed:
            break
        }
    }
}
