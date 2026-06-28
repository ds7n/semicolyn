// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import SemicolynKit

final class RecordEnvelopeTests: XCTestCase {
    private let key = SymmetricKey(size: .bits256)

    func testSealThenOpenRoundTripsRecord() throws {
        let host = Host(id: UUID(), label: "prod", hostName: "db.internal",
                        port: .explicit(2222))
        let sealed = try RecordEnvelope.seal(host, key: key)
        // Qualify as SemicolynKit.Host: on Linux, swift-corelibs-Foundation also
        // exports a `Host` type, ambiguous in type-annotation position.
        let opened: SemicolynKit.Host = try RecordEnvelope.open(sealed, as: SemicolynKit.Host.self, key: key)
        XCTAssertEqual(opened, host)
    }

    func testCiphertextDiffersFromPlaintext() throws {
        let host = Host(id: UUID(), label: "prod", hostName: "db.internal")
        let sealed = try RecordEnvelope.seal(host, key: key)
        let plain = try JSONEncoder().encode(host)
        XCTAssertNotEqual(sealed, plain)
    }

    func testWrongKeyFailsToOpen() throws {
        let host = Host(id: UUID(), label: "prod", hostName: "db.internal")
        let sealed = try RecordEnvelope.seal(host, key: key)
        XCTAssertThrowsError(
            try RecordEnvelope.open(sealed, as: SemicolynKit.Host.self,
                                    key: SymmetricKey(size: .bits256))
        ) { error in
            XCTAssertEqual(error as? RecordEnvelopeError, .decryptionFailed)
        }
    }

    func testTamperedCiphertextFailsToOpen() throws {
        let host = Host(id: UUID(), label: "prod", hostName: "db.internal")
        var sealed = try RecordEnvelope.seal(host, key: key)
        sealed[sealed.count - 1] ^= 0xFF   // flip a bit in the GCM tag region
        XCTAssertThrowsError(
            try RecordEnvelope.open(sealed, as: SemicolynKit.Host.self, key: key)
        ) { error in
            XCTAssertEqual(error as? RecordEnvelopeError, .decryptionFailed)
        }
    }

    func testMalformedBlobFailsToOpenWithTypedError() throws {
        // Adversarial: a blob too short to be a valid sealed box must produce
        // the typed `decryptionFailed`, never a panic or a raw CryptoKit error.
        let garbage = Data([0x00, 0x01, 0x02, 0x03])
        XCTAssertThrowsError(
            try RecordEnvelope.open(garbage, as: SemicolynKit.Host.self, key: key)
        ) { error in
            XCTAssertEqual(error as? RecordEnvelopeError, .decryptionFailed)
        }
    }
}
