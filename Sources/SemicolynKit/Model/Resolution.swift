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

/// How the UI should obtain credentials before connecting, mirroring the auth
/// precedence in `ConnectionViewModel.authenticate`: a usable publickey identity
/// wins over any stored password, and only the no-key/no-password case needs a
/// manual prompt. Extracted here (pure, Linux-tested) so `SessionView` cannot
/// regress into forcing a password screen on a key-configured host.
public enum CredentialResolution: Equatable, Sendable {
    /// The host has a resolvable identity whose private key is available → connect
    /// via publickey; do NOT prompt for a password.
    case connectWithKey
    /// No usable key, but a non-empty password is stored → connect with it silently.
    case connectWithStoredPassword
    /// No usable key and no stored password → show the password prompt.
    case promptForPassword
}

/// Decide `CredentialResolution` from the two facts the app tier can cheaply
/// establish: whether the host resolves to an identity with an available private
/// key, and whether a non-empty password secret is stored. Key precedence matches
/// `authenticate` — publickey is preferred whenever a usable key exists.
public func credentialResolution(hasUsableKey: Bool, hasStoredPassword: Bool) -> CredentialResolution {
    if hasUsableKey { return .connectWithKey }
    if hasStoredPassword { return .connectWithStoredPassword }
    return .promptForPassword
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
// Resolved at the LEAF: host config leaf → Defaults config leaf → built-in.
//
// These must resolve each leaf INDEPENDENTLY. Using `resolveOptional` on the
// whole container is wrong: it picks the host container entirely whenever the
// host container is `.explicit`, so a host that sets only SOME leaves (e.g. the
// editor writes `.explicit(SemicolynConfig(predictor: ...))` with `osc52` unset)
// would silently shadow the Defaults values of the leaves it left nil. The
// editors write partial containers as the norm, so that path is routinely hit.

/// Resolve a single leaf of a nested `Inherited` config, leaf-independently:
/// the host's leaf (when the host container is explicit AND that leaf is set) →
/// the Defaults' leaf (likewise) → `fallback`. A host container that sets some
/// leaves does NOT shadow the Defaults values of the leaves it leaves unset.
///
/// `.explicit(nil)` at the container level (a "cleared" container) carries no
/// per-leaf intent and simply falls through here — matching `.inherit`. That
/// state is not reachable through the current editors (they write either a
/// populated `.explicit(cfg)` or `.inherit`), so the choice is moot in practice.
private func resolveLeaf<Container, Leaf>(
    _ host: Inherited<Container>,
    _ defaults: Inherited<Container>,
    _ leaf: (Container) -> Leaf?,
    fallback: Leaf
) -> Leaf {
    if case .explicit(let c?) = host, let v = leaf(c) { return v }
    if case .explicit(let c?) = defaults, let v = leaf(c) { return v }
    return fallback
}

public func resolveMoshEnabled(host: Host, defaults: Defaults) -> Bool {
    resolveLeaf(host.mosh, defaults.mosh, { $0.enabled }, fallback: false)
}
public func resolveTailscaleRequired(host: Host, defaults: Defaults) -> Bool {
    resolveLeaf(host.tailscale, defaults.tailscale, { $0.required }, fallback: false)
}
public func resolvePredictorIncognito(host: Host, defaults: Defaults) -> Bool {
    resolveLeaf(host.semicolyn, defaults.semicolyn, { $0.predictor?.incognito }, fallback: false)
}
public func resolveTmuxAttemptControlMode(host: Host, defaults: Defaults) -> Bool {
    resolveLeaf(host.semicolyn, defaults.semicolyn, { $0.tmux?.attemptControlMode }, fallback: true)
}

/// Resolve the tmux -CC session name: host leaf → Defaults leaf → builtin.
/// Normalization runs inside the leaf accessor, so an empty/whitespace-only leaf
/// is seen as absent and falls through to the next level (ultimately "semicolyn").
public func resolveTmuxSessionName(host: Host, defaults: Defaults) -> String {
    resolveLeaf(host.semicolyn, defaults.semicolyn,
                { $0.tmux?.sessionName.flatMap(normalizedTmuxSessionName) },
                fallback: builtInTmuxSessionName)
}

/// Resolve whether OSC 52 clipboard writes are permitted (builtin default: true).
public func resolveOsc52Allow(host: Host, defaults: Defaults) -> Bool {
    resolveLeaf(host.semicolyn, defaults.semicolyn, { $0.osc52?.allow }, fallback: true)
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
