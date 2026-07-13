// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ArrowEncodingTests: XCTestCase {
    // Normal cursor-key mode (DECCKM off) → CSI: ESC [ A, repeated by count.
    func testUpTwiceNormalModeIsCSIRepeated() {
        let bytes = encodeArrowRun(ArrowRun(direction: .up, count: 2), applicationCursorKeys: false)
        XCTAssertEqual(bytes, [0x1b, 0x5b, 0x41, 0x1b, 0x5b, 0x41]) // ESC[A ESC[A
    }
    // Application cursor-key mode (DECCKM on) → SS3: ESC O B.
    func testDownOnceApplicationModeIsSS3() {
        let bytes = encodeArrowRun(ArrowRun(direction: .down, count: 1), applicationCursorKeys: true)
        XCTAssertEqual(bytes, [0x1b, 0x4f, 0x42]) // ESC O B
    }
    // Left/right map correctly (regression against a direction swap).
    func testLeftRightNormalMode() {
        XCTAssertEqual(encodeArrowRun(ArrowRun(direction: .left, count: 1), applicationCursorKeys: false),
                       [0x1b, 0x5b, 0x44]) // ESC [ D
        XCTAssertEqual(encodeArrowRun(ArrowRun(direction: .right, count: 1), applicationCursorKeys: false),
                       [0x1b, 0x5b, 0x43]) // ESC [ C
    }
    // Zero count → no bytes.
    func testZeroCountIsEmpty() {
        XCTAssertEqual(encodeArrowRun(ArrowRun(direction: .up, count: 0), applicationCursorKeys: false), [])
    }
}
