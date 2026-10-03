// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// How soon after the previous tap a tap counts as a follow-up (the 2nd/3rd tap of a
/// multi-tap). Covers iOS's multi-tap interval (~0.35s) with margin, so a real double-tap's
/// second tap is always recognized as a follow-up.
public let followUpTapWindow: Double = 0.4

/// Whether a tap at `now` is a follow-up of the tap at `previousTapAt` (seconds on a
/// monotonic clock, e.g. `CACurrentMediaTime()`).
///
/// Plain-tmux fires the single-tap action instantly (no waiting to rule out a double-tap,
/// per Apple's "stackable taps" guidance and SwiftTerm's own default), so a double-tap also
/// delivers single taps 1 and 2. Only tap 1 may act: a follow-up would send tmux a second
/// click (its own double-click binding enters copy-mode) or clear the word the double-tap
/// just selected. A negative interval (clock anomaly) is treated as a fresh tap so a real
/// tap is never swallowed.
public func isFollowUpTap(at now: Double, previousTapAt: Double?,
                          window: Double = followUpTapWindow) -> Bool {
    guard let previousTapAt else { return false }
    let interval = now - previousTapAt
    return interval >= 0 && interval < window
}
