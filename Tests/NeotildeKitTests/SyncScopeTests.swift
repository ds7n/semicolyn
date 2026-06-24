// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class SyncScopeTests: XCTestCase {
    func testBackendsMatchSpec() {
        XCTAssertEqual(SyncItem.hostRecord.backend, .cloudKitAES)
        XCTAssertEqual(SyncItem.identityMetadata.backend, .cloudKitAES)
        XCTAssertEqual(SyncItem.knownHosts.backend, .iCloudKeychain)
        XCTAssertEqual(SyncItem.privateKeySE.backend, .secureEnclave)
        XCTAssertEqual(SyncItem.recentConnections.backend, .localOnly)
    }
    func testSyncFlags() {
        XCTAssertTrue(SyncItem.hostRecord.syncs)
        XCTAssertTrue(SyncItem.password.syncs)        // iCloud Keychain syncs
        XCTAssertFalse(SyncItem.privateKeySE.syncs)   // device-bound
        XCTAssertFalse(SyncItem.liveSessionState.syncs)
    }
    func testAuditLogIsReservedNoOp() {
        XCTAssertEqual(AuditLog.reservedNamespace, "auditLog")
        AuditLog.record("connect")                    // must compile, do nothing, not crash
    }
}
