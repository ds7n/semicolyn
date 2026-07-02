// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Whether to hand off to a Mosh session or fall back to plain SSH. Mirrors the
/// `tmuxLaunchDecision` pure-decision pattern: no I/O, fully testable.
public enum MoshLaunchDecision: Equatable, Sendable {
    case mosh(port: Int, key: String)
    case fallbackSSH(reason: String)
}

/// Maps the resolved `mosh.enabled` flag + the bootstrap parse result to a launch
/// decision. Any failure yields `.fallbackSSH` so the user still gets a shell.
public func moshLaunchDecision(enabled: Bool, bootstrap: MoshConnect) -> MoshLaunchDecision {
    guard enabled else { return .fallbackSSH(reason: "Mosh not enabled for this host") }
    switch bootstrap {
    case let .success(port, key):
        return .mosh(port: port, key: key)
    case .failed(.noConnectLine):
        return .fallbackSSH(reason: "mosh-server produced no session (is mosh installed on the host?)")
    case .failed(.malformed):
        return .fallbackSSH(reason: "could not parse mosh-server output")
    }
}
