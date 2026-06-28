// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

public struct Fingerprint: Equatable, Sendable {
    public let full: String

    public init(_ raw: String) {
        self.full = raw
    }

    public var truncated: String {
        let prefix = "SHA256:"
        guard full.hasPrefix(prefix) else {
            return full
        }

        let body = String(full.dropFirst(prefix.count))
        if body.count <= 9 {
            return full
        }

        let head = body.prefix(5)
        let tail = body.suffix(4)
        return "\(prefix)\(head)…\(tail)"
    }
}
