// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// What a single tap should do, given whether a text selection is currently active and
/// whether the tap landed on it. A tap INSIDE an active selection re-presents the copy menu
/// (does NOT clear); a tap OUTSIDE it dismisses the selection; with no selection, a tap
/// places the cursor at the tapped cell.
public enum TapAction: Equatable, Sendable {
    case clearSelection
    case placeCursor
    /// Tap landed ON an active selection: re-present the copy menu (do NOT clear).
    case reSummonMenu
}

/// Pure tap decider. With a selection: tap INSIDE it re-summons the menu, tap OUTSIDE clears.
/// With no selection: place the cursor at the tapped cell.
public func tapAction(hasSelection: Bool, tapInsideSelection: Bool) -> TapAction {
    guard hasSelection else { return .placeCursor }
    return tapInsideSelection ? .reSummonMenu : .clearSelection
}
