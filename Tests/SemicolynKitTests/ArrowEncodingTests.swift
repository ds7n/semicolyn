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

final class WheelEncodingTests: XCTestCase {
    // SGR wheel-up at col 3, row 5: ESC [ < 6 4 ; 3 ; 5 M
    func testWheelUpBytes() {
        let bytes = encodeWheelRun(ArrowRun(direction: .up, count: 1), col: 3, row: 5)
        XCTAssertEqual(bytes, Array("\u{1b}[<64;3;5M".utf8))
    }
    // Wheel-down uses button 65 (swap-detecting: differs from up).
    func testWheelDownBytes() {
        let bytes = encodeWheelRun(ArrowRun(direction: .down, count: 1), col: 3, row: 5)
        XCTAssertEqual(bytes, Array("\u{1b}[<65;3;5M".utf8))
        XCTAssertNotEqual(bytes, encodeWheelRun(ArrowRun(direction: .up, count: 1), col: 3, row: 5))
    }
    // count repeats the event exactly count times.
    func testWheelCountRepeats() {
        let one = encodeWheelRun(ArrowRun(direction: .up, count: 1), col: 1, row: 1)
        let three = encodeWheelRun(ArrowRun(direction: .up, count: 3), col: 1, row: 1)
        XCTAssertEqual(three, one + one + one)
    }
    // Multi-digit coordinates render as decimal.
    func testWheelMultiDigitCoords() {
        let bytes = encodeWheelRun(ArrowRun(direction: .down, count: 1), col: 80, row: 40)
        XCTAssertEqual(bytes, Array("\u{1b}[<65;80;40M".utf8))
    }
    // count 0 or horizontal -> empty.
    func testWheelZeroAndHorizontalEmpty() {
        XCTAssertEqual(encodeWheelRun(ArrowRun(direction: .up, count: 0), col: 1, row: 1), [])
        XCTAssertEqual(encodeWheelRun(ArrowRun(direction: .left, count: 2), col: 1, row: 1), [])
    }
}
