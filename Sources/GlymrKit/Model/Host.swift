// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum JumpHop: Codable, Equatable, Sendable {
    case ref(hostId: UUID)
    case inline(hostName: String, port: Int?, user: String?, identities: [IdentityRef]?)
}

public struct LocalForward: Codable, Equatable, Sendable {
    public var bindAddress: String?; public var bindPort: Int
    public var hostAddress: String; public var hostPort: Int
    // Explicit `public` init: the synthesized memberwise init is only `internal`,
    // so the app module (a separate module) could not construct one otherwise.
    public init(bindAddress: String?, bindPort: Int, hostAddress: String, hostPort: Int) {
        self.bindAddress = bindAddress; self.bindPort = bindPort
        self.hostAddress = hostAddress; self.hostPort = hostPort
    }
}
public struct RemoteForward: Codable, Equatable, Sendable {
    public var bindAddress: String?; public var bindPort: Int
    public var hostAddress: String; public var hostPort: Int
    public init(bindAddress: String?, bindPort: Int, hostAddress: String, hostPort: Int) {
        self.bindAddress = bindAddress; self.bindPort = bindPort
        self.hostAddress = hostAddress; self.hostPort = hostPort
    }
}
public struct DynamicForward: Codable, Equatable, Sendable {
    public var bindAddress: String?; public var bindPort: Int
    public init(bindAddress: String?, bindPort: Int) {
        self.bindAddress = bindAddress; self.bindPort = bindPort
    }
}

public enum HostKeySource: String, Codable, Equatable, Sendable {
    case manual, trustOnFirstUse = "trust-on-first-use", imported
}
public struct HostKey: Codable, Equatable, Sendable {
    public var algorithm: String; public var fingerprint: String
    public var addedAt: Date; public var source: HostKeySource
}

public enum StrictHostKeyChecking: String, Codable, Equatable, Sendable {
    case yes, acceptNew = "accept-new", ask, no
}

/// A Glymr host record. Required fields are non-optional; every OpenSSH-derived
/// optional uses `Inherited<T>` so "inherit" vs "explicitly none" never collide.
public struct Host: Codable, Equatable, Sendable {
    // Required
    public let id: UUID
    public var label: String
    public var hostName: String

    // OpenSSH Tier 1 — all optional, inherit from Defaults if undefined.
    public var user: Inherited<String>
    public var port: Inherited<Int>
    public var identities: Inherited<[IdentityRef]>
    public var passwordRef: Inherited<UUID>
    public var proxyJump: Inherited<[JumpHop]>
    public var localForwards: Inherited<[LocalForward]>
    public var remoteForwards: Inherited<[RemoteForward]>
    public var dynamicForwards: Inherited<[DynamicForward]>

    // OpenSSH Tier 2 — all optional.
    public var serverAliveInterval: Inherited<Int>
    public var serverAliveCountMax: Inherited<Int>
    public var compression: Inherited<Bool>
    public var strictHostKeyChecking: Inherited<StrictHostKeyChecking>
    public var forwardAgent: Inherited<Bool>
    public var preferredAuthentications: Inherited<[AuthMethod]>

    // Glymr extensions — all optional, namespaced.
    public var mosh: Inherited<MoshConfig>
    public var tailscale: Inherited<TailscaleConfig>
    public var glymr: Inherited<GlymrConfig>

    public init(id: UUID, label: String, hostName: String,
                user: Inherited<String> = .inherit,
                port: Inherited<Int> = .inherit,
                identities: Inherited<[IdentityRef]> = .inherit,
                proxyJump: Inherited<[JumpHop]> = .inherit,
                passwordRef: Inherited<UUID> = .inherit,
                localForwards: Inherited<[LocalForward]> = .inherit,
                remoteForwards: Inherited<[RemoteForward]> = .inherit,
                dynamicForwards: Inherited<[DynamicForward]> = .inherit,
                serverAliveInterval: Inherited<Int> = .inherit,
                serverAliveCountMax: Inherited<Int> = .inherit,
                compression: Inherited<Bool> = .inherit,
                strictHostKeyChecking: Inherited<StrictHostKeyChecking> = .inherit,
                forwardAgent: Inherited<Bool> = .inherit,
                preferredAuthentications: Inherited<[AuthMethod]> = .inherit,
                mosh: Inherited<MoshConfig> = .inherit,
                tailscale: Inherited<TailscaleConfig> = .inherit,
                glymr: Inherited<GlymrConfig> = .inherit) {
        self.id = id; self.label = label; self.hostName = hostName
        self.user = user; self.port = port
        self.identities = identities; self.proxyJump = proxyJump
        self.passwordRef = passwordRef
        self.localForwards = localForwards; self.remoteForwards = remoteForwards
        self.dynamicForwards = dynamicForwards
        self.serverAliveInterval = serverAliveInterval
        self.serverAliveCountMax = serverAliveCountMax
        self.compression = compression
        self.strictHostKeyChecking = strictHostKeyChecking
        self.forwardAgent = forwardAgent
        self.preferredAuthentications = preferredAuthentications
        self.mosh = mosh; self.tailscale = tailscale; self.glymr = glymr
    }

    /// The resolved jump chain (empty when inherited/unset for cycle-checking).
    public var resolvedJumpChain: [JumpHop] { proxyJump.value ?? [] }
}

/// Singleton defaults record: same optional fields as Host (it is `Partial<Host>`),
/// no required ones. Same names/types/semantics; resolution falls through here.
public struct Defaults: Codable, Equatable, Sendable {
    public var user: Inherited<String>
    public var port: Inherited<Int>
    public var identities: Inherited<[IdentityRef]>
    public var passwordRef: Inherited<UUID>
    public var proxyJump: Inherited<[JumpHop]>
    public var localForwards: Inherited<[LocalForward]>
    public var remoteForwards: Inherited<[RemoteForward]>
    public var dynamicForwards: Inherited<[DynamicForward]>
    public var serverAliveInterval: Inherited<Int>
    public var serverAliveCountMax: Inherited<Int>
    public var compression: Inherited<Bool>
    public var strictHostKeyChecking: Inherited<StrictHostKeyChecking>
    public var forwardAgent: Inherited<Bool>
    public var preferredAuthentications: Inherited<[AuthMethod]>
    public var mosh: Inherited<MoshConfig>
    public var tailscale: Inherited<TailscaleConfig>
    public var glymr: Inherited<GlymrConfig>

    public init(user: Inherited<String> = .inherit,
                port: Inherited<Int> = .inherit,
                identities: Inherited<[IdentityRef]> = .inherit,
                passwordRef: Inherited<UUID> = .inherit,
                proxyJump: Inherited<[JumpHop]> = .inherit,
                localForwards: Inherited<[LocalForward]> = .inherit,
                remoteForwards: Inherited<[RemoteForward]> = .inherit,
                dynamicForwards: Inherited<[DynamicForward]> = .inherit,
                serverAliveInterval: Inherited<Int> = .inherit,
                serverAliveCountMax: Inherited<Int> = .inherit,
                compression: Inherited<Bool> = .inherit,
                strictHostKeyChecking: Inherited<StrictHostKeyChecking> = .inherit,
                forwardAgent: Inherited<Bool> = .inherit,
                preferredAuthentications: Inherited<[AuthMethod]> = .inherit,
                mosh: Inherited<MoshConfig> = .inherit,
                tailscale: Inherited<TailscaleConfig> = .inherit,
                glymr: Inherited<GlymrConfig> = .inherit) {
        self.user = user; self.port = port
        self.identities = identities; self.passwordRef = passwordRef
        self.proxyJump = proxyJump
        self.localForwards = localForwards; self.remoteForwards = remoteForwards
        self.dynamicForwards = dynamicForwards
        self.serverAliveInterval = serverAliveInterval
        self.serverAliveCountMax = serverAliveCountMax
        self.compression = compression
        self.strictHostKeyChecking = strictHostKeyChecking
        self.forwardAgent = forwardAgent
        self.preferredAuthentications = preferredAuthentications
        self.mosh = mosh; self.tailscale = tailscale; self.glymr = glymr
    }
}
