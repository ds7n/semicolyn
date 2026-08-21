// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class PredictorEditingKeysTests: XCTestCase {
    func testDelIsEditingKey() { XCTAssertTrue(containsEditingKey([0x7f])) }
    func testBackspaceIsEditingKey() { XCTAssertTrue(containsEditingKey([0x08])) }
    func testPrintableIsNot() { XCTAssertFalse(containsEditingKey([0x61])) }   // 'a'
    func testEmptyIsNot() { XCTAssertFalse(containsEditingKey([])) }
    func testMixedPrintableThenDelIsEditingKey() { XCTAssertTrue(containsEditingKey([0x61, 0x7f])) }
}
