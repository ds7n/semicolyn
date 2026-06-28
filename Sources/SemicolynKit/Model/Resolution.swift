// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Built-in fallback for `port` per host-config-model resolution table.
private let builtInPort = 22

/// Errors raised while resolving a host field that has no built-in fallback.
public enum ResolutionError: Error, Equatable {
    /// `user` is unset on both the host and Defaults — iOS has no OS-level
    /// "current user" to fall back to, so the connection must be refused.
    case userUnset
}

/// The effective optional value of a field, honoring the three-state
/// `Inherited` distinction: an `.explicit` host value (whether a value or an
/// explicit "none") is the host's decision and is NOT overridden by Defaults;
/// only `.inherit` falls through to the Defaults record. Returns `nil` when the
/// resolved state is "none" (explicit-none or both-inherit-with-no-default).
///
/// This is why resolution cannot use `Inherited.value`: that property collapses
/// `.inherit` and `.explicit(nil)` together, which would let a cleared field
/// wrongly inherit the Defaults value.
public func resolveOptional<T>(_ host: Inherited<T>, _ defaults: Inherited<T>) -> T? {
    switch host {
    case .explicit(let v): return v                 // host decided (value or explicit-none)
    case .inherit:
        if case .explicit(let v) = defaults { return v }
        return nil
    }
}

/// Generic resolution: per-host value → Defaults value → built-in fallback,
/// honoring the three-state `Inherited` distinction (see `resolveOptional`).
public func resolve<T>(_ host: Inherited<T>, _ defaults: Inherited<T>, fallback: T) -> T {
    resolveOptional(host, defaults) ?? fallback
}

/// Resolves `port`: per-host value → Defaults value → built-in fallback (22).
public func resolvePort(host: Host, defaults: Defaults) -> Int {
    resolve(host.port, defaults.port, fallback: builtInPort)
}

/// Resolves `user`. **No built-in fallback** — throws `.userUnset` if absent on
/// both host and Defaults, or explicitly cleared on the host (the connection
/// should be refused with a clear error).
public func resolveUser(host: Host, defaults: Defaults) throws -> String {
    if let v = resolveOptional(host.user, defaults.user) { return v }
    throw ResolutionError.userUnset
}

// MARK: Tier 1 list fields (fallback: empty)

public func resolveIdentities(host: Host, defaults: Defaults) -> [IdentityRef] {
    resolve(host.identities, defaults.identities, fallback: [])
}
public func resolveProxyJump(host: Host, defaults: Defaults) -> [JumpHop] {
    resolve(host.proxyJump, defaults.proxyJump, fallback: [])
}
public func resolveLocalForwards(host: Host, defaults: Defaults) -> [LocalForward] {
    resolve(host.localForwards, defaults.localForwards, fallback: [])
}
public func resolveRemoteForwards(host: Host, defaults: Defaults) -> [RemoteForward] {
    resolve(host.remoteForwards, defaults.remoteForwards, fallback: [])
}
public func resolveDynamicForwards(host: Host, defaults: Defaults) -> [DynamicForward] {
    resolve(host.dynamicForwards, defaults.dynamicForwards, fallback: [])
}

// MARK: Tier 2 scalar fields

public func resolveCompression(host: Host, defaults: Defaults) -> Bool {
    resolve(host.compression, defaults.compression, fallback: false)
}
public func resolveForwardAgent(host: Host, defaults: Defaults) -> Bool {
    resolve(host.forwardAgent, defaults.forwardAgent, fallback: false)
}
public func resolveStrictHostKeyChecking(host: Host, defaults: Defaults) -> StrictHostKeyChecking {
    resolve(host.strictHostKeyChecking, defaults.strictHostKeyChecking, fallback: .acceptNew)
}
public func resolveServerAliveInterval(host: Host, defaults: Defaults) -> Int {
    resolve(host.serverAliveInterval, defaults.serverAliveInterval, fallback: 30)
}
public func resolveServerAliveCountMax(host: Host, defaults: Defaults) -> Int {
    resolve(host.serverAliveCountMax, defaults.serverAliveCountMax, fallback: 3)
}
public func resolvePreferredAuthentications(host: Host, defaults: Defaults) -> [AuthMethod] {
    resolve(host.preferredAuthentications, defaults.preferredAuthentications,
            fallback: [.publicKey, .keyboardInteractive, .password])
}

// MARK: Semicolyn-extension nested-config leaves
// Resolved at the leaf: host config leaf → Defaults config leaf → built-in.

public func resolveMoshEnabled(host: Host, defaults: Defaults) -> Bool {
    resolveOptional(host.mosh, defaults.mosh)?.enabled ?? false
}
public func resolveTailscaleRequired(host: Host, defaults: Defaults) -> Bool {
    resolveOptional(host.tailscale, defaults.tailscale)?.required ?? false
}
public func resolvePredictorIncognito(host: Host, defaults: Defaults) -> Bool {
    resolveOptional(host.semicolyn, defaults.semicolyn)?.predictor?.incognito ?? false
}
public func resolveTmuxAttemptControlMode(host: Host, defaults: Defaults) -> Bool {
    resolveOptional(host.semicolyn, defaults.semicolyn)?.tmux?.attemptControlMode ?? true
}

/// Resolve whether OSC 52 clipboard writes are permitted (builtin default: true).
public func resolveOsc52Allow(host: Host, defaults: Defaults) -> Bool {
    resolveOptional(host.semicolyn, defaults.semicolyn)?.osc52?.allow ?? true
}

/// Returns true if saving `savingHostId` with `chain` would loop back through a
/// host already reachable in the chain. Walks `ref` hops via `hosts`.
public func hasCycle(savingHostId: UUID, chain: [JumpHop],
                     in hosts: [UUID: Host]) -> Bool {
    var seen: Set<UUID> = [savingHostId]
    var frontier = chain
    while let hop = frontier.first {
        frontier.removeFirst()
        guard case let .ref(hostId) = hop else { continue }
        if !seen.insert(hostId).inserted { return true }
        if let next = hosts[hostId] { frontier.append(contentsOf: next.resolvedJumpChain) }
    }
    return false
}
