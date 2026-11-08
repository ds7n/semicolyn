// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import Foundation
@testable import SemicolynKit

final class EraseAllDataTests: XCTestCase {
    private let suite = "EraseAllDataTests"
    private var defaults: UserDefaults!
    private var root: URL!
    private var records: URL!
    private var fonts: URL!
    private let device = InMemorySecretStore()
    private let synced = InMemorySecretStore()
    private let session = UUID(), host = UUID(), identity = UUID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("erase-\(UUID().uuidString)", isDirectory: true)
        records = root.appendingPathComponent("semicolyn/records/host", isDirectory: true)
        fonts = root.appendingPathComponent("Fonts", isDirectory: true)
        for dir in [records!, fonts!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data([1]).write(to: dir.appendingPathComponent("x"))
        }
        try device.setSecret(Data([1]), for: .resumeSecret(sessionID: session))
        try synced.setSecret(Data([2]), for: .recordKey)
        try synced.setSecret(Data([3]), for: .password(id: host))
        try synced.setSecret(Data([4]), for: .privateKey(identityID: identity))
        defaults.set("x", forKey: "semicolyn.keybarSettings")
        defaults.set(true, forKey: PrivacyPreferences.Key.allowThirdPartyKeyboards)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func erase(alsoFromOtherDevices: Bool) throws {
        try eraseAllAppData(directories: [root.appendingPathComponent("semicolyn"), fonts],
                            deviceSecrets: device, syncedSecrets: synced,
                            alsoFromOtherDevices: alsoFromOtherDevices,
                            defaults: defaults, defaultsDomain: suite)
    }

    // Default (box unticked): files, device secrets and settings go; synced secrets stay.
    func testLocalEraseKeepsSyncedSecrets() throws {
        try erase(alsoFromOtherDevices: false)

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("semicolyn").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fonts.path))
        XCTAssertNil(try device.getSecret(.resumeSecret(sessionID: session)))
        XCTAssertEqual(try synced.getSecret(.password(id: host)), Data([3]))
        XCTAssertEqual(try synced.getSecret(.privateKey(identityID: identity)), Data([4]))
        XCTAssertEqual(try synced.getSecret(.recordKey), Data([2]))
        XCTAssertNil(defaults.object(forKey: "semicolyn.keybarSettings"))
        XCTAssertNil(defaults.object(forKey: PrivacyPreferences.Key.allowThirdPartyKeyboards))
    }

    // Box ticked: synced secrets go too, except the record key other devices still need.
    func testEverywhereEraseDeletesSyncedButKeepsRecordKey() throws {
        try erase(alsoFromOtherDevices: true)

        XCTAssertNil(try synced.getSecret(.password(id: host)))
        XCTAssertNil(try synced.getSecret(.privateKey(identityID: identity)))
        XCTAssertEqual(try synced.getSecret(.recordKey), Data([2]))
        XCTAssertNil(try device.getSecret(.resumeSecret(sessionID: session)))
    }

    // A directory that doesn't exist (no fonts ever imported) is not a failure; the
    // rest is still erased.
    func testMissingDirectoryIsFine() throws {
        try FileManager.default.removeItem(at: fonts)
        try erase(alsoFromOtherDevices: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("semicolyn").path))
        XCTAssertNil(try device.getSecret(.resumeSecret(sessionID: session)))
        XCTAssertNil(defaults.object(forKey: "semicolyn.keybarSettings"))
    }

    // A second erase finds nothing, succeeds, and leaves the same end state.
    func testEraseIsIdempotent() throws {
        try erase(alsoFromOtherDevices: true)
        try erase(alsoFromOtherDevices: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fonts.path))
        XCTAssertNil(try synced.getSecret(.password(id: host)))
        XCTAssertEqual(try synced.getSecret(.recordKey), Data([2]))
    }

    // A directory that can't be removed is reported as `.files`; secrets and settings
    // are still erased. (Its parent is made read-only, so the delete is refused.)
    func testUndeletableDirectoryReportsFiles() throws {
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        let stuck = locked.appendingPathComponent("stuck", isDirectory: true)
        try FileManager.default.createDirectory(at: stuck, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        try XCTSkipIf(getuid() == 0, "root ignores directory permissions")

        XCTAssertThrowsError(try eraseAllAppData(
            directories: [stuck], deviceSecrets: device, syncedSecrets: synced,
            alsoFromOtherDevices: false, defaults: defaults, defaultsDomain: suite)) { error in
            XCTAssertEqual(error as? EraseIncomplete, EraseIncomplete(failedSteps: [.files]))
        }
        XCTAssertNil(try device.getSecret(.resumeSecret(sessionID: session)))
        XCTAssertNil(defaults.object(forKey: "semicolyn.keybarSettings"))
    }

    // A failing secret store is reported by name, and the other steps still run.
    func testFailureNamedAndOtherStepsStillRun() throws {
        final class FailingStore: BulkErasableSecretStore {
            struct Boom: Error {}
            func setSecret(_ data: Data, for ref: SecretRef) throws {}
            func getSecret(_ ref: SecretRef) throws -> Data? { nil }
            func deleteSecret(_ ref: SecretRef) throws {}
            func deleteAllSecrets(except kept: Set<SecretRef>) throws { throw Boom() }
        }
        XCTAssertThrowsError(try eraseAllAppData(
            directories: [fonts], deviceSecrets: FailingStore(), syncedSecrets: synced,
            alsoFromOtherDevices: true, defaults: defaults, defaultsDomain: suite)) { error in
            XCTAssertEqual(error as? EraseIncomplete, EraseIncomplete(failedSteps: [.deviceSecrets]))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fonts.path))
        XCTAssertNil(try synced.getSecret(.password(id: host)))
        XCTAssertNil(defaults.object(forKey: "semicolyn.keybarSettings"))
    }
}
