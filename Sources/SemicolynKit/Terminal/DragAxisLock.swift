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

/// Pure axis-lock decision for a live terminal pan. Reuses the dead-zone radius and the
/// switch-dominance ratio (biased toward scroll, so a vertical scroll that drifts
/// sideways does not fling into the wrong window). Window-switch is gated on multi-window
/// tmux; every other drag scrolls.
public struct DragAxisLock: Sendable {
    /// Radius (points) the finger must travel (Euclidean) before the pan locks an axis.
    public static let deadZonePoints: Double = 12
    /// |dx| >= ratio * |dy| for a drag to count as a window switch rather than a scroll.
    public static let switchDominanceRatio: Double = 1.7

    public static func resolve(dx: Double, dy: Double, isMultiWindowTmux: Bool) -> DragAxis {
        guard (dx * dx + dy * dy) >= deadZonePoints * deadZonePoints else { return .pending }
        if isMultiWindowTmux, abs(dx) >= abs(dy) * switchDominanceRatio {
            return .switchWindow(delta: dx > 0 ? -1 : +1)
        }
        return .scroll
    }
}
