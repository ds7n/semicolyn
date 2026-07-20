// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ArrowRepeatTests: XCTestCase {

    // MARK: interval(heldFor:) — iOS-style hold-to-repeat timing (BVA on the curve)

    func testNoRepeatAtStart() {
        XCTAssertNil(ArrowRepeat.interval(heldFor: 0))              // still in initial-delay window
    }
    func testNoRepeatJustUnderInitialDelay() {
        XCTAssertNil(ArrowRepeat.interval(heldFor: 0.40 - 0.001))   // just under boundary
    }
    func testStartIntervalAtInitialDelayBoundary() {
        let out = ArrowRepeat.interval(heldFor: 0.40)               // exactly at boundary
        XCTAssertNotNil(out)
        XCTAssertEqual(out!, 0.25, accuracy: 1e-9)                  // == startInterval
    }
    func testEasesToRampMidpoint() {
        // Linear ease start(0.25)->min(0.06) across rampDuration(1.20); midpoint = mean.
        let out = ArrowRepeat.interval(heldFor: 0.40 + 0.60)        // half the ramp
        XCTAssertNotNil(out)
        XCTAssertEqual(out!, (0.25 + 0.06) / 2, accuracy: 1e-9)     // 0.155
    }
    func testClampsToMinIntervalAtRampEnd() {
        let out = ArrowRepeat.interval(heldFor: 0.40 + 1.20)        // ramp end
        XCTAssertNotNil(out)
        XCTAssertEqual(out!, 0.06, accuracy: 1e-9)                  // == minInterval
    }
    func testClampsToMinIntervalPastRampEnd() {
        let out = ArrowRepeat.interval(heldFor: 0.40 + 1.20 + 1.0)  // well past ramp
        XCTAssertNotNil(out)
        XCTAssertEqual(out!, 0.06, accuracy: 1e-9)                  // clamped floor
    }

    // MARK: dominantArrow(dx:dy:) — equivalence partitions, one representative each

    func testDominantRight() { XCTAssertEqual(dominantArrow(dx: 10, dy: 0), .right) }
    func testDominantLeft()  { XCTAssertEqual(dominantArrow(dx: -10, dy: 0), .left) }
    func testDominantDown()  { XCTAssertEqual(dominantArrow(dx: 0, dy: 10), .down) }
    func testDominantUp()    { XCTAssertEqual(dominantArrow(dx: 0, dy: -10), .up) }
    func testDominantDiagonalHorizontalWins() {
        XCTAssertEqual(dominantArrow(dx: 10, dy: 4), .right)        // |dx| > |dy|
    }
    func testDominantDiagonalVerticalWins() {
        XCTAssertEqual(dominantArrow(dx: 4, dy: -10), .up)          // |dy| > |dx|
    }
    func testTieResolvesHorizontalPositive() {
        XCTAssertEqual(dominantArrow(dx: 5, dy: 5), .right)         // |dx| == |dy|, dx >= 0
    }
    func testTieResolvesHorizontalNegative() {
        XCTAssertEqual(dominantArrow(dx: -5, dy: 5), .left)         // |dx| == |dy|, dx < 0
    }
    func testZeroResolvesRight() {
        XCTAssertEqual(dominantArrow(dx: 0, dy: 0), .right)         // (0,0) tie -> horizontal +
    }
}
