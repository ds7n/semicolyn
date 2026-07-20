// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SemicolynKit

/// A live session whose in-memory predictor engine can be reset by a panic-purge.
/// Kept minimal (one method) so `AppStores` holds only a weak, narrow reference to
/// the active session rather than the whole view-model. `ConnectionViewModel`
/// conforms; `AppStores.purgePredictorLearned()` calls it before the disk delete.
@MainActor
protocol PredictorPurgeable: AnyObject {
    /// Reset the running predictor engine to empty (seed preserved) so no stale
    /// learned state can be flushed back to disk after a purge.
    func purgeLearnedEngine()
}

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

        // Install the bundled predictor seed on first launch / version upgrade so
        // prediction works out of the box. Fail-soft: a missing/corrupt resource must
        // never break launch (degrades to learned-only, matching loadSeed's contract).
        // This is the app-edge glue Phase 4l deferred; its absence was device issue #3.
        installBundledSeedIfNeeded()
    }

    // MARK: - Predictor stores

    /// The on-device predictor learned-state store (per the predictor spec path).
    func predictorLearnedStore() -> LearnedStore {
        LearnedStore(directory: baseDirectory.appendingPathComponent("predictor", isDirectory: true))
    }

    /// The live session whose in-memory predictor engine must also be reset by a
    /// panic-purge. Weak so a torn-down session deregisters itself simply by
    /// deallocating; nil when no session is active (purge is then disk-only). Set on
    /// `startPredictor`, cleared on `teardown`.
    weak var activePredictorSession: (any PredictorPurgeable)?

    /// Panic-purge: wipe all user-derived predictor learned state. Resets the LIVE
    /// in-memory engine first (if a session is active) so no stale state can be
    /// flushed back, THEN deletes the on-disk store. Ordering matters: resetting the
    /// engine before the delete closes the stale-write-back window that a disk-only
    /// purge left open (a backgrounding session would otherwise re-flush the old
    /// learned state via `flushPredictor`). The bundled seed is separate and
    /// untouched; a missing file is not an error.
    func purgePredictorLearned() throws {
        activePredictorSession?.purgeLearnedEngine()
        try predictorLearnedStore().delete()
    }

    /// The bundled/installed predictor seed, or nil if none is installed yet.
    func predictorSeed() -> PredictorSeed? {
        SeedStore(directory: baseDirectory.appendingPathComponent("predictor", isDirectory: true)).loadSeed()
    }

    /// Read the bundled combined seed resource and install it via SeedStore
    /// (idempotent + self-healing). No-op if the resource is absent (dev builds
    /// without a committed seed) or unparseable. Never throws into launch.
    private func installBundledSeedIfNeeded() {
        guard let url = Bundle.main.url(forResource: "seed_v1", withExtension: "sketch"),
              let data = try? Data(contentsOf: url) else {
            DebugLog.shared.log(.seed, "seed:install skipped=no-resource")
            return
        }
        guard let bundled = BundledSeed(combinedBlob: [UInt8](data)) else {
            DebugLog.shared.log(.seed, "seed:install skipped=unparseable bytes=\(data.count)")
            return
        }
        let store = SeedStore(directory: baseDirectory.appendingPathComponent("predictor", isDirectory: true))
        do {
            let didInstall = try store.installIfNeeded(bundled)
            DebugLog.shared.log(.seed, "seed:install installed=\(didInstall) version=\(bundled.version)")
        } catch {
            DebugLog.shared.log(.seed, "seed:install failed error=\(error)")
        }
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
