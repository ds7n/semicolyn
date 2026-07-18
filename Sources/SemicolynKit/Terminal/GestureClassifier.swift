// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Shared terminal-pan tuning constants. The release-time `classify` classifier this
/// file once held is superseded by `DragAxisLock` (at-dead-zone lock for the live
/// finger-drag transition). These constants are kept as the single source both the live
/// lock and any future gesture code read from.
public enum GestureTuning {
    /// Radius (points) the finger must travel before a pan is classified.
    public static let deadZonePoints: Double = 12
    /// |dx| >= ratio * |dy| for a horizontal drag to count as a window switch.
    public static let switchDominanceRatio: Double = 1.7
}
