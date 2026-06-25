// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Drives the visual bell halo + haptic. Timestamp-injected (no internal clock)
/// for deterministic Linux tests. Intensity holds at peak for `holdQuiet` after
/// the last ring, then fades over `fade`. Haptic fires at most once per `hapticMinGap`.
public struct BellStateMachine: Equatable, Sendable {
    public static let holdQuiet: TimeInterval = 0.4
    public static let fade: TimeInterval = 0.25
    public static let hapticMinGap: TimeInterval = 0.5

    private var lastRing: Date?
    private var lastHaptic: Date?

    public init() {}

    /// Register a bell at `now`. Returns whether a haptic should fire (throttled).
    public mutating func ring(at now: Date) -> Bool {
        lastRing = now
        if let lh = lastHaptic, now.timeIntervalSince(lh) < Self.hapticMinGap {
            return false
        }
        lastHaptic = now
        return true
    }

    /// Halo intensity ∈ [0,1] at `now`.
    public func intensity(at now: Date) -> Double {
        guard let r = lastRing else { return 0 }
        let dt = now.timeIntervalSince(r)
        if dt <= 0 { return 1 }
        if dt <= Self.holdQuiet { return 1 }
        let f = (dt - Self.holdQuiet) / Self.fade
        return f >= 1 ? 0 : 1 - f
    }
}
