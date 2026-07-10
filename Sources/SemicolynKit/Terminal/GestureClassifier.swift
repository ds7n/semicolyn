// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The action a terminal single-finger pan resolves to.
public enum PanGesture: Equatable, Sendable {
    /// Movement is still within the dead-zone — do not act yet.
    case none
    /// Scroll the scrollback (vertical drag, or horizontal fall-through).
    case scrollVertical
    /// Switch tmux window by `delta` (+1 next / −1 previous). Only produced for a
    /// horizontal-dominant drag in multi-window tmux.
    case switchWindow(delta: Int)
}

/// Pure axis-lock classifier for a terminal pan. Given the cumulative translation
/// `(dx, dy)` in points (dx>0 = rightward, dy>0 = downward) and whether the terminal
/// is a multi-window tmux session, decides scroll vs. window-switch. Vertical drags
/// always scroll; horizontal drags switch windows only under multi-window tmux and
/// otherwise fall through to scroll. Movement inside the dead-zone yields `.none`.
public struct GestureClassifier: Sendable {
    /// Radius (points) the finger must travel before the pan is classified. Tuned to
    /// avoid classifying a tap-with-jitter; feel-tuned on device.
    public static let deadZonePoints: Double = 12

    public static func classify(dx: Double, dy: Double, isMultiWindowTmux: Bool) -> PanGesture {
        // Dead-zone: require the finger to travel past the radius (Euclidean) first.
        guard (dx * dx + dy * dy) >= deadZonePoints * deadZonePoints else { return .none }

        // Dominant axis wins.
        if abs(dy) >= abs(dx) {
            return .scrollVertical
        }
        // Horizontal-dominant: switch windows only in multi-window tmux, else scroll.
        guard isMultiWindowTmux else { return .scrollVertical }
        return .switchWindow(delta: dx > 0 ? +1 : -1)
    }
}
