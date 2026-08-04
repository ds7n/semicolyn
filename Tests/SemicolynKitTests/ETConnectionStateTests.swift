// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ETConnectionStateTests: XCTestCase {
    func testKnownStatesMap() {
        XCTAssertEqual(mapETState(0), .connecting)
        XCTAssertEqual(mapETState(1), .connected)
        XCTAssertEqual(mapETState(2), .roaming)
        XCTAssertEqual(mapETState(3), .disconnected)
    }

    // A newer or hostile library sending an out-of-range code must not crash.
    func testUnknownHighCodeIsWrapped() {
        XCTAssertEqual(mapETState(7), .unknown(7))
    }

    func testNegativeCodeIsWrapped() {
        XCTAssertEqual(mapETState(-1), .unknown(-1))
    }
}
