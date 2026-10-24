// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Connection options that are stored but not yet applied at runtime: their
/// resolvers (`resolveProxyJump`, `resolveLocalForwards`/`Remote`/`Dynamic`,
/// `resolveCompression`, `resolveForwardAgent`, `resolveStrictHostKeyChecking`,
/// `resolvePreferredAuthentications`, `resolveTailscaleRequired`) have no call sites
/// outside tests. Their rows are hidden in the host editor and Connection Defaults
/// so nothing promises an effect that never happens (Tailscale and Host key checking
/// read as security controls). Stored values and the model are kept; flip a flag to
/// re-show its row once the option is wired.
enum UnwiredOptions {
    static let jumpChain = false
    static let portForwarding = false
    static let tailscale = false
    static let compression = false
    static let agentForwarding = false
    static let hostKeyChecking = false
    static let preferredAuth = false
}
