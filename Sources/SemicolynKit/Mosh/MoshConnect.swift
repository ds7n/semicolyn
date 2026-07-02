// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Why a `MOSH CONNECT` line could not be turned into a session.
public enum MoshConnectError: Equatable, Sendable {
    /// No `MOSH CONNECT` line was found in the server output at all.
    case noConnectLine
    /// A `MOSH CONNECT` line was found but the port/key could not be parsed.
    /// Carries the offending line for diagnostics.
    case malformed(String)
}

/// Result of parsing `mosh-server`'s stdout for its handoff line.
public enum MoshConnect: Equatable, Sendable {
    case success(port: Int, key: String)
    case failed(MoshConnectError)
}

/// Parses `mosh-server new` output for its `MOSH CONNECT <port> <key>` handoff
/// line, tolerating surrounding banner/motd text. Returns a typed failure rather
/// than throwing — the caller falls back to plain SSH on any failure.
public func parseMoshConnect(_ output: String) -> MoshConnect {
    for line in output.split(whereSeparator: \.isNewline) {
        guard line.hasPrefix("MOSH CONNECT ") else { continue }
        // Split on single spaces so a trailing empty key is caught (not trimmed away).
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 4,
              let port = Int(parts[2]), (1...65535).contains(port),
              !parts[3].isEmpty
        else { return .failed(.malformed(String(line))) }
        return .success(port: port, key: String(parts[3]))
    }
    return .failed(.noConnectLine)
}
