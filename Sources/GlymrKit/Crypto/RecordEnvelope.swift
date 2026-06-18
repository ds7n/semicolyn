// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto   // Apple's swift-crypto — API-compatible on Linux
#endif

public enum RecordEnvelopeError: Error, Equatable {
    case decryptionFailed
}

/// Client-side AES-256-GCM seal/open for records written to CloudKit, so Apple
/// sees only ciphertext. The 32-byte key lives in iCloud Keychain (Phase 2).
public enum RecordEnvelope {
    /// JSON-encodes then seals `value` with AES-GCM, returning the combined
    /// nonce+ciphertext+tag blob.
    public static func seal<T: Encodable>(_ value: T, key: SymmetricKey) throws -> Data {
        let plaintext = try JSONEncoder().encode(value)
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else { throw RecordEnvelopeError.decryptionFailed }
        return combined
    }

    /// Opens a blob produced by `seal` and decodes it as `T`. Throws
    /// `decryptionFailed` if the key is wrong, the ciphertext was tampered with
    /// (GCM tag mismatch), or the blob is malformed (not a valid sealed box).
    public static func open<T: Decodable>(_ blob: Data, as type: T.Type,
                                          key: SymmetricKey) throws -> T {
        let plaintext: Data
        do {
            // SealedBox construction is inside the catch so a malformed blob
            // yields the typed `decryptionFailed`, not a raw CryptoKit error.
            let box = try AES.GCM.SealedBox(combined: blob)
            plaintext = try AES.GCM.open(box, using: key)
        } catch {
            throw RecordEnvelopeError.decryptionFailed
        }
        return try JSONDecoder().decode(T.self, from: plaintext)
    }
}
