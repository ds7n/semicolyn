// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Ties the two persistence tiers together: non-secret `ResumableSession` metadata
/// in `EncryptedRecordStore` (RecordType.resumableSession) + the reconnect secret in
/// the Keychain-backed `SecretStore` (SecretRef.resumeSecret). The reconnect logic
/// talks only to this; it never touches Keychain/blob APIs directly.
public struct ResumableSessionStore {
    private let records: EncryptedRecordStore
    private let secrets: SecretStore
    private let hostExists: @Sendable (UUID) -> Bool

    public init(records: EncryptedRecordStore, secrets: SecretStore,
                hostExists: @escaping @Sendable (UUID) -> Bool) {
        self.records = records
        self.secrets = secrets
        self.hostExists = hostExists
    }

    /// Write metadata FIRST, then the secret, so a crash never leaves a secret with
    /// no owning record (at worst a record with no secret, which `reconcile` prunes).
    public func upsert(_ record: ResumableSession, secret: Data?) throws {
        try records.put(record, type: .resumableSession, id: record.sessionID)
        if let secret {
            try secrets.setSecret(secret, for: .resumeSecret(sessionID: record.sessionID))
        }
    }

    /// Remove a record and its secret slot. Idempotent.
    public func remove(sessionID: UUID) throws {
        try records.delete(.resumableSession, id: sessionID)
        try secrets.deleteSecret(.resumeSecret(sessionID: sessionID))
    }

    /// All records, most-recent first (by `lastConnectedAt`).
    public func all() throws -> [ResumableSession] {
        let rows = try records.list(.resumableSession, as: ResumableSession.self)
        return rows.map(\.value).sorted { $0.lastConnectedAt > $1.lastConnectedAt }
    }

    /// Whether a secret exists for this session (drives the cold-path decision).
    public func hasSecret(sessionID: UUID) -> Bool {
        guard let result = try? secrets.getSecret(.resumeSecret(sessionID: sessionID)) else {
            return false
        }
        return result != nil
    }

    /// The reconnect secret for `sessionID`, or nil (absent or unreadable). Read by
    /// the cold-reattach executor to rebuild the Mosh/ET transport. The reconnect
    /// logic gets the secret ONLY through this chokepoint, never from Keychain APIs.
    public func secret(sessionID: UUID) -> Data? {
        (try? secrets.getSecret(.resumeSecret(sessionID: sessionID))) ?? nil
    }

    /// Prune orphans: a record whose transport needs a secret but has none, OR whose
    /// hostID no longer resolves. Returns the pruned sessionIDs. Also deletes any
    /// secret slot belonging to a pruned record (via `remove`).
    @discardableResult
    public func reconcile() throws -> [UUID] {
        var pruned: [UUID] = []
        for record in try all() {
            let deadHost = !hostExists(record.hostID)
            let needsSecret = record.transport == .mosh || record.transport == .et
            let missingSecret = needsSecret && !hasSecret(sessionID: record.sessionID)
            guard deadHost || missingSecret else { continue }
            try remove(sessionID: record.sessionID)
            pruned.append(record.sessionID)
        }
        return pruned
    }
}
