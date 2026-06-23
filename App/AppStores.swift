// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import GlymrKit

/// The app's composition root for the live storage stack: hosts via `HostStore`
/// (encrypted records on disk), host keys via `HostKeyStore` (Keychain), and
/// trust decisions via `HostKeyTrustEvaluator`. Singleton lifetime matches the app.
@MainActor
final class AppStores {
    /// Shared instance, initialized once at app startup via `try!`.
    static let shared = try! AppStores()

    let hosts: HostStore
    let hostKeys: HostKeyStore
    let trust: HostKeyTrustEvaluator
    /// The Keychain-backed secret store. Exposed so the host editor can persist
    /// and resolve host passwords via `SecretRef.password(id:)`.
    let secrets: SecretStore

    /// Initializes the storage stack: Application Support directory, Keychain
    /// secrets, AES record key, file-backed blob store, and trust evaluator.
    ///
    /// - Throws: `KeychainError` if Keychain operations fail, or `FileBlobStore`
    ///   errors if the Application Support directory cannot be created.
    init() throws {
        // Application Support directory: ~/.../Library/Application Support/glymr/
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("glymr", isDirectory: true)

        // Keychain-backed secrets (iCloud Keychain synced).
        let secrets = KeychainSecretStore()

        // Generate or retrieve the AES-256 record encryption key.
        let key = try recordKey(in: secrets)

        // File-backed blob store for encrypted host records.
        let blobs = FileBlobStore(directory: dir.appendingPathComponent("records"))

        // Encrypted record store wraps the blob store with AES-GCM sealing.
        self.hosts = HostStore(records: EncryptedRecordStore(backend: blobs, key: key))

        // Expose the secret store so the host editor can persist/resolve passwords.
        self.secrets = secrets

        // Host-key store for TOFU host-key tracking (Keychain-backed).
        self.hostKeys = HostKeyStore(secrets: secrets)

        // Trust evaluator for first-trust and key-rotation decisions.
        self.trust = HostKeyTrustEvaluator(store: hostKeys)
    }
}
