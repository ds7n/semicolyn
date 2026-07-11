// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// RFC 5424 syslog framing: PRI+version header, per-transport octet counting.
final class SyslogFrameTests: XCTestCase {
    private let ts = "2026-07-11T03:40:51.123Z"

    // EP: UDP → bare message, no octet-count prefix.
    func testUDPHasNoOctetCount() {
        let out = syslogFrame(message: "hello", hostname: "iphone", timestamp: ts, transport: .udp)
        XCTAssertEqual(out, "<135>1 2026-07-11T03:40:51.123Z iphone semicolyn - - - hello")
    }

    // EP: TCP → octet-count prefix = UTF-8 byte length of the syslog message + space.
    func testTCPOctetCountPrefix() {
        let msg = "<135>1 2026-07-11T03:40:51.123Z iphone semicolyn - - - hello"
        let out = syslogFrame(message: "hello", hostname: "iphone", timestamp: ts, transport: .tcp)
        XCTAssertEqual(out, "\(msg.utf8.count) \(msg)")
    }

    // TLS frames identically to TCP (octet-counted).
    func testTLSOctetCountMatchesTCP() {
        let tcp = syslogFrame(message: "hello", hostname: "iphone", timestamp: ts, transport: .tcp)
        let tls = syslogFrame(message: "hello", hostname: "iphone", timestamp: ts, transport: .tls)
        XCTAssertEqual(tls, tcp)
    }

    // BVA: multibyte content — octet count is BYTES not characters.
    func testMultibyteOctetCountIsBytes() {
        let content = "café→x"   // é = 2 bytes, → = 3 bytes
        let msg = "<135>1 2026-07-11T03:40:51.123Z iphone semicolyn - - - \(content)"
        let out = syslogFrame(message: content, hostname: "iphone", timestamp: ts, transport: .tls)
        XCTAssertEqual(out, "\(msg.utf8.count) \(msg)")
        // Guard against a char-count regression: bytes must exceed Swift character count here.
        XCTAssertGreaterThan(msg.utf8.count, msg.count)
    }

    // Empty hostname → NILVALUE '-'.
    func testEmptyHostnameBecomesDash() {
        let out = syslogFrame(message: "x", hostname: "", timestamp: ts, transport: .udp)
        XCTAssertEqual(out, "<135>1 2026-07-11T03:40:51.123Z - semicolyn - - - x")
    }

    // Newline in message is flattened to a space (single-line syslog; count stays correct).
    func testNewlineFlattenedToSpace() {
        let out = syslogFrame(message: "a\nb", hostname: "h", timestamp: ts, transport: .udp)
        XCTAssertEqual(out, "<135>1 2026-07-11T03:40:51.123Z h semicolyn - - - a b")
    }

    // PRI is exactly <135> (local0=16 · 8 + debug=7) and version is 1.
    func testPriAndVersion() {
        let out = syslogFrame(message: "m", hostname: "h", timestamp: ts, transport: .udp)
        XCTAssertTrue(out.hasPrefix("<135>1 "), "got: \(out)")
    }
}
