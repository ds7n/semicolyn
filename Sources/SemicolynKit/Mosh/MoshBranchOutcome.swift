// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// The `ConnectionViewModel` Mosh-branch decision: hand off to a Mosh session,
/// or fall back to SSH with a user-facing banner string. Extracted here (pure,
/// Linux-tested) so the decision is covered off the Apple-only bridge gate.
public enum MoshBranchOutcome: Equatable, Sendable {
    case mosh(port: Int, key: String)
    /// `reason` is the exact banner text shown before the SSH fallback runs.
    case fallback(reason: String)
}

/// Maps captured `mosh-server` bootstrap stdout + the resolved `mosh.enabled`
/// flag to a branch outcome. An empty `stdout` (used to represent a bootstrap
/// timeout with no output) parses as `.noConnectLine` → the not-found fallback.
public func moshBranchOutcome(stdout: String, enabled: Bool) -> MoshBranchOutcome {
    switch moshLaunchDecision(enabled: enabled, bootstrap: parseMoshConnect(stdout)) {
    case let .mosh(port, key):
        return .mosh(port: port, key: key)
    case .fallbackSSH:
        // Re-derive a user-facing banner from the underlying cause. Recompute the
        // parse to distinguish the failure classes (cheap; keeps this a pure map).
        if !enabled {
            return .fallback(reason: "Mosh not enabled for this host — using SSH")
        }
        switch parseMoshConnect(stdout) {
        case .failed(.noConnectLine):
            return .fallback(reason: "mosh-server not found on host — using SSH")
        case .failed(.malformed):
            return .fallback(reason: "couldn't parse mosh-server output — using SSH")
        case .success:
            // Unreachable: enabled + success would have returned .mosh above.
            return .fallback(reason: "mosh-server not found on host — using SSH")
        }
    }
}
