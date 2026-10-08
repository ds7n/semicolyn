// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// When a fresh connect launches tmux IN-BAND (Mosh/ET type the launch into the login
/// shell), the App covers the terminal with a "Connecting to <host>..." overlay so the
/// user never sees the login shell, the typed launch command or the tmux spawn stall.
/// This pure decider says when to take the overlay down. It masks the delay; it does not
/// shorten it.

/// Quiet window (seconds) after the last output that arrived AFTER the launch sentinel:
/// tmux has painted and the stream has settled.
public let connectRevealQuietSeconds: Double = 0.15

/// Hard backstop (seconds since the in-band launch was typed): reveal no matter what, so
/// the overlay can never strand the user.
public let connectRevealTimeoutSeconds: Double = 3.0

/// Everything the reveal decision reads. Snapshotted by the App on each output chunk, on
/// a mouse-mode change and on its re-check timers.
public struct ConnectRevealInput: Equatable, Sendable {
    /// The `SEMICOLYN_LAUNCH` sentinel was seen in output since the launch: the remote
    /// shell actually executed the launch script.
    public var sentinelSeen: Bool
    /// Seconds since the most recent output chunk that arrived AFTER the chunk carrying
    /// the sentinel; nil when no output has arrived after it yet. Nil means "keep
    /// covering": the silence right after the sentinel is the launch script's tmux
    /// spawns (the stall the overlay hides), so it is NOT measured from the sentinel time.
    public var secondsSinceLastOutput: Double?
    /// Terminal mouse reporting turned on (tmux attached and enabled `mouse on`).
    public var mouseModeOn: Bool
    /// The launch probe classified tmux as missing on the remote.
    public var tmuxMissing: Bool
    /// The connection failed, ended or was torn down.
    public var sessionEnded: Bool
    /// Seconds since the in-band launch was typed.
    public var secondsSinceLaunch: Double

    public init(sentinelSeen: Bool, secondsSinceLastOutput: Double?, mouseModeOn: Bool,
                tmuxMissing: Bool, sessionEnded: Bool, secondsSinceLaunch: Double) {
        self.sentinelSeen = sentinelSeen
        self.secondsSinceLastOutput = secondsSinceLastOutput
        self.mouseModeOn = mouseModeOn
        self.tmuxMissing = tmuxMissing
        self.sessionEnded = sessionEnded
        self.secondsSinceLaunch = secondsSinceLaunch
    }
}

/// Why the overlay came down. The raw value is logged verbatim.
public enum ConnectRevealReason: String, Sendable {
    case mouseMode, sentinelQuiet, tmuxMissing, sessionEnded, timeout
}

/// Decide whether to reveal the terminal. Returns nil to keep covering.
///
/// Precedence: `sessionEnded`, `tmuxMissing`, `mouseMode`, `sentinelQuiet` (sentinel seen
/// AND at least `connectRevealQuietSeconds` since the last post-sentinel output),
/// `timeout` (`secondsSinceLaunch >= connectRevealTimeoutSeconds`).
public func connectRevealDecision(_ input: ConnectRevealInput) -> ConnectRevealReason? {
    if input.sessionEnded { return .sessionEnded }
    if input.tmuxMissing { return .tmuxMissing }
    if input.mouseModeOn { return .mouseMode }
    if input.sentinelSeen, let quiet = input.secondsSinceLastOutput,
       quiet >= connectRevealQuietSeconds {
        return .sentinelQuiet
    }
    if input.secondsSinceLaunch >= connectRevealTimeoutSeconds { return .timeout }
    return nil
}

/// The one-line decision log for a reveal (decision-point logging standard: inputs, then
/// output, then reason), e.g.
/// `connect:reveal sentinel=true quiet=0.20 mouse=false missing=false ended=false → after=0.93s reason=sentinelQuiet`.
public func connectRevealLogLine(_ input: ConnectRevealInput, reason: ConnectRevealReason) -> String {
    decisionLine("connect:reveal",
                 inputs: [("sentinel", "\(input.sentinelSeen)"),
                          ("quiet", input.secondsSinceLastOutput.map { String(format: "%.2f", $0) } ?? "nil"),
                          ("mouse", "\(input.mouseModeOn)"),
                          ("missing", "\(input.tmuxMissing)"),
                          ("ended", "\(input.sessionEnded)")],
                 outputs: [("after", String(format: "%.2fs", input.secondsSinceLaunch))],
                 reason: reason.rawValue)
}
