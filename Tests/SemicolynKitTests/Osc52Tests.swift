// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class Osc52Tests: XCTestCase {
    func testAllowedNonEmptyWrites() {
        XCTAssertEqual(osc52Action(allow: true, content: [0x68, 0x69], isMoshReplay: false), .write([0x68, 0x69]))
    }
    func testDeniedDrops() {
        XCTAssertEqual(osc52Action(allow: false, content: [0x68, 0x69], isMoshReplay: false), .drop)
    }
    func testAllowedEmptyDropsToAvoidClobberingClipboard() {
        XCTAssertEqual(osc52Action(allow: true, content: [], isMoshReplay: false), .drop)
    }

    // BVA on the 1 MiB cap (security audit M1).
    func testExactlyAtCapWrites() {
        let payload = [UInt8](repeating: 0x61, count: osc52MaxBytes)
        XCTAssertEqual(osc52Action(allow: true, content: payload, isMoshReplay: false), .write(payload))
    }
    func testOneOverCapIsTooLarge() {
        let payload = [UInt8](repeating: 0x61, count: osc52MaxBytes + 1)
        XCTAssertEqual(osc52Action(allow: true, content: payload, isMoshReplay: false), .tooLarge(bytes: 1_048_577))
    }
    func testCapIsOneMebibyte() {
        XCTAssertEqual(osc52MaxBytes, 1_048_576)
    }
    // A disabled host stays silent even for an oversized write.
    func testDeniedOversizedStillDrops() {
        let payload = [UInt8](repeating: 0x61, count: osc52MaxBytes + 1)
        XCTAssertEqual(osc52Action(allow: false, content: payload, isMoshReplay: false), .drop)
    }

    // Notices: ordinary writes are silent; only a refused oversized write is announced.
    func testNoNoticeForOrdinaryWrite() {
        XCTAssertNil(osc52Notice(.write(Array("aé🙂".utf8))))
    }
    func testNoticeForTooLarge() {
        XCTAssertEqual(osc52Notice(.tooLarge(bytes: 2 * 1_048_576)),
                       "Blocked a 2.0 MB clipboard copy from the server (limit 1 MB)")
    }
    func testNoNoticeForDrop() {
        XCTAssertNil(osc52Notice(.drop))
    }

    // Mosh replay: mosh-server re-sends its last clipboard write to every new client.
    func testMoshReplayDropsEvenWhenAllowed() {
        XCTAssertEqual(osc52Action(allow: true, content: [0x68, 0x69], isMoshReplay: true), .drop)
    }
    func testMoshReplayDropsOversizedWithoutNotice() {
        let payload = [UInt8](repeating: 0x61, count: 1_048_577)
        let action = osc52Action(allow: true, content: payload, isMoshReplay: true)
        XCTAssertEqual(action, .drop)
        XCTAssertNil(osc52Notice(action))
    }
    func testReplayWindowIsFiveSeconds() {
        XCTAssertEqual(osc52MoshReplayWindow, 5)
    }
    func testMoshBeforeFirstFrameIsReplay() {
        XCTAssertTrue(osc52IsMoshReplay(isMosh: true, secondsSinceFirstFrame: nil))
    }
    func testMoshAtFirstFrameIsReplay() {
        XCTAssertTrue(osc52IsMoshReplay(isMosh: true, secondsSinceFirstFrame: 0))
    }
    func testMoshJustInsideWindowIsReplay() {
        XCTAssertTrue(osc52IsMoshReplay(isMosh: true, secondsSinceFirstFrame: 4.999))
    }
    func testMoshAtWindowEdgeIsLive() {
        XCTAssertFalse(osc52IsMoshReplay(isMosh: true, secondsSinceFirstFrame: 5))
    }
    func testMoshLongAfterFirstFrameIsLive() {
        XCTAssertFalse(osc52IsMoshReplay(isMosh: true, secondsSinceFirstFrame: 600))
    }
    func testLogLabelCarriesSizeNotContent() {
        XCTAssertEqual(Osc52Action.write(Array("secret".utf8)).logLabel, "write(6)")
        XCTAssertEqual(Osc52Action.drop.logLabel, "drop")
        XCTAssertEqual(Osc52Action.tooLarge(bytes: 1_048_577).logLabel, "tooLarge(1048577)")
    }
    func testNonMoshIsNeverReplay() {
        XCTAssertFalse(osc52IsMoshReplay(isMosh: false, secondsSinceFirstFrame: nil))
        XCTAssertFalse(osc52IsMoshReplay(isMosh: false, secondsSinceFirstFrame: 0))
    }
}
