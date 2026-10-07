// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Backoff delay (seconds) before reconnect attempt `attempt` of the remote log stream.
///
/// Exponential from 1s, doubling per attempt, capped at 30s:
/// attempt 0 -> 1, 1 -> 2, 2 -> 4, 3 -> 8, 4 -> 16, 5+ -> 30.
/// A negative attempt (caller bug) clamps to the first delay. Large attempts never
/// overflow: anything at or past the cap boundary returns the cap directly.
public func remoteLogReconnectDelay(attempt: Int) -> Double {
    let cap = 30.0
    let a = max(0, attempt)
    // 2^5 = 32 already exceeds the cap, so short-circuit before any shift can overflow.
    guard a < 5 else { return cap }
    return min(cap, Double(1 << a))
}
