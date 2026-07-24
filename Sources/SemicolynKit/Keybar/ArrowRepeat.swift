// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// iOS-style key-repeat timing for a held d-pad swipe, as a function of how long the
/// swipe has been held (measured from the first fire at the 16pt crossing). Distance
/// selects direction (see `dominantArrow`); held-time drives the rate. Pure + testable,
/// mirroring the `ResizeDebounce` tested-seam pattern (no UIKit/SwiftUI).
public enum ArrowRepeat {
    /// After the first fire, wait this long before repeating begins.
    public static let initialDelay: TimeInterval  = 0.40
    /// The first repeat interval once repeating begins (slow).
    public static let startInterval: TimeInterval = 0.25
    /// The fastest repeat interval (clamp floor).
    public static let minInterval: TimeInterval   = 0.06
    /// Held-time over which the interval eases from `startInterval` down to `minInterval`.
    public static let rampDuration: TimeInterval  = 1.20

    /// The repeat interval for a swipe held `heldFor` seconds, or nil while still inside
    /// the initial-delay window (no repeat yet). Linear ease from `startInterval` down to
    /// `minInterval` across `rampDuration`, clamped at `minInterval` past the ramp.
    public static func interval(heldFor: TimeInterval) -> TimeInterval? {
        guard heldFor >= initialDelay else { return nil }
        let intoRamp = heldFor - initialDelay
        guard intoRamp < rampDuration else { return minInterval }
        let progress = intoRamp / rampDuration               // 0..<1 across the ramp
        return startInterval + (minInterval - startInterval) * progress
    }
}

/// The dominant-axis arrow for a drag translation. Ties (|dx| == |dy|, including 0,0)
/// resolve to the horizontal axis (`.right` when `dx >= 0`, else `.left`). Extracted from
/// `PadView` so direction selection is unit-tested.
public func dominantArrow(dx: Double, dy: Double) -> ArrowDirection {
    if abs(dx) >= abs(dy) {
        return dx >= 0 ? .right : .left
    }
    return dy >= 0 ? .down : .up
}
