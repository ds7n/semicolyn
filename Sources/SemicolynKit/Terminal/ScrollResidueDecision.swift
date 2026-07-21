// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Whether to restore the terminal's scroll offset after a drag's axis resolves.
public enum ScrollRestore: Equatable, Sendable {
    /// Keep the live offset (a scroll drag, or not yet decided).
    case keep
    /// Restore the offset captured at drag start (a switch drag: undo the tiny
    /// vertical nudge the native scroll pan made during the pre-lock dead-zone).
    case restore(toX: Double, toY: Double)
}

/// Pure decision for the pre-lock scroll residue. The native `UIScrollView` pan
/// commits on first movement (no dead-zone), so a horizontal drag can nudge the
/// buffer a few points before `DragAxisLock` resolves to `.switchWindow`. When it
/// does, restore the offset captured at `.began`; otherwise keep the live offset.
public struct ScrollResidueDecision: Sendable {
    public static func resolve(axis: DragAxis, savedX: Double, savedY: Double) -> ScrollRestore {
        guard case .switchWindow = axis else { return .keep }
        return .restore(toX: savedX, toY: savedY)
    }
}
