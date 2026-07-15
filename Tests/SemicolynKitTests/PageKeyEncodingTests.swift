// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class PageKeyEncodingTests: XCTestCase {
    // Up → PgUp = ESC [ 5 ~  (0x1b 0x5b 0x35 0x7e). Direction convention matches arrows:
    // an .up run scrolls back, which for a pager/TUI is Page Up.
    func testUpEncodesPageUp() {
        let run = ArrowRun(direction: .up, count: 1)
        XCTAssertEqual(encodePageKeyRun(run), [0x1b, 0x5b, 0x35, 0x7e])
    }

    // Down → PgDn = ESC [ 6 ~  (0x1b 0x5b 0x36 0x7e).
    func testDownEncodesPageDown() {
        let run = ArrowRun(direction: .down, count: 1)
        XCTAssertEqual(encodePageKeyRun(run), [0x1b, 0x5b, 0x36, 0x7e])
    }

    // count repeats the sequence exactly count times.
    func testCountRepeats() {
        let run = ArrowRun(direction: .up, count: 3)
        XCTAssertEqual(encodePageKeyRun(run),
                       [0x1b,0x5b,0x35,0x7e, 0x1b,0x5b,0x35,0x7e, 0x1b,0x5b,0x35,0x7e])
    }

    // count 0 → empty.
    func testZeroCountEmpty() {
        XCTAssertEqual(encodePageKeyRun(ArrowRun(direction: .up, count: 0)), [])
    }

    // Horizontal runs have no page-key analog → empty (alt-screen scroll is vertical).
    func testHorizontalEmpty() {
        XCTAssertEqual(encodePageKeyRun(ArrowRun(direction: .left, count: 2)), [])
        XCTAssertEqual(encodePageKeyRun(ArrowRun(direction: .right, count: 2)), [])
    }
}
