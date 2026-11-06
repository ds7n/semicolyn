// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Characters a POSIX shell word may contain unquoted without any expansion or splitting.
private let shellSafeCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+:,@%=")

/// Renders `value` as one POSIX shell word that the remote login shell reads back
/// literally (security audit L3). A value made only of safe characters is returned as-is
/// so ordinary paths stay readable in logs; anything else is single-quoted, with each `'`
/// written as `'\''`. A leading `~/` stays outside the quotes so the shell still expands
/// it to the home directory. An empty value becomes `''` rather than vanishing.
public func shellWord(_ value: String) -> String {
    if value.hasPrefix("~/") {
        let rest = String(value.dropFirst(2))
        return rest.isEmpty ? "~/" : "~/" + shellWord(rest)
    }
    if !value.isEmpty, value.allSatisfy({ shellSafeCharacters.contains($0) }) {
        return value
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
