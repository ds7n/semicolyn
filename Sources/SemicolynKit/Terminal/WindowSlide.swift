// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// A screen edge for the window-switch slide animation.
public enum SlideEdge: Sendable, Equatable { case left, right }

/// Which edge the OUTgoing window exits toward and which edge the INcoming window enters from,
/// for a window switch of `delta`. Content-follows-finger (matching the shipped swipe flip,
/// `GestureClassifier`: rightward swipe -> delta -1 = previous window): the current window
/// exits toward the finger-release direction and the new one enters from the opposite side.
/// `delta == 0` is not a switch, so it yields nil (no animation).
public func windowSlideDirection(delta: Int) -> (out: SlideEdge, in: SlideEdge)? {
    if delta < 0 { return (out: .right, in: .left) }   // previous window (rightward swipe)
    if delta > 0 { return (out: .left, in: .right) }    // next window (leftward swipe)
    return nil
}
