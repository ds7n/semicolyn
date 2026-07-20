// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Coalesce a burst of size changes (rotation / keyboard show-hide) into a single
/// resize once input goes quiet for `quiet` seconds (~10Hz). Timestamp-injected.
public struct ResizeDebounce: Equatable, Sendable {
    public static let quiet: TimeInterval = 0.1

    private var pendingCols: Int?
    private var pendingRows: Int?
    private var lastChange: Date?
    /// The last size actually EMITTED by `tick`, so an unchanged size is never re-emitted.
    /// Device 2026-07-20: a spring-back's layout churn re-noted the same grid, and without this
    /// guard `tick` re-emitted it, sending tmux a `refresh-client` that forced a full-screen
    /// repaint (visible flicker on a no-op short drag). nil (both) until the first emit. Two
    /// `Int?`s rather than a tuple so `Equatable` still synthesizes.
    private var lastEmittedCols: Int?
    private var lastEmittedRows: Int?

    public init() {}

    /// Record a requested size; resets the quiet timer.
    public mutating func note(cols: Int, rows: Int, at now: Date) {
        pendingCols = cols; pendingRows = rows; lastChange = now
    }

    /// If a pending size has been quiet for `quiet` AND differs from the last emitted size,
    /// return and clear it; else nil (an unchanged size is suppressed, not re-emitted). The
    /// `quiet` threshold defaults to `Self.quiet` (0.1s); callers pass a LONGER window during a
    /// window-switch settle so the keyboard/keybar grow animation's intermediate sizes coalesce
    /// to a single final emit (device #2 Build 2) instead of resizing tmux mid-animation.
    public mutating func tick(at now: Date, quiet: TimeInterval = ResizeDebounce.quiet) -> (cols: Int, rows: Int)? {
        guard let lc = lastChange, let c = pendingCols, let r = pendingRows else { return nil }
        guard now.timeIntervalSince(lc) >= quiet else { return nil }
        pendingCols = nil; pendingRows = nil; lastChange = nil
        // Suppress a no-op resize: nothing changed since the last emit, so don't nudge tmux.
        if lastEmittedCols == c, lastEmittedRows == r { return nil }
        lastEmittedCols = c; lastEmittedRows = r
        return (c, r)
    }
}
