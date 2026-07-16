// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The action a terminal single-finger pan resolves to.
public enum PanGesture: Equatable, Sendable {
    /// Movement is still within the dead-zone — do not act yet.
    case none
    /// Scroll the scrollback (vertical drag, or horizontal fall-through).
    case scrollVertical
    /// Switch tmux window by a relative `delta` (+1 = the window after the current in index
    /// order, −1 = the window before). Only produced for a horizontal-dominant drag in
    /// multi-window tmux. See `classify` for the swipe-direction → delta mapping
    /// (content-follows-finger: rightward swipe → −1).
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

    /// How strongly horizontal a drag must be (|dx| ≥ ratio × |dy|) before it counts as a
    /// window switch rather than a scroll. Biased toward scroll: a plain vertical scroll on
    /// a phone often drifts sideways, and switching windows on that drift is jarring (device
    /// feedback: an accidental swipe landed the user in the wrong tmux window mid-scroll).
    /// 1.7 ≈ within 30° of horizontal. Below it, the drag scrolls; window-switch requires a
    /// clearly-sideways swipe.
    public static let switchDominanceRatio: Double = 1.7

    public static func classify(dx: Double, dy: Double, isMultiWindowTmux: Bool) -> PanGesture {
        // Dead-zone: require the finger to travel past the radius (Euclidean) first.
        guard (dx * dx + dy * dy) >= deadZonePoints * deadZonePoints else { return .none }

        // Window-switch only for a CLEARLY horizontal drag (|dx| ≥ ratio·|dy|) in multi-window
        // tmux. Everything else — vertical, diagonal, or gently-horizontal — scrolls.
        // Direction is content-follows-finger: swiping the content RIGHTWARD (dx>0) reveals
        // the window to its LEFT (delta −1, previous); swiping left reveals the next window
        // to the right. (Device retest 2026-07-16: the prior dx>0→+1 mapping felt backwards.)
        if isMultiWindowTmux, abs(dx) >= abs(dy) * switchDominanceRatio {
            return .switchWindow(delta: dx > 0 ? -1 : +1)
        }
        return .scrollVertical
    }
}
