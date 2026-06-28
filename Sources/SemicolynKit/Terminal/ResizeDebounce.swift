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

    public init() {}

    /// Record a requested size; resets the quiet timer.
    public mutating func note(cols: Int, rows: Int, at now: Date) {
        pendingCols = cols; pendingRows = rows; lastChange = now
    }

    /// If a pending size has been quiet for `quiet`, return and clear it; else nil.
    public mutating func tick(at now: Date) -> (cols: Int, rows: Int)? {
        guard let lc = lastChange, let c = pendingCols, let r = pendingRows else { return nil }
        guard now.timeIntervalSince(lc) >= Self.quiet else { return nil }
        pendingCols = nil; pendingRows = nil; lastChange = nil
        return (c, r)
    }
}
