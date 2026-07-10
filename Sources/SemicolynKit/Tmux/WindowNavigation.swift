// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Wrap-around destination index for stepping between tmux windows (`⌘]`/`⌘[`,
/// Esc-pill swipe). Returns the destination index, or `nil` when stepping is a
/// no-op: fewer than two windows, or a `current` index outside `0..<count`
/// (guards against stale published state). `delta` is typically ±1 but any
/// integer wraps correctly, including negative modulo.
public func stepIndex(current: Int, delta: Int, count: Int) -> Int? {
    guard count > 1, current >= 0, current < count else { return nil }
    return ((current + delta) % count + count) % count
}

/// Clamped destination index for stepping between tmux windows by one (horizontal
/// drag). Unlike `stepIndex`, this does NOT wrap: at the last window a forward step
/// and at the first window a backward step both return `nil` (a no-op). Also `nil`
/// for fewer than two windows or a `current` outside `0..<count`. `delta` is ±1.
public func clampedStepIndex(current: Int, delta: Int, count: Int) -> Int? {
    guard count > 1, current >= 0, current < count else { return nil }
    let target = current + delta
    guard target >= 0, target < count else { return nil }
    return target
}
