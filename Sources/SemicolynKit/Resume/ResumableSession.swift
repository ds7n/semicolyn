// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A session that was connected when the app left, enough to restore it. The
/// reconnect SECRET (Mosh MOSH_KEY / ET IDPASSKEY) is NOT here: it lives in the
/// Keychain-backed `SecretStore` under `SecretRef.resumeSecret(sessionID:)`, so
/// this metadata record can be stored/logged without exposing it. Raw SSH records
/// carry no secret (raw always reconnects fresh after a prompt).
public struct ResumableSession: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let hostID: UUID
    public let transport: Transport
    /// The reattach endpoint (Mosh server port, ET server host/port).
    public let host: String
    public let port: Int
    /// The tmux -CC session name if the session was control-mode, so a reconnect
    /// runs `new-session -A -s <name>` and reattaches the same panes; nil otherwise.
    public let tmuxSessionName: String?
    /// Timestamp for most-recent ordering. NOT used for expiry (records clear on
    /// failure, not on a timer).
    public let lastConnectedAt: Date
    /// The tmux prefix byte discovered in-band during the live session (e.g. 0x01 for
    /// C-a), captured at background/suspend. Replayed on a state-resume reattach, where
    /// in-band re-discovery cannot run: the restored screen is already inside attached
    /// tmux, so a probe `printf` would be typed into the running pane, never executed
    /// (device bug 2026-09-13, Issue B). `nil` when unknown (a pre-field record, a
    /// session whose discovery never completed, or a transport without a tmux prefix);
    /// the reattach path then falls back to the in-band probe.
    public let discoveredPrefix: UInt8?

    public init(sessionID: UUID, hostID: UUID, transport: Transport, host: String,
                port: Int, tmuxSessionName: String?, lastConnectedAt: Date,
                discoveredPrefix: UInt8? = nil) {
        self.sessionID = sessionID
        self.hostID = hostID
        self.transport = transport
        self.host = host
        self.port = port
        self.tmuxSessionName = tmuxSessionName
        self.lastConnectedAt = lastConnectedAt
        self.discoveredPrefix = discoveredPrefix
    }
}
