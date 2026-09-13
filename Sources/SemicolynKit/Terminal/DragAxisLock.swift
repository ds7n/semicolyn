// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The axis a live terminal pan has locked to, decided ONCE when the finger first
/// leaves the dead-zone (unlike the release-time `GestureClassifier`, which classified
/// on `.ended`). A live finger-drag must know at that moment whether the window should
/// start tracking the finger (`.switchWindow`) or the drag should scroll (`.scroll`);
/// inside the dead-zone it is `.pending` (do not act yet). Fixed for the whole drag so a
/// single gesture never flips between scroll and switch mid-flight.
public enum DragAxis: Equatable, Sendable {
    case pending
    case scroll
    /// Content-follows-finger is gone (KISS): rightward swipe (dx>0) -> previous window (-1),
    /// leftward -> next (+1).
    case switchWindow(delta: Int)
}

/// Pure axis-lock decision for a live terminal pan. Biased hard toward scroll so a
/// vertical scroll that drifts sideways does not fling into the wrong window (device bug
/// 2026-09-13): the lock is deferred until the drag clears the COMMIT radius (larger than
/// the dead-zone, so the decision reflects the drag's settled direction, not its first
/// past-dead-zone twitch), a vertical VETO forces scroll whenever there is clear vertical
/// travel regardless of a momentary horizontal lead, and the dominance ratio is raised.
/// Window-switch is gated on multi-window tmux; every other drag scrolls.
public struct DragAxisLock: Sendable {
    /// Legacy dead-zone radius (points). Kept for reference/back-compat; the lock now
    /// commits at `commitRadiusPoints`. Below the dead-zone a drag was never actioned.
    public static let deadZonePoints: Double = 12
    /// Radius (points) the finger must travel (Euclidean) before the pan COMMITS an axis.
    /// Larger than `deadZonePoints` so the axis is chosen from the drag's settled
    /// direction rather than the noisy first sample past the dead-zone.
    public static let commitRadiusPoints: Double = 24
    /// If |dy| exceeds this many points, the drag scrolls regardless of the horizontal
    /// component: clear vertical intent vetoes a window switch (kills the twitch misfire).
    public static let verticalVetoPoints: Double = 14
    /// |dx| >= ratio * |dy| for a drag to count as a window switch rather than a scroll.
    public static let switchDominanceRatio: Double = 2.0

    public static func resolve(dx: Double, dy: Double, isMultiWindowTmux: Bool) -> DragAxis {
        guard (dx * dx + dy * dy) >= commitRadiusPoints * commitRadiusPoints else { return .pending }
        if abs(dy) > verticalVetoPoints { return .scroll }
        if isMultiWindowTmux, abs(dx) >= abs(dy) * switchDominanceRatio {
            return .switchWindow(delta: dx > 0 ? -1 : +1)
        }
        return .scroll
    }
}
