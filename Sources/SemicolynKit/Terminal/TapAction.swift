// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// What a single tap should do, given whether a text selection is currently active.
/// A tap while a selection exists DISMISSES it (standard terminal UX: tap-to-clear,
/// tap-again-to-place); with no selection, a tap places the cursor at the tapped cell.
public enum TapAction: Equatable, Sendable {
    case clearSelection
    case placeCursor
}

/// Pure tap decider. `hasSelection` = the terminal view has an active selection range.
public func tapAction(hasSelection: Bool) -> TapAction {
    hasSelection ? .clearSelection : .placeCursor
}
