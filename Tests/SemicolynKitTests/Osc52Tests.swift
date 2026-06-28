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
}
