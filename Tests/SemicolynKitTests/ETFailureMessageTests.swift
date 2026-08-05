// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ETFailureMessageTests: XCTestCase {
    func testExecFailed() {
        XCTAssertEqual(etFailureMessage(.execFailed),
            "Eternal Terminal could not connect: could not start the bootstrap over SSH.")
    }

    func testNoIDPASSKEYIncludesServerHint() {
        let msg = etFailureMessage(.noIDPASSKEY(serverOutput: "command not found"))
        XCTAssertEqual(msg,
            "Eternal Terminal could not connect: no response from etserver (is it installed?). Server said: command not found")
    }

    func testMalformed() {
        XCTAssertEqual(etFailureMessage(.malformedIDPASSKEY),
            "Eternal Terminal could not connect: the server sent a malformed credential.")
    }

    func testInvalidConfig() {
        XCTAssertEqual(etFailureMessage(.invalidConfig(.missingTERM)),
            "Eternal Terminal could not connect: invalid connection settings (missingTERM).")
    }

    func testHandshakeFailedIncludesReason() {
        XCTAssertEqual(etFailureMessage(.handshakeFailed(reason: "protocol mismatch")),
            "Eternal Terminal could not connect: protocol mismatch")
    }
}
