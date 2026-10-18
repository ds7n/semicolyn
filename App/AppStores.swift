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
    /// Two-tier connection-resume store: non-secret `ResumableSession` metadata in
    /// `EncryptedRecordStore` + the reconnect secret in the Keychain. Held under the
    /// same `@MainActor` confinement as the other stores (it is not `Sendable`, its
    /// deps aren't). The App-side `ResumeCoordinator` wraps it.
    let resumableSessions: ResumableSessionStore
    /// The `EncryptedRecordStore` backing `resumableSessions` (same blob backend +
    /// record key). Held so `moshState` can share the identical instance rather than
    /// re-deriving a second store over the same key.
    private let encryptedRecords: EncryptedRecordStore
    /// Terminal rendering preferences (font, cursor, scrollback).
    let terminalSettings = TerminalSettingsStore()
    /// User keybar customization (three-region slot layout + library), persisted.
    let keybarSettings = KeybarSettingsStore()
    /// User-selected theme id (Appearance), persisted. The root view resolves it
    /// through the Pro-gate and injects the result into `\.theme`.
    let appearance = ThemeSettingsStore()
    /// Pro entitlement (stub seam; real StoreKit is a later slice).
    let pro = ProStore()
    /// App-side connection-resume orchestrator over `resumableSessions`. Shared so the
    /// capture edge (`ConnectionViewModel`), the launch-resume flow (`HostListView`),
    /// and the banner/prompt (`SessionView`) all read/write one store.
    private(set) lazy var resume = ResumeCoordinator(store: resumableSessions)
    /// Encrypted, device-local store for the latest mosh transport-state blob per
    /// session (crypto seq + screen). Shares the record store + key with `resume`.
    private(set) lazy var moshState = MoshStateBlobStore(records: encryptedRecords)
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

        // Connection-resume store: a SEPARATE `EncryptedRecordStore` over the SAME
        // blob store + record key as `hosts` (the record TYPE, not the store, keys the
        // namespace, so reusing blobs+key is safe and correct). `hostExists` resolves a
        // saved-host UUID at reconcile time. It is `@Sendable`, but `reconcile()` is
        // only ever invoked synchronously on the main actor (via
        // `ResumeCoordinator.resumeOnLaunch`), so reading the main-actor-confined
        // `HostStore` under `MainActor.assumeIsolated` is concurrency-correct here
        // (the alternative, snapshotting host IDs at construction, is WRONG: the host
        // library changes over the app's lifetime, so a stale snapshot would keep
        // orphaned records or prune live ones). `AppStores.shared` is read (not the
        // still-initializing `self`) so the closure never captures a partially-built
        // instance; by the time `reconcile()` runs, `shared` is fully assigned.
        // Resume reconnect secrets get a SEPARATE, NON-synchronizable Keychain store:
        // the spec ("Two-tier storage") requires the ephemeral per-session Mosh/ET
        // reattach key to be `AfterFirstUnlock` AND NOT iCloud-synced (it is device-
        // local roaming state, not a credential to fan out across the user's devices).
        // The main `secrets` store stays synchronizable (identities/hosts/passwords ride
        // iCloud Keychain). `resumeSecret/<uuid>` accounts live in a distinct item space
        // (sync vs non-sync are separate query domains), so there is no collision.
        let resumeSecrets = KeychainSecretStore(synchronizable: false)
        self.encryptedRecords = EncryptedRecordStore(backend: blobs, key: key)
        self.resumableSessions = ResumableSessionStore(
            records: encryptedRecords,
            secrets: resumeSecrets,
            hostExists: { hostID in
                MainActor.assumeIsolated {
                    ((try? AppStores.shared.hosts.host(id: hostID)) ?? nil) != nil
                }
            })

        // The single-ranker predictor reads the shipped dictionaries directly from the
        // bundle (`englishDictionary()` / `commandTree()`), so the copies the old seeds
        // installed under Application Support are dead weight: delete them.
        removeLegacySeedInstalls()
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

    /// Delete the installed copies of the retired seeds: `predictor/seed_pinned.sketch`
    /// (the learned store beside it is untouched) and the whole `predictor-prose/`
    /// directory. Missing paths are skipped, so after the first launch this is a no-op.
    /// Never throws into launch.
    private func removeLegacySeedInstalls() {
        let legacy = [
            baseDirectory.appendingPathComponent("predictor", isDirectory: true)
                .appendingPathComponent("seed_pinned.sketch"),
            baseDirectory.appendingPathComponent("predictor-prose", isDirectory: true),
        ]
        let fm = FileManager.default
        for url in legacy where fm.fileExists(atPath: url.path) {
            do {
                try fm.removeItem(at: url)
                DebugLog.shared.log(.seed, "seed:legacy removed=\(url.lastPathComponent)")
            } catch {
                DebugLog.shared.log(.seed, "seed:legacy remove-failed=\(url.lastPathComponent) error=\(error)")
            }
        }
    }

    /// The shipped English dictionary (`english_v2.bin`), loaded once and cached. Nil
    /// when the resource is absent or fails to parse; the predictor then works from
    /// learned words, the command tree and screen words.
    func englishDictionary() -> WordDictionary? { cachedEnglish }

    /// The shipped command tree (`commands_v2.bin`), loaded once and cached. Nil when
    /// the resource is absent or fails to parse.
    func commandTree() -> CommandTree? { cachedCommands }

    private lazy var cachedEnglish: WordDictionary? = {
        guard let data = AppStores.mappedResource("english_v2", "bin") else {
            DebugLog.shared.log(.seed, "dict:load english skipped=no-resource")
            return nil
        }
        guard let dict = WordDictionary(deserializing: [UInt8](data)) else {
            DebugLog.shared.log(.seed, "dict:load english skipped=unparseable bytes=\(data.count)")
            return nil
        }
        DebugLog.shared.log(.seed, "dict:load english words=\(dict.wordCount) bytes=\(data.count)")
        return dict
    }()

    private lazy var cachedCommands: CommandTree? = {
        guard let data = AppStores.mappedResource("commands_v2", "bin") else {
            DebugLog.shared.log(.seed, "dict:load commands skipped=no-resource")
            return nil
        }
        guard let tree = CommandTree(deserializing: [UInt8](data)) else {
            DebugLog.shared.log(.seed, "dict:load commands skipped=unparseable bytes=\(data.count)")
            return nil
        }
        DebugLog.shared.log(.seed, "dict:load commands tools=\(tree.toolCount) bytes=\(data.count)")
        return tree
    }()

    /// A bundled resource memory-mapped, or nil when it is absent or unreadable.
    private static func mappedResource(_ name: String, _ ext: String) -> Data? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { return nil }
        return try? Data(contentsOf: url, options: .alwaysMapped)
    }

    /// The runtime `TokenFilter` the predictor is constructed with: the default
    /// exclude patterns plus a `.blocklist` loaded from the bundled profanity word
    /// list, so profanity the user types is never learned or suggested back.
    /// Graceful: if the resource is missing or unreadable, returns the plain
    /// default filter (no blocklist) so the app behaves exactly as it did before
    /// this resource existed. Never crashes, never force-unwraps.
    func predictorTokenFilter() -> TokenFilter {
        guard let url = Bundle.main.url(forResource: "profanity_blocklist", withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            DebugLog.shared.log(.seed, "predictor:blocklist skipped=no-resource")
            return TokenFilter()
        }
        let words = Set(
            contents
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        DebugLog.shared.log(.seed, "predictor:blocklist loaded words=\(words.count)")
        return TokenFilter(patterns: TokenFilter.defaultPatterns + [.blocklist(words)])
    }

    // MARK: - Device seed

    /// Returns a stable per-install random seed, persisted in `UserDefaults`.
    ///
    /// No longer feeds the tmux session name, that is now the user-configurable
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
