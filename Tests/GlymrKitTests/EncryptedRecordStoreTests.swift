// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import GlymrKit

final class EncryptedRecordStoreTests: XCTestCase {
    private let key = SymmetricKey(size: .bits256)

    private func host() -> GlymrKit.Host {
        GlymrKit.Host(id: UUID(), label: "prod", hostName: "db.internal", user: .explicit("deploy"))
    }

    func testRoundTripAndList() throws {
        let backend = InMemoryBlobStore()
        let store = EncryptedRecordStore(backend: backend, key: key)
        let h = host()
        try store.put(h, type: .host, id: h.id)
        XCTAssertEqual(try store.get(.host, id: h.id, as: GlymrKit.Host.self), h)
        XCTAssertNil(try store.get(.host, id: UUID(), as: GlymrKit.Host.self))    // absent → nil
        XCTAssertEqual(try store.list(.host, as: GlymrKit.Host.self).map(\.value), [h])
        try store.delete(.host, id: h.id)
        XCTAssertNil(try store.get(.host, id: h.id, as: GlymrKit.Host.self))
    }

    func testBackendHoldsCiphertextNotPlaintext() throws {
        let backend = InMemoryBlobStore()
        let h = host()
        try EncryptedRecordStore(backend: backend, key: key).put(h, type: .host, id: h.id)
        let raw = try XCTUnwrap(try backend.getBlob(type: "host", id: h.id))
        // The raw blob must NOT be the plaintext JSON, and must NOT decode as a Host.
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("db.internal"))
        XCTAssertThrowsError(try JSONDecoder().decode(GlymrKit.Host.self, from: raw))
    }

    func testWrongKeyFails() throws {
        let backend = InMemoryBlobStore()
        let h = host()
        try EncryptedRecordStore(backend: backend, key: key).put(h, type: .host, id: h.id)
        let attacker = EncryptedRecordStore(backend: backend, key: SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try attacker.get(.host, id: h.id, as: GlymrKit.Host.self)) {
            XCTAssertEqual($0 as? RecordEnvelopeError, .decryptionFailed)
        }
    }

    func testTamperedBlobFails() throws {
        let backend = InMemoryBlobStore()
        let h = host()
        try EncryptedRecordStore(backend: backend, key: key).put(h, type: .host, id: h.id)
        var raw = try XCTUnwrap(try backend.getBlob(type: "host", id: h.id))
        raw[raw.count - 1] ^= 0xFF                                    // flip a tag byte
        try backend.putBlob(raw, type: "host", id: h.id)
        XCTAssertThrowsError(try EncryptedRecordStore(backend: backend, key: key)
            .get(.host, id: h.id, as: GlymrKit.Host.self)) {
            XCTAssertEqual($0 as? RecordEnvelopeError, .decryptionFailed)
        }
    }
}
