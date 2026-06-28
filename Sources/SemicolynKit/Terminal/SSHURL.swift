// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The connect coordinates extracted from a tapped `ssh://` link
/// (`ssh://[user@]host[:port][/path]`). `user`/`port` are nil when the URL omits them.
public struct SSHConnectTarget: Equatable, Sendable {
    public let host: String
    public let user: String?
    public let port: Int?
    public init(host: String, user: String? = nil, port: Int? = nil) {
        self.host = host
        self.user = user
        self.port = port
    }
}

/// Parse an `ssh://[user@]host[:port][/path]` link into its connect coordinates.
///
/// Hand-parsed (not `URLComponents`) for deterministic behavior across the Linux
/// and Apple Foundation implementations. Returns nil for a non-ssh scheme, an empty
/// host, or a malformed port (non-numeric or outside 1…65535). Any `/path` is dropped
/// (SSH ignores it). An empty userinfo (`ssh://@host`) yields `user == nil`. IPv6
/// literals must be bracketed (`ssh://[::1]:22`).
public func parseSSHURL(_ link: String) -> SSHConnectTarget? {
    guard link.lowercased().hasPrefix("ssh://") else { return nil }
    // Authority is everything after the scheme, up to the first '/' (drop any path).
    let authority = link.dropFirst("ssh://".count).prefix { $0 != "/" }
    guard !authority.isEmpty else { return nil }

    // Split userinfo on the first '@'.
    var user: String?
    let hostPort: Substring
    if let at = authority.firstIndex(of: "@") {
        let u = authority[..<at]
        user = u.isEmpty ? nil : String(u)
        hostPort = authority[authority.index(after: at)...]
    } else {
        hostPort = authority
    }

    // host[:port], allowing a bracketed IPv6 literal.
    let host: String
    let portPart: Substring?
    if hostPort.first == "[" {
        guard let close = hostPort.firstIndex(of: "]") else { return nil }
        let inside = hostPort[hostPort.index(after: hostPort.startIndex)..<close]
        host = String(inside)
        let afterClose = hostPort[hostPort.index(after: close)...]
        if afterClose.isEmpty {
            portPart = nil
        } else if afterClose.first == ":" {
            portPart = afterClose.dropFirst()
        } else {
            return nil // junk after the IPv6 ']'
        }
    } else if let colon = hostPort.lastIndex(of: ":") {
        host = String(hostPort[..<colon])
        portPart = hostPort[hostPort.index(after: colon)...]
    } else {
        host = String(hostPort)
        portPart = nil
    }
    guard !host.isEmpty else { return nil }

    // Port: optional, but when present must be ASCII digits in 1…65535.
    var port: Int?
    if let pp = portPart {
        guard !pp.isEmpty, pp.allSatisfy({ ("0"..."9").contains($0) }),
              let n = Int(pp), (1...65535).contains(n) else { return nil }
        port = n
    }

    return SSHConnectTarget(host: host, user: user, port: port)
}
