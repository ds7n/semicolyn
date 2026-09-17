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

final class ResumableSessionStoreTests: XCTestCase {
    func testStorageSeamsExist() {
        XCTAssertEqual(RecordType.resumableSession.rawValue, "resumableSession")
        let id = UUID()
        XCTAssertEqual(SecretRef.resumeSecret(sessionID: id), SecretRef.resumeSecret(sessionID: id))
    }

    func testRecordRoundTripsThroughCodable() throws {
        let r = ResumableSession(sessionID: UUID(), hostID: UUID(), transport: .mosh,
                                 host: "server01.example.io", port: 60001,
                                 tmuxSessionName: "semicolyn", lastConnectedAt: Date(timeIntervalSince1970: 1_000))
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(ResumableSession.self, from: data)
        XCTAssertEqual(back, r)
        XCTAssertEqual(back.transport, .mosh)
        XCTAssertNil(ResumableSession(sessionID: UUID(), hostID: UUID(), transport: .ssh,
                                      host: "h", port: 22, tmuxSessionName: nil,
                                      lastConnectedAt: Date(timeIntervalSince1970: 0)).tmuxSessionName)
    }

    private func makeStore(hostIDs: Set<UUID>) -> ResumableSessionStore {
        let records = EncryptedRecordStore(backend: InMemoryBlobStore(), key: SymmetricKey(size: .bits256))
        let secrets = InMemorySecretStore()
        return ResumableSessionStore(records: records, secrets: secrets,
                                     hostExists: { hostIDs.contains($0) })
    }

    private func rec(_ t: Transport, host: UUID, at ts: TimeInterval) -> ResumableSession {
        ResumableSession(sessionID: UUID(), hostID: host, transport: t, host: "h", port: 1,
                         tmuxSessionName: nil, lastConnectedAt: Date(timeIntervalSince1970: ts))
    }

    func testUpsertAndAllRoundTrips() throws {
        let h = UUID(); let store = makeStore(hostIDs: [h])
        let r = rec(.mosh, host: h, at: 10)
        try store.upsert(r, secret: Data([1, 2, 3]))
        XCTAssertEqual(try store.all(), [r])
        XCTAssertTrue(store.hasSecret(sessionID: r.sessionID))
    }

    func testAllIsMostRecentFirst() throws {
        let h = UUID(); let store = makeStore(hostIDs: [h])
        let older = rec(.mosh, host: h, at: 10); let newer = rec(.et, host: h, at: 20)
        try store.upsert(older, secret: Data([1])); try store.upsert(newer, secret: Data([2]))
        XCTAssertEqual(try store.all().map(\.sessionID), [newer.sessionID, older.sessionID])
    }

    func testRemoveDropsRecordAndSecret() throws {
        let h = UUID(); let store = makeStore(hostIDs: [h])
        let r = rec(.et, host: h, at: 5); try store.upsert(r, secret: Data([9]))
        try store.remove(sessionID: r.sessionID)
        XCTAssertEqual(try store.all(), [])
        XCTAssertFalse(store.hasSecret(sessionID: r.sessionID))
    }

    func testReconcilePrunesSecretlessMoshRecord() throws {
        let h = UUID(); let store = makeStore(hostIDs: [h])
        let r = rec(.mosh, host: h, at: 5); try store.upsert(r, secret: nil)   // mosh needs a secret
        let pruned = try store.reconcile()
        XCTAssertEqual(pruned, [r.sessionID])
        XCTAssertEqual(try store.all(), [])
    }

    func testReconcilePrunesDeadHostRecord() throws {
        let h = UUID(); let dead = UUID(); let store = makeStore(hostIDs: [h])
        let r = rec(.et, host: dead, at: 5); try store.upsert(r, secret: Data([1]))
        XCTAssertEqual(try store.reconcile(), [r.sessionID])
        XCTAssertFalse(store.hasSecret(sessionID: r.sessionID))   // secret pruned too
    }

    func testReconcileKeepsRawRecordWithoutSecret() throws {
        let h = UUID(); let store = makeStore(hostIDs: [h])
        let r = rec(.ssh, host: h, at: 5); try store.upsert(r, secret: nil)   // raw needs no secret
        XCTAssertEqual(try store.reconcile(), [])
        XCTAssertEqual(try store.all(), [r])
    }
}
