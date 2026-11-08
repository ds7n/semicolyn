// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import UIKit
import SemicolynKit

/// UserDefaults keys for the remote diagnostics stream's switches. All developer-facing,
/// off by default. The server address and pinned certificates are in `LogServerStore`.
enum RemoteLogConfig {
    static let enabledKey = "diagnostics.remoteLog.enabled"
    static let keystrokeContentKey = "diagnostics.remoteLog.keystrokeContent"
}

/// The diagnostics server address and pinned certificates (`LogServerSettings`), sealed in
/// the encrypted record store rather than plain UserDefaults (privacy audit P-L1). The
/// first load moves any values still in UserDefaults across. Thread-safe: the sink's TLS
/// verify block reads and writes pins from its own queue, so it has its own record store
/// over the app's records directory instead of going through the main-actor `AppStores`.
final class LogServerStore: @unchecked Sendable {
    static let shared = LogServerStore()

    private let lock = NSLock()
    /// Nil while the record key couldn't be read; `reloadIfUnreadable` retries.
    private var records: EncryptedRecordStore?
    private var current = LogServerSettings()
    /// False while the stored settings couldn't be read (device locked at launch, or
    /// no record key yet): changes stay in memory and nothing is saved, so the
    /// defaults can't overwrite the real settings.
    private var canSave = false

    private init() {
        loadLocked()
    }

    /// The current settings.
    var settings: LogServerSettings { lock.withLock { current } }

    /// Applies `change` and seals the result.
    func update(_ change: (inout LogServerSettings) -> Void) {
        lock.withLock {
            change(&current)
            guard canSave else { return }
            try? records?.put(current, type: .settings, id: SealedSettingID.logServer)
        }
    }

    /// Pins `fingerprint` for `pinKey` unless something is pinned already, in one step
    /// (the first certificate seen wins). Returns whether it pinned.
    @discardableResult
    func pinIfUnpinned(_ fingerprint: String, for pinKey: String) -> Bool {
        var pinned = false
        update {
            guard $0.certPins[pinKey] == nil else { return }
            $0.certPins[pinKey] = fingerprint
            pinned = true
        }
        return pinned
    }

    /// Re-reads the store (after Erase All Data deleted it: back to the defaults).
    func reload() {
        lock.withLock { loadLocked() }
    }

    /// Retries a load that failed (device locked at launch). Called when the app
    /// becomes active.
    func reloadIfUnreadable() {
        lock.withLock {
            guard !canSave else { return }
            loadLocked()
        }
    }

    /// Loads into `current`. Caller holds `lock` (or is `init`).
    private func loadLocked() {
        if records == nil {
            records = try? EncryptedRecordStore(
                backend: FileBlobStore(directory: AppStores.recordsDirectory()),
                key: recordKey(in: KeychainSecretStore()))
        }
        guard let records else {
            canSave = false
            return
        }
        let defaults = UserDefaults.standard
        switch loadSealedSetting(id: SealedSettingID.logServer, as: LogServerSettings.self, records: records,
                                 legacy: { LogServerSettings.legacy(in: defaults) },
                                 removeLegacy: { LogServerSettings.removeLegacy(from: defaults) }) {
        case let .found(stored):
            current = stored
            canSave = true
        case .absent:
            current = LogServerSettings()
            canSave = true
        case .unreadable:
            current = LogServerSettings()
            canSave = false
        }
    }
}

/// Pinned TLS certificate fingerprints for diagnostics servers, keyed by
/// `remoteLogPinKey(host:port:)` (security audit M3). Kept in `LogServerStore`.
enum RemoteLogCertPins {
    static func pin(for pinKey: String) -> String? {
        LogServerStore.shared.settings.certPins[pinKey]
    }

    static func setPin(_ fingerprint: String, for pinKey: String) {
        LogServerStore.shared.update { $0.certPins[pinKey] = fingerprint }
    }

    static func forget(_ pinKey: String) {
        LogServerStore.shared.update { $0.certPins[pinKey] = nil }
    }
}

/// Asks the user, on top of whatever is on screen, whether to trust a diagnostics server
/// whose certificate no longer matches its pin. The sink refuses the connection first;
/// "Trust New Certificate" re-pins and reconnects. A certificate the user declined is not
/// asked about again until the app relaunches (the sink keeps retrying in the background).
@MainActor
enum RemoteLogCertPrompt {
    private static var declined: Set<String> = []

    /// Called from the sink's TLS queue.
    nonisolated static func report(pinKey: String, pinned: String, presented: String) {
        Task { @MainActor in present(pinKey: pinKey, pinned: pinned, presented: presented) }
    }

    private static func present(pinKey: String, pinned: String, presented: String) {
        // No "showing" flag to get stuck: skip while any alert is up, or while the top
        // controller can't present; the sink's next retry reports again.
        guard !declined.contains(presented), let top = topViewController(),
              !(top is UIAlertController), !top.isBeingDismissed,
              top.viewIfLoaded?.window != nil else { return }
        let alert = UIAlertController(
            title: "Log server certificate changed",
            message: "The diagnostics server \(pinKey) presented a different certificate.\n\n"
                + "Before: \(pinned)\nNow: \(presented)\n\n"
                + "If you didn't replace it, someone may be intercepting your logs. "
                + "Logs are not sent until you decide.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Don't Trust", style: .cancel) { _ in
            declined.insert(presented)
        })
        alert.addAction(UIAlertAction(title: "Trust New Certificate", style: .destructive) { _ in
            RemoteLogCertPins.setPin(presented, for: pinKey)
            // Accepting a different server is a redirect: keystroke content logging goes
            // off (re-enabling asks for Face ID). Security audit M3.
            UserDefaults.standard.set(false, forKey: RemoteLogConfig.keystrokeContentKey)
            DebugLog.shared.restartRemote(reason: "cert-trusted")
        })
        top.present(alert, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        var top = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
