// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// The terminal's current touch-interaction mode. Held as tracked state and
/// updated on `bufferActivated` / `mouseModeChanged` delegate events; the gesture
/// layer routes drag / tap / selection per mode. One unambiguous drag-owner each.
public enum InteractionMode: Equatable, Sendable {
    /// Normal screen, no mouse reporting — SwiftTerm's native scroll owns the drag.
    case localScroll
    /// Alternate screen (vim/htop/Claude) — we translate drag→arrows, tap→mouse.
    case appOwnsInput
    /// Normal screen, app enabled mouse reporting — forward events to the app.
    case mouseReporting
}

/// Resolve the interaction mode from terminal state. Alt-screen takes precedence
/// over mouse-mode: an alt-screen app with mouse on resolves to `.appOwnsInput`
/// (drag→arrows and tap→mouse both apply there).
public func resolveMode(isAltScreen: Bool, mouseReporting: Bool) -> InteractionMode {
    if isAltScreen { return .appOwnsInput }
    if mouseReporting { return .mouseReporting }
    return .localScroll
}
