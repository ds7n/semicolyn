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

    private enum Outcome: Equatable {
        case found(LogServerSettings), absent, unreadable
    }

    private func loadLogServer(_ store: EncryptedRecordStore? = nil) -> Outcome {
        switch loadSealedSetting(id: SealedSettingID.logServer, as: LogServerSettings.self,
                                 records: store ?? records,
                                 legacy: { LogServerSettings.legacy(in: defaults) },
                                 removeLegacy: { LogServerSettings.removeLegacy(from: defaults) }) {
        case let .found(value): return .found(value)
        case .absent: return .absent
        case .unreadable: return .unreadable
        }
    }

    private func setLegacy() {
        defaults.set("logs.example.net", forKey: LogServerSettings.LegacyKey.host)
        defaults.set(1514, forKey: LogServerSettings.LegacyKey.port)
        defaults.set("tcp", forKey: LogServerSettings.LegacyKey.transport)
        defaults.set(["logs.example.net:6514": "AB:CD"], forKey: LogServerSettings.LegacyKey.certPins)
    }

    private let expected = LogServerSettings(host: "logs.example.net", port: 1514, transport: .tcp,
                                             certPins: ["logs.example.net:6514": "AB:CD"])

    // Nothing anywhere: absent, so the caller uses (and may save) its default.
    func testNothingStoredIsAbsent() {
        XCTAssertEqual(loadLogServer(), .absent)
    }

    // First launch after the update: the legacy keys are sealed, then removed.
    func testLegacyMigratedSealedAndRemoved() throws {
        setLegacy()
        XCTAssertEqual(loadLogServer(), .found(expected))
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
        XCTAssertEqual(loadLogServer(), .found(current))
        XCTAssertNil(defaults.object(forKey: LogServerSettings.LegacyKey.host))
    }

    // Adversarial: a record sealed with another key is treated as missing and replaced
    // by the legacy value instead of leaving the setting unreadable.
    func testUndecryptableRecordReplacedByLegacy() throws {
        let foreign = EncryptedRecordStore(backend: backend, key: SymmetricKey(size: .bits256))
        try foreign.put(LogServerSettings(host: "x"), type: .settings, id: SealedSettingID.logServer)
        setLegacy()
        XCTAssertEqual(loadLogServer(), .found(expected))
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
        XCTAssertEqual(loadLogServer(readOnly), .found(expected))
        XCTAssertEqual(defaults.string(forKey: LogServerSettings.LegacyKey.host), "logs.example.net")
    }

    // Only some legacy keys set: the rest take their defaults; a bad transport too.
    func testPartialLegacyUsesDefaults() {
        defaults.set("h.example", forKey: LogServerSettings.LegacyKey.host)
        defaults.set("carrier-pigeon", forKey: LogServerSettings.LegacyKey.transport)
        XCTAssertEqual(LogServerSettings.legacy(in: defaults),
                       LogServerSettings(host: "h.example", port: 6514, transport: .tls, certPins: [:]))
    }

    // A record whose file can't be read (a locked device) is unreadable: nothing is
    // migrated over it and the legacy copy stays. Simulated with a directory where the
    // record file should be, which exists but can't be read as data.
    func testUnreadableFileIsUnreadableAndKeepsLegacy() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sealed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recordFile = dir.appendingPathComponent("settings/\(SealedSettingID.logServer.uuidString).rec")
        try FileManager.default.createDirectory(at: recordFile, withIntermediateDirectories: true)
        let fileRecords = EncryptedRecordStore(backend: FileBlobStore(directory: dir), key: SymmetricKey(size: .bits256))
        setLegacy()

        XCTAssertEqual(loadLogServer(fileRecords), .unreadable)
        XCTAssertEqual(defaults.string(forKey: LogServerSettings.LegacyKey.host), "logs.example.net")
    }
}
