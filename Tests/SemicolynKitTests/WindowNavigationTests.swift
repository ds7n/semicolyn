// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Pure wrap-around arithmetic behind `⌘]`/`⌘[` and Esc-pill swipe window stepping.
final class WindowNavigationTests: XCTestCase {
    // EP: forward/backward within range.
    func testForwardStepMovesToNextIndex() {
        XCTAssertEqual(stepIndex(current: 0, delta: +1, count: 3), 1)
    }

    func testBackwardStepMovesToPreviousIndex() {
        XCTAssertEqual(stepIndex(current: 2, delta: -1, count: 3), 1)
    }

    // BVA: wrap at the high boundary (last → first).
    func testForwardStepWrapsPastLast() {
        XCTAssertEqual(stepIndex(current: 2, delta: +1, count: 3), 0)
    }

    // BVA: wrap at the low boundary (first → last), incl. negative-modulo correctness.
    func testBackwardStepWrapsBeforeFirst() {
        XCTAssertEqual(stepIndex(current: 0, delta: -1, count: 3), 2)
    }

    // BVA: exactly two windows toggles.
    func testTwoWindowsToggle() {
        XCTAssertEqual(stepIndex(current: 0, delta: +1, count: 2), 1)
        XCTAssertEqual(stepIndex(current: 1, delta: +1, count: 2), 0)
    }

    // Negative: a single window is a no-op (nil), not index 0 spuriously.
    func testSingleWindowIsNoOp() {
        XCTAssertNil(stepIndex(current: 0, delta: +1, count: 1))
    }

    // Negative: zero windows is a no-op.
    func testZeroWindowsIsNoOp() {
        XCTAssertNil(stepIndex(current: 0, delta: +1, count: 0))
    }

    // Negative: an out-of-range current index is a no-op (guards stale state).
    func testOutOfRangeCurrentIsNoOp() {
        XCTAssertNil(stepIndex(current: 5, delta: +1, count: 3))
        XCTAssertNil(stepIndex(current: -1, delta: +1, count: 3))
    }
}
