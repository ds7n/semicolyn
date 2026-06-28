// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// `known_hosts` storage, keyed by host UUID, over a `SecretStore` (entries live
/// in iCloud Keychain — synced and E2EE — per the host-config-model storage
/// backbone). Multiple entries per host are supported so a rotation window can
/// hold the old and new key as both valid. Entries serialize as JSON `[HostKey]`
/// under `SecretRef.hostKeys(hostID:)`.
public struct HostKeyStore {
    private let secrets: SecretStore

    public init(secrets: SecretStore) {
        self.secrets = secrets
    }

    /// All trusted host-key entries for `hostID`, in insertion order; `[]` if none.
    public func entries(forHost hostID: UUID) throws -> [HostKey] {
        guard let data = try secrets.getSecret(.hostKeys(hostID: hostID)) else { return [] }
        return try JSONDecoder().decode([HostKey].self, from: data)
    }

    /// Append `key` to `hostID`'s entries, preserving any existing ones.
    public func add(_ key: HostKey, forHost hostID: UUID) throws {
        var all = try entries(forHost: hostID)
        all.append(key)
        try persist(all, forHost: hostID)
    }

    /// Remove every entry for `hostID` matching `fingerprint`. When no entries
    /// remain, the underlying secret is deleted rather than left as an empty array.
    public func remove(fingerprint: String, forHost hostID: UUID) throws {
        let remaining = try entries(forHost: hostID).filter { $0.fingerprint != fingerprint }
        if remaining.isEmpty {
            try secrets.deleteSecret(.hostKeys(hostID: hostID))
        } else {
            try persist(remaining, forHost: hostID)
        }
    }

    private func persist(_ entries: [HostKey], forHost hostID: UUID) throws {
        try secrets.setSecret(JSONEncoder().encode(entries), for: .hostKeys(hostID: hostID))
    }
}
