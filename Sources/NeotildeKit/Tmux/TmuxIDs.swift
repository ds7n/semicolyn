// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct PaneID: Hashable, Sendable {
    public let raw: UInt32
    public init(raw: UInt32) { self.raw = raw }
}
public struct WindowID: Hashable, Sendable {
    public let raw: UInt32
    public init(raw: UInt32) { self.raw = raw }
}
public struct SessionID: Hashable, Sendable {
    public let raw: UInt32
    public init(raw: UInt32) { self.raw = raw }
}

private func parseSigiled(_ token: Substring, _ sigil: Character) -> UInt32? {
    guard token.first == sigil else { return nil }
    let rest = token.dropFirst()
    guard !rest.isEmpty, rest.allSatisfy(\.isNumber), let n = UInt32(rest) else { return nil }
    return n
}

extension PaneID {
    init?(token: Substring) {
        guard let n = parseSigiled(token, "%") else { return nil }
        self.init(raw: n)
    }
}
extension WindowID {
    init?(token: Substring) {
        guard let n = parseSigiled(token, "@") else { return nil }
        self.init(raw: n)
    }
}
extension SessionID {
    init?(token: Substring) {
        guard let n = parseSigiled(token, "$") else { return nil }
        self.init(raw: n)
    }
}

/// True iff `name` is a valid Neotilde tmux session name: a non-empty string of
/// lowercase ASCII letters, digits, and hyphens (`^[a-z0-9-]+$`) — the only
/// characters a Neotilde-minted session name ever contains (per the tmux-session
/// naming spec). Shared by the command encoder (`kill-session`) and the session
/// controller (`new-session` attach) so the two can never drift.
func isValidTmuxSessionName(_ name: String) -> Bool {
    guard !name.isEmpty else { return false }
    return name.utf8.allSatisfy { b in
        (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || b == 0x2D // a-z, 0-9, '-'
    }
}
