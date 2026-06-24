// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class KeychainAccountTests: XCTestCase {
    func testRecordKeyAccountIsStable() {
        XCTAssertEqual(keychainAccount(for: .recordKey), "recordKey")
    }

    func testKindsWithSameUUIDDoNotCollide() {
        let id = UUID()
        let accounts = [
            keychainAccount(for: .recordKey),
            keychainAccount(for: .privateKey(identityID: id)),
            keychainAccount(for: .password(id: id)),
            keychainAccount(for: .passphrase(identityID: id)),
            keychainAccount(for: .hostKeys(hostID: id)),
        ]
        XCTAssertEqual(Set(accounts).count, 5)   // distinct kinds → distinct accounts
        XCTAssertTrue(keychainAccount(for: .hostKeys(hostID: id)).hasPrefix("hostKeys/"))
    }

    func testDifferentUUIDsDoNotCollide() {
        let a = UUID(), b = UUID()
        XCTAssertNotEqual(keychainAccount(for: .hostKeys(hostID: a)),
                          keychainAccount(for: .hostKeys(hostID: b)))
    }
}
