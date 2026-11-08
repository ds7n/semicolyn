// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import SemicolynKit

/// Privacy audit P-M2: a saved Mosh screen snapshot never outlives its session record.
final class MoshStateCleanupTests: XCTestCase {
    private var records: EncryptedRecordStore!
    private var mosh: MoshStateBlobStore!
    private let liveHost = UUID()

    override func setUp() {
        super.setUp()
        records = EncryptedRecordStore(backend: InMemoryBlobStore(), key: SymmetricKey(size: .bits256))
        mosh = MoshStateBlobStore(records: records)
    }

    private func makeStore() -> ResumableSessionStore {
        let host = liveHost
        return ResumableSessionStore(records: records, secrets: InMemorySecretStore(),
                                     hostExists: { $0 == host })
    }

    private func session(host: UUID) -> ResumableSession {
        ResumableSession(sessionID: UUID(), hostID: host, transport: .mosh, host: "h", port: 60001,
                         tmuxSessionName: nil, lastConnectedAt: Date(timeIntervalSince1970: 1))
    }

    // Removing a session deletes its snapshot, and only its snapshot.
    func testRemoveClearsOnlyThatSessionsMoshState() throws {
        let store = makeStore()
        let a = session(host: liveHost), b = session(host: liveHost)
        try store.upsert(a, secret: Data([1])); try store.upsert(b, secret: Data([2]))
        try mosh.put(Data([0xA]), sessionID: a.sessionID)
        try mosh.put(Data([0xB]), sessionID: b.sessionID)

        try store.remove(sessionID: a.sessionID)

        XCTAssertNil(try mosh.get(sessionID: a.sessionID))
        XCTAssertEqual(try mosh.get(sessionID: b.sessionID), Data([0xB]))
    }

    // A session pruned for a deleted host takes its snapshot with it.
    func testReconcilePrunedSessionLosesMoshState() throws {
        let store = makeStore()
        let dead = session(host: UUID())
        try store.upsert(dead, secret: Data([1]))
        try mosh.put(Data([0xD]), sessionID: dead.sessionID)

        XCTAssertEqual(try store.reconcile(), [dead.sessionID])
        XCTAssertNil(try mosh.get(sessionID: dead.sessionID))
    }

    // The launch sweep deletes snapshots with no session record and keeps live ones.
    func testReconcileSweepsOrphanMoshStateKeepsLive() throws {
        let store = makeStore()
        let live = session(host: liveHost)
        try store.upsert(live, secret: Data([1]))
        try mosh.put(Data([0x1]), sessionID: live.sessionID)
        let orphan = UUID()
        try mosh.put(Data([0x2]), sessionID: orphan)

        XCTAssertEqual(try store.reconcile(), [])
        XCTAssertEqual(try mosh.get(sessionID: live.sessionID), Data([0x1]))
        XCTAssertNil(try mosh.get(sessionID: orphan))
        XCTAssertEqual(try records.ids(.moshState), [live.sessionID])
    }

    // Adversarial: an orphan that can't be decrypted (another key) is still swept,
    // because the sweep lists ids without opening the records.
    func testSweepRemovesUndecryptableOrphan() throws {
        let backend = InMemoryBlobStore()
        records = EncryptedRecordStore(backend: backend, key: SymmetricKey(size: .bits256))
        let foreign = EncryptedRecordStore(backend: backend, key: SymmetricKey(size: .bits256))
        let orphan = UUID()
        try foreign.put(Data([0x9]), type: .moshState, id: orphan)

        try makeStore().reconcile()

        XCTAssertEqual(try records.ids(.moshState), [])
    }

    // Adversarial: a session record that can't be opened makes pruning fail, but the
    // sweep still runs: the orphan goes, that session's own snapshot stays, and the
    // pruning error still surfaces.
    func testSweepRunsWhenPruningFails() throws {
        let backend = InMemoryBlobStore()
        records = EncryptedRecordStore(backend: backend, key: SymmetricKey(size: .bits256))
        mosh = MoshStateBlobStore(records: records)
        let foreign = EncryptedRecordStore(backend: backend, key: SymmetricKey(size: .bits256))
        let unreadable = session(host: liveHost)
        try foreign.put(unreadable, type: .resumableSession, id: unreadable.sessionID)
        try mosh.put(Data([0x1]), sessionID: unreadable.sessionID)
        let orphan = UUID()
        try mosh.put(Data([0x2]), sessionID: orphan)

        XCTAssertThrowsError(try makeStore().reconcile()) { error in
            XCTAssertEqual(error as? RecordEnvelopeError, .decryptionFailed)
        }
        XCTAssertEqual(try records.ids(.moshState), [unreadable.sessionID])
    }

    // Excluding a type creates its directory (so files written later land inside it)
    // and leaves the store working.
    func testExcludeFromBackupCreatesDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("excl-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let blobs = FileBlobStore(directory: dir)

        try blobs.excludeFromBackup(type: "moshState")

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("moshState").path,
                                                     isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        #if canImport(Darwin)
        let flagged = try dir.appendingPathComponent("moshState")
            .resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(flagged, true)
        #endif
        let id = UUID()
        try blobs.putBlob(Data([7]), type: "moshState", id: id)
        XCTAssertEqual(try blobs.getBlob(type: "moshState", id: id), Data([7]))
    }
}
