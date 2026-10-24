// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Review fix 1 / 4: a replaced session's late callbacks are recognized as stale.
final class SessionGenerationTests: XCTestCase {
    func testFreshCaptureIsCurrent() {
        let g = SessionGeneration()
        XCTAssertTrue(g.isCurrent(g.value))
    }

    func testCaptureFromBeforeATeardownIsStale() {
        var g = SessionGeneration()
        let oldSession = g.value
        g.advance()                         // Reconnect: teardown of the old session
        let newSession = g.value
        XCTAssertFalse(g.isCurrent(oldSession))
        XCTAssertTrue(g.isCurrent(newSession))
        XCTAssertNotEqual(oldSession, newSession)
    }

    func testTwoTeardownsInOneTurnStillRejectTheOldSession() {
        // reconnect() tears down, then connect() tears down again.
        var g = SessionGeneration()
        let old = g.value
        g.advance(); g.advance()
        XCTAssertFalse(g.isCurrent(old))
        XCTAssertFalse(g.isCurrent(old &+ 1))
        XCTAssertTrue(g.isCurrent(old &+ 2))
    }
}
