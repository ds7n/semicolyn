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
}
public struct RemoteForward: Codable, Equatable, Sendable {
    public var bindAddress: String?; public var bindPort: Int
    public var hostAddress: String; public var hostPort: Int
}
public struct DynamicForward: Codable, Equatable, Sendable {
    public var bindAddress: String?; public var bindPort: Int
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

    // OpenSSH Tier 1 (subset modeled in Phase 0; remaining fields follow the
    // identical Inherited<T> pattern and are added as later phases consume them).
    public var user: Inherited<String>
    public var port: Inherited<Int>
    public var identities: Inherited<[IdentityRef]>
    public var proxyJump: Inherited<[JumpHop]>

    public init(id: UUID, label: String, hostName: String,
                user: Inherited<String> = .inherit,
                port: Inherited<Int> = .inherit,
                identities: Inherited<[IdentityRef]> = .inherit,
                proxyJump: Inherited<[JumpHop]> = .inherit) {
        self.id = id; self.label = label; self.hostName = hostName
        self.user = user; self.port = port
        self.identities = identities; self.proxyJump = proxyJump
    }

    /// The resolved jump chain (empty when inherited/unset for cycle-checking).
    public var resolvedJumpChain: [JumpHop] { proxyJump.value ?? [] }
}

/// Singleton defaults record: same optional fields as Host, no required ones.
public struct Defaults: Codable, Equatable, Sendable {
    public var user: Inherited<String>
    public var port: Inherited<Int>
    public init(user: Inherited<String> = .inherit,
                port: Inherited<Int> = .inherit) {
        self.user = user; self.port = port
    }
}
