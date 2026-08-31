// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// What the App should do to resume on launch. Pure + Linux-tested (mirrors
/// `ETControlModeDecision`); the App tier only executes the returned action.
public enum ResumeAction: Equatable, Sendable {
    /// Warm: the live ConnectionViewModel + transport are still in memory; re-show it.
    case reforeground
    /// Cold Mosh/ET: rebuild the transport from this record and read its secret.
    case coldReattach(ResumableSession)
    /// Raw SSH: ask before reconnecting (a reconnect is a fresh shell).
    case promptRaw(ResumableSession)
    /// Nothing to resume.
    case none
}

/// Decide how to resume.
/// - record: the most-recent resumable session, or nil.
/// - isWarm: whether a live session object survived in memory (process not killed).
/// - secretPresent: whether the reconnect secret exists in the SecretStore (Mosh/ET cold path).
public func resumeDecision(record: ResumableSession?, isWarm: Bool, secretPresent: Bool) -> ResumeAction {
    guard let record else { return .none }
    switch record.transport {
    case .ssh:
        return .promptRaw(record)
    case .mosh, .et:
        if isWarm { return .reforeground }
        return secretPresent ? .coldReattach(record) : .none
    }
}
