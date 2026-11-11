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

/// Decides, the moment a drag on a keybar key starts moving, whether the key
/// claims it as a possible swipe. A drag that starts sideways (or exactly
/// diagonal) is left to the scrolling middle region; claiming it would stop the
/// scroll view from moving. `keySwipeDirection` still judges the finished drag.
public func keySwipeShouldClaim(dx: Double, dy: Double) -> Bool {
    abs(dy) > abs(dx)
}

/// The swipe a keybar key would fire if the finger lifted right now, for the live
/// flick preview: the direction `keySwipeDirection` returns, or nil when the drag is
/// not (yet) a swipe or that direction has no binding on this key. Re-evaluated on
/// every drag change, so reversing past the key switches the preview and returning
/// inside the threshold clears it.
public func keySwipePreview(dx: Double, dy: Double, hasUp: Bool, hasDown: Bool,
                            threshold: Double = 12) -> KeySwipeDirection? {
    switch keySwipeDirection(dx: dx, dy: dy, threshold: threshold) {
    case .up?:   return hasUp ? .up : nil
    case .down?: return hasDown ? .down : nil
    case nil:    return nil
    }
}
