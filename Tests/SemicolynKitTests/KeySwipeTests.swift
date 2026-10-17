// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class KeySwipeTests: XCTestCase {

    // MARK: - Clear vertical swipes

    func testStraightUpIsUp() {
        XCTAssertEqual(keySwipeDirection(dx: 0, dy: -30), .up)
    }

    func testStraightDownIsDown() {
        XCTAssertEqual(keySwipeDirection(dx: 0, dy: 30), .down)
    }

    func testSlightlySlantedUpIsStillUp() {
        XCTAssertEqual(keySwipeDirection(dx: 10, dy: -20), .up)
    }

    // MARK: - Distance threshold (BVA around 12pt)

    func testAtThresholdIsIgnored() {
        XCTAssertNil(keySwipeDirection(dx: 0, dy: -12))
    }

    func testJustPastThresholdFires() {
        XCTAssertEqual(keySwipeDirection(dx: 0, dy: -12.5), .up)
        XCTAssertEqual(keySwipeDirection(dx: 0, dy: 12.5), .down)
    }

    // MARK: - Horizontal drags belong to the scrolling middle

    func testHorizontalScrollIsNotASwipe() {
        XCTAssertNil(keySwipeDirection(dx: -80, dy: 0))
    }

    func testHorizontalScrollWithVerticalDriftIsNotASwipe() {
        // A sideways scroll whose finger drifts down 20pt must not send the swipe-down key.
        XCTAssertNil(keySwipeDirection(dx: -60, dy: 20))
    }

    // MARK: - Dominance boundary (vertical must exceed 1.5x horizontal)

    func testExactlyOneAndAHalfTimesIsIgnored() {
        XCTAssertNil(keySwipeDirection(dx: 20, dy: -30))
    }

    func testJustOverOneAndAHalfTimesFires() {
        XCTAssertEqual(keySwipeDirection(dx: 20, dy: -30.5), .up)
    }

    func testDiagonalIsIgnored() {
        XCTAssertNil(keySwipeDirection(dx: 25, dy: 25))
    }
}
