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
