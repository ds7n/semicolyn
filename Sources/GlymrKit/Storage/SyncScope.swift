// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Where a stored item lives and how it is protected — the storage backbone from
/// the host-config-model / iCloud-sync-scope specs.
public enum SyncBackend: Equatable, Sendable {
    /// CloudKit Private DB, client-side AES-256-GCM. Syncs across Apple devices.
    case cloudKitAES
    /// iCloud Keychain. End-to-end encrypted by Apple; syncs.
    case iCloudKeychain
    /// Secure Enclave. Hardware-bound; never leaves the device; does not sync.
    case secureEnclave
    /// Local file storage only. Never syncs.
    case localOnly
}

/// The authoritative v1 sync decision per item the storage core knows about.
/// Items the storage core does not yet model (macro library, keybar
/// customizations, predictor sketches) are owned by other phases.
public enum SyncItem: CaseIterable, Sendable {
    case hostRecord, defaultsRecord, identityMetadata          // CloudKit + AES
    case privateKeyICloud, password, passphrase, knownHosts    // iCloud Keychain
    case privateKeySE                                          // Secure Enclave
    case recentConnections, liveSessionState                   // local only

    public var backend: SyncBackend {
        switch self {
        case .hostRecord, .defaultsRecord, .identityMetadata: return .cloudKitAES
        case .privateKeyICloud, .password, .passphrase, .knownHosts: return .iCloudKeychain
        case .privateKeySE: return .secureEnclave
        case .recentConnections, .liveSessionState: return .localOnly
        }
    }

    /// Whether this item syncs across the user's Apple devices. Everything but
    /// Secure-Enclave (device-bound) and local-only items syncs.
    public var syncs: Bool {
        switch backend {
        case .cloudKitAES, .iCloudKeychain: return true
        case .secureEnclave, .localOnly: return false
        }
    }
}

/// Reserved Pro-tier compliance audit log — **dropped from v1**. The namespace
/// and emission hook are reserved (per iCloud-sync-scope) so a future Pro
/// feature can turn them on without retroactive instrumentation. `record` is a
/// no-op in v1: it writes nowhere and allocates nothing (the `@autoclosure`
/// argument is never evaluated).
public enum AuditLog {
    /// Reserved CloudKit / local-storage namespace for the future log.
    public static let reservedNamespace = "auditLog"

    /// No-op event emission hook. Reserved for the future Pro audit log.
    public static func record(_ event: @autoclosure () -> String) {
        // Intentionally empty in v1. See 2026-06-16-icloud-sync-scope-design.md.
    }
}
