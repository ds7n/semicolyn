// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public typealias IdentityRef = UUID

public enum IdentityFlavor: String, Codable, Equatable, Sendable {
    case iCloudKeychain
    case secureEnclave
}

public enum KeyAlgorithm: String, Codable, Equatable, Sendable {
    case ed25519, ecdsaP256 = "ecdsa-p256", ecdsaP384 = "ecdsa-p384", rsa
}

public enum BiometricPolicy: String, Codable, Equatable, Sendable {
    case never, anyUse, afterUnlock

    /// The policy a new or imported key starts with. The phone unlock is the gate; Face ID
    /// is an opt-in extra per key (decision log, security posture).
    public static let newKeyDefault: BiometricPolicy = .never
}

public struct Identity: Codable, Equatable, Sendable {
    public let id: UUID
    public var displayName: String
    public var flavor: IdentityFlavor
    public var algorithm: KeyAlgorithm
    public var publicKey: String
    public var fingerprint: String          // SHA256:base64
    public var createdAt: Date
    public var biometricPolicy: BiometricPolicy

    public init(id: UUID, displayName: String, flavor: IdentityFlavor,
                algorithm: KeyAlgorithm, publicKey: String, fingerprint: String,
                createdAt: Date, biometricPolicy: BiometricPolicy) {
        self.id = id; self.displayName = displayName; self.flavor = flavor
        self.algorithm = algorithm; self.publicKey = publicKey
        self.fingerprint = fingerprint; self.createdAt = createdAt
        self.biometricPolicy = biometricPolicy
    }
}
