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

final class InMemorySecretStoreTests: XCTestCase {
    func testSetGetDeleteByRef() throws {
        let s = InMemorySecretStore()
        let idA = UUID()
        try s.setSecret(Data([1, 2]), for: .privateKey(identityID: idA))
        XCTAssertEqual(try s.getSecret(.privateKey(identityID: idA)), Data([1, 2]))
        XCTAssertNil(try s.getSecret(.privateKey(identityID: UUID())))   // distinct ref → nil
        XCTAssertNil(try s.getSecret(.password(id: idA)))               // distinct kind, same UUID → nil
        try s.deleteSecret(.privateKey(identityID: idA))
        XCTAssertNil(try s.getSecret(.privateKey(identityID: idA)))
        try s.deleteSecret(.privateKey(identityID: idA))                // idempotent
    }

    func testRecordKeyIsGeneratedOnceAndStable() throws {
        let s = InMemorySecretStore()
        let k1 = try recordKey(in: s)
        let k2 = try recordKey(in: s)                                    // must not regenerate
        let d1 = k1.withUnsafeBytes { Data($0) }
        let d2 = k2.withUnsafeBytes { Data($0) }
        XCTAssertEqual(d1, d2)
        XCTAssertEqual(d1.count, 32)
        XCTAssertNotNil(try s.getSecret(.recordKey))                     // persisted
    }
}
