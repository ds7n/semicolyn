// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Persists the latest serialized mosh transport-state blob per session, so a
/// reattach can replay it into `mosh_main` and re-home to the live server at the
/// correct sequence (instead of an empty-state re-home the server silently drops).
///
/// The blob is SENSITIVE (crypto sequence + screen contents), so it lives in the
/// `EncryptedRecordStore` (AES-256-GCM, device-local) alongside the resume record,
/// keyed separately from the MOSH_KEY secret (which stays in the Keychain).
public struct MoshStateBlobStore {
    private let records: EncryptedRecordStore

    public init(records: EncryptedRecordStore) {
        self.records = records
    }

    /// Store (overwriting) the latest state blob for a session.
    public func put(_ blob: Data, sessionID: UUID) throws {
        try records.put(blob, type: .moshState, id: sessionID)
    }

    /// The most recently stored blob for a session, or nil if none.
    public func get(sessionID: UUID) throws -> Data? {
        try records.get(.moshState, id: sessionID, as: Data.self)
    }

    /// Remove a session's blob (call after a successful resume: it is now stale).
    public func clear(sessionID: UUID) throws {
        try records.delete(.moshState, id: sessionID)
    }
}
