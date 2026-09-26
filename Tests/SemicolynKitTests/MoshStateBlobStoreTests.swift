// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import Crypto
@testable import SemicolynKit

final class MoshStateBlobStoreTests: XCTestCase {
    private let key = SymmetricKey(size: .bits256)

    private func makeStore() -> MoshStateBlobStore {
        MoshStateBlobStore(records: EncryptedRecordStore(backend: InMemoryBlobStore(), key: key))
    }

    // Round-trip: a stored blob reads back byte-identical.
    func testPutGetRoundTrip() throws {
        let store = makeStore()
        let id = UUID()
        let blob = Data([0x01, 0x02, 0xFF, 0x00, 0x42])
        try store.put(blob, sessionID: id)
        XCTAssertEqual(try store.get(sessionID: id), blob)
    }

    // Missing key returns nil (absent result, not an error).
    func testGetMissingReturnsNil() throws {
        let store = makeStore()
        XCTAssertNil(try store.get(sessionID: UUID()))
    }

    // Overwrite-latest: a second put for the same sessionID replaces the first.
    func testPutOverwritesLatest() throws {
        let store = makeStore()
        let id = UUID()
        try store.put(Data([0xAA]), sessionID: id)
        try store.put(Data([0xBB, 0xCC]), sessionID: id)
        XCTAssertEqual(try store.get(sessionID: id), Data([0xBB, 0xCC]))
    }

    // Clear removes the blob; a subsequent get returns nil.
    func testClearRemovesBlob() throws {
        let store = makeStore()
        let id = UUID()
        try store.put(Data([0x01]), sessionID: id)
        try store.clear(sessionID: id)
        XCTAssertNil(try store.get(sessionID: id))
    }

    // Blobs are per-sessionID: one session's blob does not leak into another.
    func testBlobsAreKeyedBySession() throws {
        let store = makeStore()
        let a = UUID(); let b = UUID()
        try store.put(Data([0x11]), sessionID: a)
        XCTAssertNil(try store.get(sessionID: b))
        XCTAssertEqual(try store.get(sessionID: a), Data([0x11]))
    }
}
