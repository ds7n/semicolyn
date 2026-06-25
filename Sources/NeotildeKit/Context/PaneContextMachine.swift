// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// One pane's context state machine (context-detection spec §"Per-pane state
/// machine"). Pure and time-injected: `observe(process:at:)` is the only input,
/// `now` is monotonic seconds, and repeated calls with the same reading advance
/// the dwell timers — there is no internal clock or timer. Asymmetric dwell:
/// entering an app is intentional (short 250 ms engage); leaving is often a
/// transient subprocess excursion (long 1500 ms disengage) that must not flap.
public struct PaneContextMachine: Equatable, Sendable {
    /// Latest `pane_current_command` reading (nil when the signal is unavailable).
    public private(set) var currentProcess: String?
    /// The process whose promotion set currently drives the keybar (or nil).
    public private(set) var engagedContext: String?

    private let knownProcesses: Set<String>
    private let engageDwell: TimeInterval
    private let disengageDwell: TimeInterval

    private var pendingEngage: String?
    private var pendingEngageSince: TimeInterval?
    private var disengageSince: TimeInterval?

    public init(knownProcesses: Set<String>,
                engageDwell: TimeInterval = 0.25,
                disengageDwell: TimeInterval = 1.5) {
        self.knownProcesses = knownProcesses
        self.engageDwell = engageDwell
        self.disengageDwell = disengageDwell
    }

    /// Feed the latest reading. Returns true iff `engagedContext` changed.
    @discardableResult
    public mutating func observe(_ process: String?, at now: TimeInterval) -> Bool {
        currentProcess = process
        let before = engagedContext

        // 1. Reading equals the engaged context: cancel any decay, drop candidate.
        if let engaged = engagedContext, process == engaged {
            disengageSince = nil
            pendingEngage = nil
            pendingEngageSince = nil
            return false
        }

        // 2. Reading is away from the engaged context: advance the disengage timer.
        if engagedContext != nil {
            if disengageSince == nil { disengageSince = now }
            if let since = disengageSince, now - since >= disengageDwell {
                engagedContext = nil
                disengageSince = nil
            }
        }

        // 3. Reading is a known app and not (yet) engaged: advance the engage timer.
        if let p = process, knownProcesses.contains(p), engagedContext != p {
            if pendingEngage != p {
                pendingEngage = p
                pendingEngageSince = now
            }
            if let since = pendingEngageSince, now - since >= engageDwell {
                engagedContext = p
                pendingEngage = nil
                pendingEngageSince = nil
                disengageSince = nil
            }
        } else {
            pendingEngage = nil
            pendingEngageSince = nil
        }

        return engagedContext != before
    }
}
