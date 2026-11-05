// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Result of gating an OSC 52 clipboard-write request.
public enum Osc52Action: Equatable, Sendable {
    case write([UInt8])
    case drop
    /// Allowed, but larger than `osc52MaxBytes`: refused, and the user is told.
    case tooLarge(bytes: Int)

    /// Log form without the clipboard content.
    public var logLabel: String {
        switch self {
        case .write(let bytes): return "write(\(bytes.count))"
        case .drop: return "drop"
        case .tooLarge(let bytes): return "tooLarge(\(bytes))"
        }
    }
}

/// The largest OSC 52 write accepted (1 MiB of decoded payload). Copying from tmux or vim
/// stays far below it; anything bigger is refused rather than silently replacing the
/// clipboard with a huge blob (security audit M1).
public let osc52MaxBytes = 1 << 20

/// How long after a Mosh session's first frame a clipboard write is treated as Mosh's
/// replay. mosh-server keeps the last OSC 52 in its screen state and re-sends it to every
/// freshly started client, so without this each connect or resume would overwrite the
/// phone's clipboard with a stale server copy.
public let osc52MoshReplayWindow: Double = 5

/// True when a clipboard write is (almost certainly) Mosh replaying an old copy: the
/// session is Mosh and its first frame arrived less than `osc52MoshReplayWindow` seconds
/// ago, or hasn't arrived yet (`nil`). Never true for SSH or ET, which don't replay.
public func osc52IsMoshReplay(isMosh: Bool, secondsSinceFirstFrame: Double?) -> Bool {
    guard isMosh else { return false }
    guard let seconds = secondsSinceFirstFrame else { return true }
    return seconds < osc52MoshReplayWindow
}

/// Gate an OSC 52 *write* (SwiftTerm only invokes the clipboard delegate for
/// writes; reads are never echoed back, read = always no-op by construction).
/// Empty payloads drop so a stray sequence can't clear the system clipboard, and a Mosh
/// replay (`osc52IsMoshReplay`) drops so a stale copy doesn't replace the clipboard.
public func osc52Action(allow: Bool, content: [UInt8], isMoshReplay: Bool) -> Osc52Action {
    guard allow, !content.isEmpty, !isMoshReplay else { return .drop }
    guard content.count <= osc52MaxBytes else { return .tooLarge(bytes: content.count) }
    return .write(content)
}

/// The notice shown for a clipboard write. Ordinary writes are silent, as in kitty,
/// Ghostty and WezTerm: the server can never READ the clipboard (SwiftTerm handles writes
/// only), pastes are bracketed and sanitized, and each host can turn writes off. Only a
/// refused oversized write is announced, so the user knows the copy didn't happen.
public func osc52Notice(_ action: Osc52Action) -> String? {
    switch action {
    case .drop, .write:
        return nil
    case .tooLarge(let bytes):
        let mb = Double(bytes) / Double(1 << 20)
        return String(format: "Blocked a %.1f MB clipboard copy from the server (limit 1 MB)", mb)
    }
}
