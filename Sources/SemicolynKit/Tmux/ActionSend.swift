// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// How a gesture action reaches tmux: a KEY (bytes to send after the prefix) or a
/// command-mode fallback command string.
public enum ActionSend: Equatable, Sendable {
    case key([UInt8])
    case commandMode(String)
}

/// Resolve how to send `action`: try the session-`discovered` key, then the
/// per-host `persisted` key (each only if it ENCODES via `tmuxKeyBytes`); if neither
/// yields a sendable key, fall back to command mode with the action's command.
public func resolveActionSend(action: TmuxAction, discovered: String?, persisted: String?) -> ActionSend {
    if let d = discovered, let bytes = tmuxKeyBytes(d) { return .key(bytes) }
    if let p = persisted, let bytes = tmuxKeyBytes(p) { return .key(bytes) }
    return .commandMode(action.command)
}
