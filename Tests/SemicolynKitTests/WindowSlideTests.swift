// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class WindowSlideTests: XCTestCase {
    // Rightward swipe -> delta -1 (previous window): current exits RIGHT, new enters from LEFT.
    func testPreviousSlidesOutRightInLeft() {
        let d = windowSlideDirection(delta: -1)
        XCTAssertEqual(d?.out, .right)
        XCTAssertEqual(d?.in, .left)
    }
    // Leftward swipe -> delta +1 (next window): current exits LEFT, new enters from RIGHT.
    func testNextSlidesOutLeftInRight() {
        let d = windowSlideDirection(delta: 1)
        XCTAssertEqual(d?.out, .left)
        XCTAssertEqual(d?.in, .right)
    }
    // Zero delta -> no switch, no transition.
    func testZeroDeltaNoTransition() {
        XCTAssertNil(windowSlideDirection(delta: 0))
    }
    // Magnitude does not change direction: large deltas map by SIGN like ±1.
    func testMagnitudeMapsBySign() {
        XCTAssertEqual(windowSlideDirection(delta: -5)?.out, .right)
        XCTAssertEqual(windowSlideDirection(delta: 5)?.out, .left)
    }
}
