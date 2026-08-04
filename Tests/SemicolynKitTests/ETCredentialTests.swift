// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ETCredentialTests: XCTestCase {
    func testIDIs16Chars() {
        XCTAssertEqual(etGenerateCredential().id.count, 16)
    }

    func testPasskeyIs32Chars() {
        XCTAssertEqual(etGenerateCredential().passkey.count, 32)
    }

    // Legacy-compat marker: the first three id chars are always 'X'.
    func testIDStartsWithXXX() {
        XCTAssertTrue(etGenerateCredential().id.hasPrefix("XXX"))
    }

    // Charset: id + passkey contain only alphanumerics.
    func testCharsetIsAlphanumericOnly() {
        let allowed = Set(etAlphanumeric)
        let cred = etGenerateCredential()
        XCTAssertTrue(cred.id.allSatisfy { allowed.contains($0) })
        XCTAssertTrue(cred.passkey.allSatisfy { allowed.contains($0) })
    }

    // Not a stub: two successive credentials differ (passkeys, and ids past the XXX marker).
    func testSuccessiveCredentialsDiffer() {
        let a = etGenerateCredential()
        let b = etGenerateCredential()
        XCTAssertNotEqual(a.passkey, b.passkey)
        XCTAssertNotEqual(a.id, b.id)
    }
}
