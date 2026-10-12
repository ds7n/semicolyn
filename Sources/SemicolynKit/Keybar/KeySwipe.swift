// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// A vertical swipe on a keybar key.
public enum KeySwipeDirection: String, Sendable, Equatable {
    case up, down
}

/// Classifies a finished drag on a keybar key as a swipe up, a swipe down, or
/// neither. A key's swipe recognizer runs alongside the scrolling middle region,
/// so a drag only counts as a swipe when it travels more than `threshold` points
/// vertically AND its vertical travel exceeds 1.5x its horizontal travel. Anything
/// else (a sideways scroll, a diagonal, a short jiggle) returns nil and is left
/// to the scroll view. `dy` is negative for upward travel (UIKit coordinates).
public func keySwipeDirection(dx: Double, dy: Double, threshold: Double = 12) -> KeySwipeDirection? {
    guard abs(dy) > threshold, abs(dy) > abs(dx) * 1.5 else { return nil }
    return dy < 0 ? .up : .down
}
