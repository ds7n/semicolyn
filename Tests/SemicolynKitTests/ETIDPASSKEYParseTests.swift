// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ETIDPASSKEYParseTests: XCTestCase {
    private let id16 = "abcdef0123456789"                     // 16
    private let key32 = "0123456789abcdef0123456789abcdef"    // 32

    func testValidLineExtractsCredential() {
        let out = "IDPASSKEY:\(id16)/\(key32)\n"
        guard case .success(let cred) = parseETIDPASSKEY(out) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(cred.id, id16)
        XCTAssertEqual(cred.passkey, key32)
    }

    // Upstream uses find(), so the line may be embedded in surrounding server noise.
    func testEmbeddedInNoiseStillExtracts() {
        let out = "MOTD: welcome\nIDPASSKEY:\(id16)/\(key32)\nlogged in\n"
        guard case .success(let cred) = parseETIDPASSKEY(out) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(cred.id, id16)
        XCTAssertEqual(cred.passkey, key32)
    }

    func testNoLineIsNoIDPASSKEYWithSanitizedOutput() {
        // sanitizeEndReason collapses whitespace (including a trailing newline)
        // to a single space rather than trimming it, per its documented/tested
        // behavior (ETEndReasonTests.testNewlinesCollapsedToSpace).
        guard case .failure(let err) = parseETIDPASSKEY("command not found: etterminal\n") else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(err, .noIDPASSKEY(serverOutput: "command not found: etterminal "))
    }

    func testShortIDIsMalformed() {
        let out = "IDPASSKEY:short/\(key32)\n"
        guard case .failure(let err) = parseETIDPASSKEY(out) else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(err, .malformedIDPASSKEY)
    }

    func testShortPasskeyIsMalformed() {
        let out = "IDPASSKEY:\(id16)/tooshort\n"
        guard case .failure(let err) = parseETIDPASSKEY(out) else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(err, .malformedIDPASSKEY)
    }

    func testMissingSlashIsMalformed() {
        let out = "IDPASSKEY:\(id16)\(key32)\n"   // no separator
        guard case .failure(let err) = parseETIDPASSKEY(out) else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(err, .malformedIDPASSKEY)
    }

    // An injection-laden non-IDPASSKEY output is captured but sanitized (no ANSI/markup leak).
    func testInjectionOutputIsSanitizedInNoIDPASSKEY() {
        guard case .failure(let err) = parseETIDPASSKEY("\u{1B}[31m<b>evil</b>\u{1B}[0m") else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(err, .noIDPASSKEY(serverOutput: "evil"))
    }
}
