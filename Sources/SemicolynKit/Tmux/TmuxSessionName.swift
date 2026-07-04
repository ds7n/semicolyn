// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The built-in tmux -CC session name when neither the host nor Defaults sets one.
public let builtInTmuxSessionName = "semicolyn"

/// Trims surrounding whitespace; returns nil for an empty/whitespace-only string
/// so a "cleared to blank" leaf resolves as unset (inherit).
public func normalizedTmuxSessionName(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? nil : trimmed
}

/// A tmux session name is valid iff, after trimming, it is non-empty and every
/// character is an ASCII letter, digit, hyphen, or underscore. This rejects
/// tmux's forbidden `.`/`:`, whitespace, control chars, and every shell
/// metacharacter, so a validated name is always safe to interpolate into the
/// `-CC new-session -A -s <name>` command.
public func isValidTmuxSessionName(_ name: String) -> Bool {
    guard let n = normalizedTmuxSessionName(name) else { return false }
    return n.unicodeScalars.allSatisfy { s in
        (s >= "a" && s <= "z") || (s >= "A" && s <= "Z")
            || (s >= "0" && s <= "9") || s == "-" || s == "_"
    }
}
