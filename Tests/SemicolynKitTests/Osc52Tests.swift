// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class Osc52Tests: XCTestCase {
    func testAllowedNonEmptyWrites() {
        XCTAssertEqual(osc52Action(allow: true, content: [0x68, 0x69]), .write([0x68, 0x69]))
    }
    func testDeniedDrops() {
        XCTAssertEqual(osc52Action(allow: false, content: [0x68, 0x69]), .drop)
    }
    func testAllowedEmptyDropsToAvoidClobberingClipboard() {
        XCTAssertEqual(osc52Action(allow: true, content: []), .drop)
    }

    // BVA on the 1 MiB cap (security audit M1).
    func testExactlyAtCapWrites() {
        let payload = [UInt8](repeating: 0x61, count: osc52MaxBytes)
        XCTAssertEqual(osc52Action(allow: true, content: payload), .write(payload))
    }
    func testOneOverCapIsTooLarge() {
        let payload = [UInt8](repeating: 0x61, count: osc52MaxBytes + 1)
        XCTAssertEqual(osc52Action(allow: true, content: payload), .tooLarge(bytes: 1_048_577))
    }
    func testCapIsOneMebibyte() {
        XCTAssertEqual(osc52MaxBytes, 1_048_576)
    }
    // A disabled host stays silent even for an oversized write.
    func testDeniedOversizedStillDrops() {
        let payload = [UInt8](repeating: 0x61, count: osc52MaxBytes + 1)
        XCTAssertEqual(osc52Action(allow: false, content: payload), .drop)
    }

    // Notices: never silent for a write.
    func testNoticeCountsCharactersNotBytes() {
        // "é" is 2 bytes, "🙂" is 4: three characters total with "a".
        let bytes = Array("aé🙂".utf8)
        XCTAssertEqual(osc52Notice(.write(bytes)), "Server copied 3 characters to the clipboard")
    }
    func testNoticeSingular() {
        XCTAssertEqual(osc52Notice(.write([0x78])), "Server copied 1 character to the clipboard")
    }
    func testNoticeForTooLarge() {
        XCTAssertEqual(osc52Notice(.tooLarge(bytes: 2 * 1_048_576)),
                       "Blocked a 2.0 MB clipboard copy from the server (limit 1 MB)")
    }
    func testNoNoticeForDrop() {
        XCTAssertNil(osc52Notice(.drop))
    }
}
