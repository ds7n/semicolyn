// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SemicolynKit

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
    /// Mint/import + resolve SSH identities (publickey auth).
    let identities: IdentityService
    /// Terminal rendering preferences (font, cursor, scrollback).
    let terminalSettings = TerminalSettingsStore()
    /// User keybar customization (slot layout + reverse-bar direction), persisted.
    let keybarSettings = KeybarSettingsStore()
    /// User-selected theme id (Appearance), persisted. The root view resolves it
    /// through the Pro-gate and injects the result into `\.theme`.
    let appearance = ThemeSettingsStore()
    /// Pro entitlement (stub seam; real StoreKit is a later slice).
    let pro = ProStore()
    /// Base Application Support directory (`…/semicolyn/`). Retained so store
    /// factory methods can build sub-paths without repeating the FileManager call.
    private let baseDirectory: URL

    /// Initializes the storage stack: Application Support directory, Keychain
    /// secrets, AES record key, file-backed blob store, and trust evaluator.
    ///
    /// - Throws: `KeychainError` if Keychain operations fail, or `FileBlobStore`
    ///   errors if the Application Support directory cannot be created.
    init() throws {
        // Application Support directory: ~/.../Library/Application Support/semicolyn/
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("semicolyn", isDirectory: true)
        self.baseDirectory = dir

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

        // Identity service: mint/import + resolve SSH identities for publickey auth.
        // Constructed last so both `self.hosts` and `self.secrets` are already set.
        self.identities = IdentityService(store: self.hosts, secrets: secrets, minter: CoreIdentityMinter())
    }

    // MARK: - Predictor stores

    /// The on-device predictor learned-state store (per the predictor spec path).
    func predictorLearnedStore() -> LearnedStore {
        LearnedStore(directory: baseDirectory.appendingPathComponent("predictor", isDirectory: true))
    }

    /// Delete the persisted predictor learned store (panic-purge's disk half). The
    /// bundled seed is separate and untouched. A missing file is not an error.
    func purgePredictorLearned() throws {
        try predictorLearnedStore().delete()
    }

    /// The bundled/installed predictor seed, or nil if none is installed yet.
    func predictorSeed() -> PredictorSeed? {
        SeedStore(directory: baseDirectory.appendingPathComponent("predictor", isDirectory: true)).loadSeed()
    }

    // MARK: - Device seed

    /// Returns a stable per-install random seed, persisted in `UserDefaults`.
    ///
    /// No longer feeds the tmux session name — that is now the user-configurable
    /// `resolveTmuxSessionName` (builtin default `"semicolyn"`). Retained for a
    /// future 2b-ii CloudKit-account-bound derivation that may reuse this seed.
    ///
    /// - Returns: A UUID string that is stable for the lifetime of the app install.
    func deviceSeed() throws -> String {
        let key = "semicolyn.deviceSeed"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }
}
