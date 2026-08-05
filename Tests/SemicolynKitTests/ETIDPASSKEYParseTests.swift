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

    private let id16b = "abcdef0123456789"                     // 16
    private let key32b = "0123456789abcdef0123456789abcdef"    // 32

    // The credential is followed by trailing content on the same line (a CR from the
    // SSH PTY, or a status token). Upstream takes a fixed 49-char window and ignores
    // this; we must too. THIS is the device bug.
    func testTrailingCarriageReturnAfterCredentialSucceeds() {
        let out = "IDPASSKEY:\(id16b)/\(key32b)\r\n"
        guard case .success(let cred) = parseETIDPASSKEY(out) else { return XCTFail("expected success") }
        XCTAssertEqual(cred.id, id16b)
        XCTAssertEqual(cred.passkey, key32b)
    }

    func testTrailingJunkOnCredentialLineSucceeds() {
        let out = "IDPASSKEY:\(id16b)/\(key32b) extra=1 more junk\n"
        guard case .success(let cred) = parseETIDPASSKEY(out) else { return XCTFail("expected success") }
        XCTAssertEqual(cred.id, id16b)
        XCTAssertEqual(cred.passkey, key32b)
    }

    // A shell banner printed before the marker must not break extraction.
    func testLeadingBannerBeforeMarkerSucceeds() {
        let out = "bash: cannot set terminal process group\nIDPASSKEY:\(id16b)/\(key32b)\n"
        guard case .success(let cred) = parseETIDPASSKEY(out) else { return XCTFail("expected success") }
        XCTAssertEqual(cred.id, id16b)
        XCTAssertEqual(cred.passkey, key32b)
    }

    // Boundary: fewer than 49 chars after the marker -> malformed.
    func testTruncatedWindowIsMalformed() {
        let out = "IDPASSKEY:\(id16b)/short"
        guard case .failure(let e) = parseETIDPASSKEY(out) else { return XCTFail("expected failure") }
        XCTAssertEqual(e, .malformedIDPASSKEY)
    }

    // Slash not at index 16 (window landed on wrong content) -> malformed.
    func testSlashNotAtIndex16IsMalformed() {
        let out = "IDPASSKEY:abcd/efghijklmnopqrstuvwxyz0123456789ABCDEF\n"   // slash at 4
        guard case .failure(let e) = parseETIDPASSKEY(out) else { return XCTFail("expected failure") }
        XCTAssertEqual(e, .malformedIDPASSKEY)
    }

    // Non-alphanumeric inside the id/passkey window -> malformed (garbage rejected).
    func testNonAlphanumericWindowIsMalformed() {
        // 16 chars, slash, then 32 chars but with a space inside the passkey window.
        let out = "IDPASSKEY:\(id16b)/0123456789abcdef 123456789abcdef\n"
        guard case .failure(let e) = parseETIDPASSKEY(out) else { return XCTFail("expected failure") }
        XCTAssertEqual(e, .malformedIDPASSKEY)
    }
}
