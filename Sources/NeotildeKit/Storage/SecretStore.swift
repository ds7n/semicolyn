// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Identifies a Keychain-bound secret. On Apple (Phase 2b) these map to iCloud
/// Keychain / Secure Enclave items via `SecAccessControl`; here the in-memory
/// backend keys on the ref directly. Secrets NEVER live in CloudKit/`BlobStore`.
public enum SecretRef: Hashable, Sendable {
    /// The 32-byte AES key that `EncryptedRecordStore` uses to seal records.
    case recordKey
    /// SSH private-key material for an identity (iCloudKeychain flavor).
    case privateKey(identityID: UUID)
    /// A stored host password (the target of `Host.passwordRef`).
    case password(id: UUID)
    /// An identity key's passphrase.
    case passphrase(identityID: UUID)
    /// Serialized `[HostKey]` (known_hosts) for a host — see `HostKeyStore`.
    case hostKeys(hostID: UUID)
}

/// Keychain-bound secret storage. The swappable seam Phase 2b fills with iCloud
/// Keychain + Secure Enclave; `InMemorySecretStore` backs tests.
public protocol SecretStore {
    /// Store `data` for `ref`, overwriting any existing secret.
    func setSecret(_ data: Data, for ref: SecretRef) throws
    /// The secret for `ref`, or `nil` if none exists.
    func getSecret(_ ref: SecretRef) throws -> Data?
    /// Remove the secret for `ref`. Idempotent.
    func deleteSecret(_ ref: SecretRef) throws
}

/// In-memory `SecretStore` for tests and previews. Not thread-safe.
public final class InMemorySecretStore: SecretStore {
    private var store: [SecretRef: Data] = [:]

    public init() {}

    public func setSecret(_ data: Data, for ref: SecretRef) throws { store[ref] = data }
    public func getSecret(_ ref: SecretRef) throws -> Data? { store[ref] }
    public func deleteSecret(_ ref: SecretRef) throws { store[ref] = nil }
}

/// The AES-256 record key from `store`, generating and persisting one on first
/// call. Stable across calls — the same key is returned for the life of the
/// store's `.recordKey` secret, so records sealed earlier stay openable.
public func recordKey(in store: SecretStore) throws -> SymmetricKey {
    if let data = try store.getSecret(.recordKey) {
        return SymmetricKey(data: data)
    }
    let key = SymmetricKey(size: .bits256)
    try store.setSecret(key.withUnsafeBytes { Data($0) }, for: .recordKey)
    return key
}
