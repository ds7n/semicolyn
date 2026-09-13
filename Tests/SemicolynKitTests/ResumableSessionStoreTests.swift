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

    // Issue B: the discovered tmux prefix byte round-trips so it can be replayed on a
    // state-resume reattach (where in-band re-discovery cannot run inside attached tmux).
    func testDiscoveredPrefixRoundTrips() throws {
        let r = ResumableSession(sessionID: UUID(), hostID: UUID(), transport: .mosh,
                                 host: "h", port: 60001, tmuxSessionName: "s",
                                 lastConnectedAt: Date(timeIntervalSince1970: 1), discoveredPrefix: 0x01)
        let back = try JSONDecoder().decode(ResumableSession.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back.discoveredPrefix, 0x01)
        XCTAssertEqual(back, r)
    }

    // Back-compat: a record persisted BEFORE this field existed (no `discoveredPrefix`
    // key in its JSON) must still decode, with the field nil (fall back to in-band probe).
    func testLegacyRecordWithoutPrefixDecodesAsNil() throws {
        let legacy = """
        {"sessionID":"\(UUID().uuidString)","hostID":"\(UUID().uuidString)",\
        "transport":"mosh","host":"h","port":60001,"tmuxSessionName":"s",\
        "lastConnectedAt":0}
        """.data(using: .utf8)!
        let back = try JSONDecoder().decode(ResumableSession.self, from: legacy)
        XCTAssertNil(back.discoveredPrefix)
    }

    // A raw-SSH or ET record simply carries no prefix; nil is the normal absence.
    func testDefaultDiscoveredPrefixIsNil() {
        let r = ResumableSession(sessionID: UUID(), hostID: UUID(), transport: .ssh,
                                 host: "h", port: 22, tmuxSessionName: nil,
                                 lastConnectedAt: Date(timeIntervalSince1970: 0))
        XCTAssertNil(r.discoveredPrefix)
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

    // Issue B: updating the discovered prefix rewrites the metadata but PRESERVES the
    // reconnect secret (they live in separate stores; a prefix update must not drop the
    // MOSH_KEY, else the reattach can't re-home at all).
    func testUpdateDiscoveredPrefixPreservesSecret() throws {
        let h = UUID(); let store = makeStore(hostIDs: [h])
        let r = rec(.mosh, host: h, at: 10)
        try store.upsert(r, secret: Data([7, 8, 9]))
        try store.updateDiscoveredPrefix(sessionID: r.sessionID, prefix: 0x01)
        let back = try XCTUnwrap(try store.all().first)
        XCTAssertEqual(back.discoveredPrefix, 0x01)
        XCTAssertEqual(store.secret(sessionID: r.sessionID), Data([7, 8, 9]))   // secret intact
        XCTAssertEqual(back.sessionID, r.sessionID)                             // same record
    }

    // Updating a prefix for a sessionID with no record is a silent no-op (the session may
    // have been cleared between suspend scheduling and the write).
    func testUpdateDiscoveredPrefixNoRecordIsNoOp() throws {
        let h = UUID(); let store = makeStore(hostIDs: [h])
        try store.updateDiscoveredPrefix(sessionID: UUID(), prefix: 0x01)
        XCTAssertEqual(try store.all(), [])
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
