// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// How an ET session end should be handled by `ConnectionViewModel`. Pure +
/// Linux-tested so the decision is covered off the Apple-only bridge gate,
/// mirroring `MoshExitDecision`.
///
/// Unlike Mosh (which cannot trust its pre-handshake init frame and classifies on
/// reason + elapsed), ET's `onFirstFrame` fires only when the stream is genuinely
/// up, so first-frame IS a reliable success signal: once seen, any later end is a
/// normal session end that should dismiss gracefully.
public enum ETExitDecision: Equatable, Sendable {
    /// A real session ran (first-frame seen) and then ended. The App tears the
    /// session down and returns to the connection list. No error banner.
    case dismiss
    /// First-frame never fired: the handshake never came up. The App shows the
    /// `.failed` banner carrying this sanitized reason string.
    case handshakeFailed(String)
}

/// Classify an ET session end.
/// - Parameters:
///   - reason: the raw `onEnd` reason. UNTRUSTED (possibly server-supplied); only
///     consulted on the failure path, and sanitized here before it can reach the
///     UI or a log.
///   - sawFirstFrame: whether `onFirstFrame` fired for this session.
public func etExitDecision(reason: String?, sawFirstFrame: Bool) -> ETExitDecision {
    sawFirstFrame ? .dismiss : .handshakeFailed(sanitizeEndReason(reason))
}
