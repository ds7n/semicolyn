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
