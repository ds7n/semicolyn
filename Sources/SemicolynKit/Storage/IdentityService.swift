// Sources/SemicolynKit/Storage/IdentityService.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Key material produced by an `IdentityMinter`. Pure value type, the private
/// key is plumbed straight into the `SecretStore` and never logged or copied
/// elsewhere. Mirrors the Rust core's `KeyMaterial` UniFFI record.
public struct KeyMaterial: Equatable, Sendable {
    public let privateKeyOpenSSH: String
    public let publicKeyOpenSSH: String
    public let fingerprintSHA256: String
    public let algorithm: KeyAlgorithm
    public init(privateKeyOpenSSH: String, publicKeyOpenSSH: String,
                fingerprintSHA256: String, algorithm: KeyAlgorithm) {
        self.privateKeyOpenSSH = privateKeyOpenSSH
        self.publicKeyOpenSSH = publicKeyOpenSSH
        self.fingerprintSHA256 = fingerprintSHA256
        self.algorithm = algorithm
    }
}

/// Generates and parses SSH key material. The Linux-testable seam: `SemicolynKit`
/// holds only the protocol; the concrete `CoreIdentityMinter` (App target,
/// macOS) bridges to the Rust core.
public protocol IdentityMinter {
    /// Generate a fresh ed25519 keypair.
    func mintEd25519() throws -> KeyMaterial
    /// Parse an OpenSSH private key (optionally passphrase-protected), deriving
    /// its public key + fingerprint.
    func importPrivateKey(_ openssh: String, passphrase: String?) throws -> KeyMaterial
}

/// Errors surfaced when creating or importing an identity.
public enum IdentityServiceError: Error, Equatable {
    /// The minter failed (generation or parse/decrypt). Carries its description.
    case minting(String)
}

/// Errors surfaced when renaming or deleting a saved identity.
public enum IdentityEditError: Error, Equatable {
    /// The new display name is empty after trimming whitespace.
    case emptyName
    /// No identity record has the given id.
    case notFound
}

/// Mints/imports an identity and persists it: private key → `SecretStore`,
/// metadata → `HostStore`. The only place the two stores are written together,
/// so the "private key in Keychain, metadata in records" invariant holds in one
/// spot. Writes the secret first, then metadata; on a minter failure nothing is
/// written (the throw happens before any store call). If the metadata save fails
/// after the secret is written, the secret is rolled back so the two stores never
/// diverge, a private key will never remain in the secret store without a
/// corresponding identity record.
public struct IdentityService {
    private let store: HostStore
    private let secrets: SecretStore
    private let minter: IdentityMinter

    public init(store: HostStore, secrets: SecretStore, minter: IdentityMinter) {
        self.store = store
        self.secrets = secrets
        self.minter = minter
    }

    /// Generate a new iCloud-Keychain ed25519 identity.
    @discardableResult
    public func createGenerated(displayName: String, biometricPolicy: BiometricPolicy,
                                now: Date) throws -> Identity {
        let material: KeyMaterial
        do { material = try minter.mintEd25519() }
        catch { throw IdentityServiceError.minting("\(error)") }
        return try persist(material, displayName: displayName,
                           biometricPolicy: biometricPolicy, now: now)
    }

    /// Import an existing private key as an iCloud-Keychain identity.
    @discardableResult
    public func importIdentity(displayName: String, openssh: String, passphrase: String?,
                               biometricPolicy: BiometricPolicy, now: Date) throws -> Identity {
        let material: KeyMaterial
        do { material = try minter.importPrivateKey(openssh, passphrase: passphrase) }
        catch { throw IdentityServiceError.minting("\(error)") }
        return try persist(material, displayName: displayName,
                           biometricPolicy: biometricPolicy, now: now)
    }

    /// The stored OpenSSH private key for `identityID`, or `nil` if absent.
    public func privateKeyOpenSSH(for identityID: UUID) throws -> String? {
        guard let data = try secrets.getSecret(.privateKey(identityID: identityID)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Rename the identity to `newName` (trimmed). Only the display name changes:
    /// the key, its fingerprint and every host reference stay as they were.
    ///
    /// - Throws: `IdentityEditError.emptyName` for a blank name,
    ///   `IdentityEditError.notFound` when no identity has `identityID`.
    @discardableResult
    public func rename(identityID: UUID, to newName: String) throws -> Identity {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw IdentityEditError.emptyName }
        guard var identity = try store.identity(id: identityID) else { throw IdentityEditError.notFound }
        identity.displayName = name
        try store.saveIdentity(identity)
        return identity
    }

    /// Delete the identity everywhere: first every host and Defaults reference
    /// (`HostStore.deleteIdentityRemovingReferences`), then the record, then its
    /// private key and passphrase secrets. Returns the usage that was cleared.
    ///
    /// - Throws: `IdentityEditError.notFound` when no identity has `identityID`.
    @discardableResult
    public func deleteIdentity(id identityID: UUID) throws -> IdentityUsage {
        guard try store.identity(id: identityID) != nil else { throw IdentityEditError.notFound }
        let usage = try store.deleteIdentityRemovingReferences(id: identityID)
        try secrets.deleteSecret(.privateKey(identityID: identityID))
        try secrets.deleteSecret(.passphrase(identityID: identityID))
        return usage
    }

    /// Shared persistence: secret first, then metadata. Both keyed by a fresh UUID.
    private func persist(_ material: KeyMaterial, displayName: String,
                         biometricPolicy: BiometricPolicy, now: Date) throws -> Identity {
        let id = UUID()
        try secrets.setSecret(Data(material.privateKeyOpenSSH.utf8),
                              for: .privateKey(identityID: id))
        let identity = Identity(
            id: id, displayName: displayName, flavor: .iCloudKeychain,
            algorithm: material.algorithm, publicKey: material.publicKeyOpenSSH,
            fingerprint: material.fingerprintSHA256, createdAt: now,
            biometricPolicy: biometricPolicy)
        do {
            try store.saveIdentity(identity)
        } catch {
            // Never leave an orphaned private key with no identity record.
            try? secrets.deleteSecret(.privateKey(identityID: id))
            throw error
        }
        return identity
    }
}
