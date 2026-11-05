// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Security audit M3: pinned diagnostics TLS, content only over it, and content logging
/// switched off whenever the stream is redirected.
final class RemoteLogSecurityTests: XCTestCase {
    // MARK: certificate pin decision

    func testNoPinPinsFirst() {
        XCTAssertEqual(remoteLogCertDecision(pinned: nil, presented: "SHA256:A"), .pinFirst)
    }
    func testEmptyPinPinsFirst() {
        XCTAssertEqual(remoteLogCertDecision(pinned: "", presented: "SHA256:A"), .pinFirst)
    }
    func testSamePinMatches() {
        XCTAssertEqual(remoteLogCertDecision(pinned: "SHA256:A", presented: "SHA256:A"), .match)
    }
    // Adversarial: a substituted certificate is refused and the old pin reported.
    func testDifferentCertIsMismatch() {
        XCTAssertEqual(remoteLogCertDecision(pinned: "SHA256:A", presented: "SHA256:B"),
                       .mismatch(pinned: "SHA256:A"))
    }
    // Adversarial: fingerprints are case-sensitive base64; a case-folded lookalike is not a match.
    func testCaseDifferenceIsMismatch() {
        XCTAssertEqual(remoteLogCertDecision(pinned: "SHA256:abc", presented: "SHA256:ABC"),
                       .mismatch(pinned: "SHA256:abc"))
    }

    // MARK: pin key

    func testPinKeyIgnoresHostCase() {
        XCTAssertEqual(remoteLogPinKey(host: "Logs.Example.COM", port: 6514), "logs.example.com:6514")
    }
    func testPinKeyDistinguishesPorts() {
        XCTAssertNotEqual(remoteLogPinKey(host: "h", port: 6514), remoteLogPinKey(host: "h", port: 6515))
    }

    // MARK: fingerprint (known SHA-256 vectors)

    func testFingerprintOfEmpty() {
        XCTAssertEqual(certificateFingerprint(der: []),
                       "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU")
    }
    func testFingerprintOfABC() {
        XCTAssertEqual(certificateFingerprint(der: Array("abc".utf8)),
                       "SHA256:ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0")
    }

    // MARK: content only over TLS

    func testContentAllowedOverTLS() {
        XCTAssertTrue(remoteLogMaySendContent(transport: .tls))
    }
    func testContentRefusedOverTCP() {
        XCTAssertFalse(remoteLogMaySendContent(transport: .tcp))
    }
    func testContentRefusedOverUDP() {
        XCTAssertFalse(remoteLogMaySendContent(transport: .udp))
    }

    // MARK: destination change turns content logging off

    private let base = RemoteLogDestination(enabled: true, host: "logs", port: 6514, transport: .tls)

    func testUnchangedDestinationKeepsContentOn() {
        XCTAssertTrue(keystrokeContentAfterDestinationChange(contentOn: true, old: base, new: base))
    }
    func testHostChangeTurnsContentOff() {
        var new = base; new.host = "evil.example"
        XCTAssertFalse(keystrokeContentAfterDestinationChange(contentOn: true, old: base, new: new))
    }
    func testPortChangeTurnsContentOff() {
        var new = base; new.port = 6515
        XCTAssertFalse(keystrokeContentAfterDestinationChange(contentOn: true, old: base, new: new))
    }
    func testTransportChangeTurnsContentOff() {
        var new = base; new.transport = .udp
        XCTAssertFalse(keystrokeContentAfterDestinationChange(contentOn: true, old: base, new: new))
    }
    func testEnablingStreamTurnsContentOff() {
        var old = base; old.enabled = false
        XCTAssertFalse(keystrokeContentAfterDestinationChange(contentOn: true, old: old, new: base))
    }
    func testContentOffStaysOff() {
        XCTAssertFalse(keystrokeContentAfterDestinationChange(contentOn: false, old: base, new: base))
    }

    // MARK: indicator condition

    func testIndicatorNeedsAllThree() {
        XCTAssertTrue(keystrokeContentActive(loggingEnabled: true, inputCategoryOn: true, contentOn: true))
        XCTAssertFalse(keystrokeContentActive(loggingEnabled: false, inputCategoryOn: true, contentOn: true))
        XCTAssertFalse(keystrokeContentActive(loggingEnabled: true, inputCategoryOn: false, contentOn: true))
        XCTAssertFalse(keystrokeContentActive(loggingEnabled: true, inputCategoryOn: true, contentOn: false))
    }
}
