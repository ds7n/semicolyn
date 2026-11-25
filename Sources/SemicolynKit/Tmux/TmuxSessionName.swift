// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The built-in tmux session name when neither the host nor Defaults sets one.
public let builtInTmuxSessionName = "semicolyn"

/// The longest valid session name, in characters (after trimming). Mosh/ET type the
/// plain-tmux launch into an interactive shell, whose line is capped at 1024 bytes
/// (MAX_CANON); the launch is 994 bytes plus the name, so 29 is the most that fits.
public let maxTmuxSessionNameLength = 29

/// Trims surrounding whitespace; returns nil for an empty/whitespace-only string
/// so a "cleared to blank" leaf resolves as unset (inherit).
public func normalizedTmuxSessionName(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? nil : trimmed
}

/// A tmux session name is valid iff, after trimming, it is non-empty, at most
/// `maxTmuxSessionNameLength` characters, and every character is an ASCII letter,
/// digit, hyphen, or underscore. This rejects
/// tmux's forbidden `.`/`:`, whitespace, control chars, and every shell
/// metacharacter, so a validated name is always safe to interpolate into the
/// plain-tmux launch command (`new-session -d -s <name>`, `attach-session -t =<name>`).
public func isValidTmuxSessionName(_ name: String) -> Bool {
    guard let n = normalizedTmuxSessionName(name),
          n.unicodeScalars.count <= maxTmuxSessionNameLength else { return false }
    return n.unicodeScalars.allSatisfy { s in
        (s >= "a" && s <= "z") || (s >= "A" && s <= "Z")
            || (s >= "0" && s <= "9") || s == "-" || s == "_"
    }
}
