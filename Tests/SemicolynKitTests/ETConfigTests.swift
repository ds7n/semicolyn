// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ETConfigTests: XCTestCase {
    private func valid() -> ETConfig {
        ETConfig(host: "h.example", port: 0, id: "0123456789abcdef",
                 passkey: "0123456789abcdef0123456789abcdef",
                 env: ["TERM": "xterm-256color"], cols: 80, rows: 24,
                 width: 0, height: 0, keepaliveSecs: 0)
    }

    func testValidConfigPassesThroughUnchanged() throws {
        let cfg = valid()
        XCTAssertEqual(try validateETConfig(cfg), cfg)
    }

    func testEmptyHostThrowsEmptyHost() {
        var cfg = valid(); cfg.host = ""
        XCTAssertThrowsError(try validateETConfig(cfg)) {
            XCTAssertEqual($0 as? ETConfigError, .emptyHost)
        }
    }

    func testEmptyIDThrowsEmptyID() {
        var cfg = valid(); cfg.id = ""
        XCTAssertThrowsError(try validateETConfig(cfg)) {
            XCTAssertEqual($0 as? ETConfigError, .emptyID)
        }
    }

    func testEmptyPasskeyThrowsEmptyPasskey() {
        var cfg = valid(); cfg.passkey = ""
        XCTAssertThrowsError(try validateETConfig(cfg)) {
            XCTAssertEqual($0 as? ETConfigError, .emptyPasskey)
        }
    }

    func testMissingTERMThrowsMissingTERM() {
        var cfg = valid(); cfg.env = [:]
        XCTAssertThrowsError(try validateETConfig(cfg)) {
            XCTAssertEqual($0 as? ETConfigError, .missingTERM)
        }
    }

    func testEmptyTERMValueIsTreatedAsMissing() {
        var cfg = valid(); cfg.env = ["TERM": ""]
        XCTAssertThrowsError(try validateETConfig(cfg)) {
            XCTAssertEqual($0 as? ETConfigError, .missingTERM)
        }
    }

    // Port 0 is a valid input (the C ABI maps 0 -> default 2022); do not reject it.
    func testPortZeroIsAccepted() throws {
        XCTAssertEqual(try validateETConfig(valid()).port, 0)
    }
}
