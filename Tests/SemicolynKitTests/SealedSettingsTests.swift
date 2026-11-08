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

/// Privacy audit P-L1: keybar macros and the log server config move from plain
/// UserDefaults into the sealed record store.
final class SealedSettingsTests: XCTestCase {
    private let suite = "SealedSettingsTests"
    private var defaults: UserDefaults!
    private var backend: InMemoryBlobStore!
    private var records: EncryptedRecordStore!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        backend = InMemoryBlobStore()
        records = EncryptedRecordStore(backend: backend, key: SymmetricKey(size: .bits256))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func loadLogServer(_ store: EncryptedRecordStore? = nil) -> LogServerSettings? {
        loadSealedSetting(id: SealedSettingID.logServer, as: LogServerSettings.self,
                          records: store ?? records,
                          legacy: { LogServerSettings.legacy(in: defaults) },
                          removeLegacy: { LogServerSettings.removeLegacy(from: defaults) })
    }

    private func setLegacy() {
        defaults.set("logs.example.net", forKey: LogServerSettings.LegacyKey.host)
        defaults.set(1514, forKey: LogServerSettings.LegacyKey.port)
        defaults.set("tcp", forKey: LogServerSettings.LegacyKey.transport)
        defaults.set(["logs.example.net:6514": "AB:CD"], forKey: LogServerSettings.LegacyKey.certPins)
    }

    private let expected = LogServerSettings(host: "logs.example.net", port: 1514, transport: .tcp,
                                             certPins: ["logs.example.net:6514": "AB:CD"])

    // Nothing anywhere: nil, so the caller uses its default.
    func testNothingStoredIsNil() {
        XCTAssertNil(loadLogServer())
    }

    // First launch after the update: the legacy keys are sealed, then removed.
    func testLegacyMigratedSealedAndRemoved() throws {
        setLegacy()
        XCTAssertEqual(loadLogServer(), expected)
        XCTAssertEqual(try records.get(.settings, id: SealedSettingID.logServer, as: LogServerSettings.self),
                       expected)
        for key in [LogServerSettings.LegacyKey.host, LogServerSettings.LegacyKey.port,
                    LogServerSettings.LegacyKey.transport, LogServerSettings.LegacyKey.certPins] {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
    }

    // The sealed copy is ciphertext: the host name doesn't appear in the stored bytes.
    func testSealedBlobDoesNotContainPlaintext() throws {
        setLegacy()
        _ = loadLogServer()
        let blob = try XCTUnwrap(backend.getBlob(type: "settings", id: SealedSettingID.logServer))
        XCTAssertNil(blob.range(of: Data("logs.example.net".utf8)))
    }

    // A stored record wins over a stale legacy copy, which is then removed.
    func testStoredRecordWinsAndStaleLegacyRemoved() throws {
        let current = LogServerSettings(host: "new.example.net")
        try records.put(current, type: .settings, id: SealedSettingID.logServer)
        setLegacy()
        XCTAssertEqual(loadLogServer(), current)
        XCTAssertNil(defaults.object(forKey: LogServerSettings.LegacyKey.host))
    }

    // Adversarial: a record sealed with another key is treated as missing and replaced
    // by the legacy value instead of leaving the setting unreadable.
    func testUndecryptableRecordReplacedByLegacy() throws {
        let foreign = EncryptedRecordStore(backend: backend, key: SymmetricKey(size: .bits256))
        try foreign.put(LogServerSettings(host: "x"), type: .settings, id: SealedSettingID.logServer)
        setLegacy()
        XCTAssertEqual(loadLogServer(), expected)
        XCTAssertEqual(try records.get(.settings, id: SealedSettingID.logServer, as: LogServerSettings.self),
                       expected)
    }

    // A failed sealed write keeps the legacy keys, so nothing is lost and the move retries.
    func testFailedWriteKeepsLegacy() {
        struct ReadOnlyStore: BlobStore {
            struct Denied: Error {}
            func putBlob(_ data: Data, type: String, id: UUID) throws { throw Denied() }
            func getBlob(type: String, id: UUID) throws -> Data? { nil }
            func deleteBlob(type: String, id: UUID) throws {}
            func listBlobs(type: String) throws -> [(id: UUID, data: Data)] { [] }
        }
        setLegacy()
        let readOnly = EncryptedRecordStore(backend: ReadOnlyStore(), key: SymmetricKey(size: .bits256))
        XCTAssertEqual(loadLogServer(readOnly), expected)
        XCTAssertEqual(defaults.string(forKey: LogServerSettings.LegacyKey.host), "logs.example.net")
    }

    // Only some legacy keys set: the rest take their defaults; a bad transport too.
    func testPartialLegacyUsesDefaults() {
        defaults.set("h.example", forKey: LogServerSettings.LegacyKey.host)
        defaults.set("carrier-pigeon", forKey: LogServerSettings.LegacyKey.transport)
        XCTAssertEqual(LogServerSettings.legacy(in: defaults),
                       LogServerSettings(host: "h.example", port: 6514, transport: .tls, certPins: [:]))
    }

    // The keybar settings (with a macro) round-trip through the same path.
    func testKeybarSettingsMigrate() throws {
        var keybar = KeybarSettings.default
        keybar.library.upsertMacro(Macro(id: MacroID("m1"), name: "deploy", body: [MacroEvent(key: .char("d"))]))
        let legacyKey = "semicolyn.keybarSettings"
        defaults.set(try JSONEncoder().encode(keybar), forKey: legacyKey)

        let loaded = loadSealedSetting(
            id: SealedSettingID.keybar, as: KeybarSettings.self, records: records,
            legacy: { defaults.data(forKey: legacyKey).flatMap { try? JSONDecoder().decode(KeybarSettings.self, from: $0) } },
            removeLegacy: { defaults.removeObject(forKey: legacyKey) })

        XCTAssertEqual(loaded, keybar)
        XCTAssertNil(defaults.object(forKey: legacyKey))
    }
}
