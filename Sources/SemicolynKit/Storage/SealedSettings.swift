// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Fixed record ids for the single-record settings kept in the sealed record store
/// (`RecordType.settings`, privacy audit P-L1) instead of plain `UserDefaults`.
public enum SealedSettingID {
    /// `KeybarSettings`: the keybar layout and its library of macros and custom keys.
    public static let keybar = UUID(uuidString: "5E1C0001-0000-4000-8000-000000000001")!
    /// `LogServerSettings`: the diagnostics server address and pinned certificates.
    public static let logServer = UUID(uuidString: "5E1C0001-0000-4000-8000-000000000002")!
}

/// Reads the setting `id` from the sealed store, moving it there from `UserDefaults`
/// the first time (privacy audit P-L1).
///
/// - A stored record wins; any copy still in `UserDefaults` is then removed.
/// - Otherwise `legacy()` supplies the old `UserDefaults` value, which is sealed and
///   returned. Its keys are removed only after the sealed write succeeded, so a failed
///   write loses nothing and is retried on the next launch.
/// - A record that can't be opened counts as missing, so the legacy value (if any)
///   replaces it rather than the setting being stuck unreadable.
///
/// Returns nil when neither place has a value; the caller uses its default.
public func loadSealedSetting<T: Codable>(id: UUID, as: T.Type, records: EncryptedRecordStore,
                                          legacy: () -> T?, removeLegacy: () -> Void) -> T? {
    if let stored = (try? records.get(.settings, id: id, as: T.self)) ?? nil {
        removeLegacy()
        return stored
    }
    guard let old = legacy() else { return nil }
    if (try? records.put(old, type: .settings, id: id)) != nil {
        removeLegacy()
    }
    return old
}

/// Where the diagnostics stream goes (Settings → Diagnostics → Stream logs to a
/// server) and the certificate fingerprints pinned for each TLS server, keyed by
/// `remoteLogPinKey(host:port:)`. Sealed in the record store (privacy audit P-L1); the
/// on/off switches stay in `UserDefaults`.
public struct LogServerSettings: Codable, Equatable, Sendable {
    public static let defaultPort = 6514
    public static let defaultTransport: LogTransport = .tls

    public var host: String
    public var port: Int
    public var transport: LogTransport
    public var certPins: [String: String]

    public init(host: String = "", port: Int = defaultPort, transport: LogTransport = defaultTransport,
                certPins: [String: String] = [:]) {
        self.host = host
        self.port = port
        self.transport = transport
        self.certPins = certPins
    }

    /// The `UserDefaults` keys these settings lived under before P-L1.
    public enum LegacyKey {
        public static let host = "diagnostics.remoteLog.host"
        public static let port = "diagnostics.remoteLog.port"
        public static let transport = "diagnostics.remoteLog.transport"
        public static let certPins = "diagnostics.remoteLog.certPins"
        static let all = [host, port, transport, certPins]
    }

    /// The settings stored under the legacy keys, or nil when none of them is set.
    /// A missing or malformed key takes its default.
    public static func legacy(in defaults: UserDefaults) -> LogServerSettings? {
        guard LegacyKey.all.contains(where: { defaults.object(forKey: $0) != nil }) else { return nil }
        return LogServerSettings(
            host: defaults.string(forKey: LegacyKey.host) ?? "",
            port: defaults.object(forKey: LegacyKey.port) as? Int ?? defaultPort,
            transport: defaults.string(forKey: LegacyKey.transport).flatMap(LogTransport.init(rawValue:))
                ?? defaultTransport,
            certPins: defaults.dictionary(forKey: LegacyKey.certPins) as? [String: String] ?? [:])
    }

    /// Removes the legacy keys.
    public static func removeLegacy(from defaults: UserDefaults) {
        for key in LegacyKey.all { defaults.removeObject(forKey: key) }
    }
}

extension LogTransport: Codable {}
