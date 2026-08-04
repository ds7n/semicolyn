// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ETConnectConfigTests: XCTestCase {
    func testBuildsValidConfig() throws {
        let cfg = try etConnectConfig(host: "h.example", id: "abcdef0123456789",
                                      passkey: "0123456789abcdef0123456789abcdef",
                                      term: "xterm-256color", cols: 80, rows: 24)
        XCTAssertEqual(cfg.host, "h.example")
        XCTAssertEqual(cfg.port, 2022)
        XCTAssertEqual(cfg.id, "abcdef0123456789")
        XCTAssertEqual(cfg.passkey, "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(cfg.env["TERM"], "xterm-256color")
        XCTAssertEqual(cfg.cols, 80)
        XCTAssertEqual(cfg.rows, 24)
    }

    func testDefaultPortIs2022() throws {
        let cfg = try etConnectConfig(host: "h", id: "abcdef0123456789",
                                      passkey: "0123456789abcdef0123456789abcdef",
                                      term: "xterm", cols: 1, rows: 1)
        XCTAssertEqual(cfg.port, 2022)
    }

    // Invalid input throws the SPECIFIC ETConfigError (from slice 1a's validateETConfig).
    func testEmptyPasskeyThrowsEmptyPasskey() {
        XCTAssertThrowsError(try etConnectConfig(host: "h", id: "abcdef0123456789",
                                                 passkey: "", term: "xterm",
                                                 cols: 1, rows: 1)) {
            XCTAssertEqual($0 as? ETConfigError, .emptyPasskey)
        }
    }

    func testEmptyTermThrowsMissingTERM() {
        XCTAssertThrowsError(try etConnectConfig(host: "h", id: "abcdef0123456789",
                                                 passkey: "0123456789abcdef0123456789abcdef",
                                                 term: "", cols: 1, rows: 1)) {
            XCTAssertEqual($0 as? ETConfigError, .missingTERM)
        }
    }
}
