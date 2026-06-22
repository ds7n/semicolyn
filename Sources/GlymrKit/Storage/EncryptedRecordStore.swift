// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The CloudKit-bound record kinds. The raw value is the `BlobStore` `type`
/// namespace; per the host-config-model storage backbone, these records are
/// AES-GCM ciphertext when written, so CloudKit/Apple sees only ciphertext.
public enum RecordType: String, Codable, Sendable, CaseIterable {
    case host
    case defaults
    case identity
}

/// Seals `Codable` records with `RecordEnvelope` (AES-256-GCM) over any
/// `BlobStore`. `put` encrypts before storing; `get`/`list` decrypt on read. A
/// present-but-undecryptable blob (wrong key or tampering) **throws**
/// `RecordEnvelopeError.decryptionFailed` — confidentiality/integrity failures
/// must surface, not be silently treated as "absent".
public struct EncryptedRecordStore {
    private let backend: BlobStore
    private let key: SymmetricKey

    public init(backend: BlobStore, key: SymmetricKey) {
        self.backend = backend
        self.key = key
    }

    public func put<T: Encodable>(_ value: T, type: RecordType, id: UUID) throws {
        let sealed = try RecordEnvelope.seal(value, key: key)
        try backend.putBlob(sealed, type: type.rawValue, id: id)
    }

    /// The decrypted record at `(type, id)`, or `nil` if no blob exists. Throws
    /// `RecordEnvelopeError.decryptionFailed` if a blob exists but cannot be
    /// opened with this key (tampered or wrong key).
    public func get<T: Decodable>(_ type: RecordType, id: UUID, as: T.Type) throws -> T? {
        guard let blob = try backend.getBlob(type: type.rawValue, id: id) else { return nil }
        return try RecordEnvelope.open(blob, as: T.self, key: key)
    }

    public func delete(_ type: RecordType, id: UUID) throws {
        try backend.deleteBlob(type: type.rawValue, id: id)
    }

    /// Every decrypted record of `type`. **Fail-closed:** if any one blob cannot
    /// be opened (wrong key or tampering), the whole call throws rather than
    /// silently dropping that record. This is deliberate for v1's security-first
    /// posture — a tampered host record must surface loudly, not vanish from a
    /// scan (which would also hide its jump-chain/identity references). The
    /// trade-off is availability: one corrupt record fails bulk reads until a
    /// repair path exists (a Phase 2b concern, alongside CloudKit sync/recovery).
    public func list<T: Decodable>(_ type: RecordType, as: T.Type) throws -> [(id: UUID, value: T)] {
        try backend.listBlobs(type: type.rawValue).map { entry in
            (id: entry.id, value: try RecordEnvelope.open(entry.data, as: T.self, key: key))
        }
    }
}
