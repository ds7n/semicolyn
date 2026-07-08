// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Resolves a host string to a NUMERIC IP for the Mosh client.
///
/// Why this exists: `mosh-client` (via `libmoshios`) calls `getaddrinfo` with
/// `AI_NUMERICHOST`, which accepts ONLY a numeric IP and does NO DNS resolution — so
/// handing it a hostname (`server01.example.com`) fails with "Bad IP address …
/// nodename nor servname provided" and the whole Mosh session dies at handshake
/// (device trace, build 24). SSH resolves the name itself, so SSH connects fine; the
/// Mosh path must resolve the name to an address BEFORE constructing the session.
///
/// Behavior:
/// - An input that is already a numeric IPv4/IPv6 literal is returned unchanged.
/// - Otherwise, DNS-resolve via `getaddrinfo` (no `AI_NUMERICHOST`) and return the
///   first usable address as a numeric string (IPv4 preferred, then IPv6).
/// - Returns `nil` if resolution fails (caller falls back / surfaces the failure).
enum MoshHostResolver {
    /// Resolve `host` to a numeric IP string, or `nil` if it cannot be resolved.
    static func numericAddress(for host: String) -> String? {
        // Fast path: already a numeric literal (v4 or v6) → no DNS needed.
        if isNumericIP(host) { return host }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC          // v4 or v6
        hints.ai_socktype = SOCK_DGRAM       // Mosh is UDP
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let head = result else { return nil }
        defer { freeaddrinfo(head) }

        // Prefer IPv4, then fall back to the first IPv6.
        var firstV6: String?
        var node: UnsafeMutablePointer<addrinfo>? = head
        while let ai = node {
            if let str = Self.numericString(from: ai.pointee) {
                if ai.pointee.ai_family == AF_INET { return str }   // IPv4 wins
                if firstV6 == nil { firstV6 = str }
            }
            node = ai.pointee.ai_next
        }
        return firstV6
    }

    /// True if `s` is already a numeric IPv4 or IPv6 literal (no DNS).
    private static func isNumericIP(_ s: String) -> Bool {
        var v4 = in_addr()
        if s.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 { return true }
        var v6 = in6_addr()
        if s.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 { return true }
        return false
    }

    /// Numeric presentation string for a resolved `addrinfo` entry.
    private static func numericString(from ai: addrinfo) -> String? {
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = getnameinfo(ai.ai_addr, ai.ai_addrlen,
                             &buf, socklen_t(buf.count),
                             nil, 0, NI_NUMERICHOST)
        guard rc == 0 else { return nil }
        return String(cString: buf)
    }
}
