// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class FnStateTests: XCTestCase {
    func testTapCyclesOffArmedLockedOff() {
        var f = FnState()
        XCTAssertEqual(f.mode, .off)
        f.tap(); XCTAssertEqual(f.mode, .armed)
        f.tap(); XCTAssertEqual(f.mode, .locked)
        f.tap(); XCTAssertEqual(f.mode, .off)
    }

    func testFireFKeyClearsArmedButNotLocked() {
        var f = FnState()
        f.tap()                      // armed
        f.fireFKey(); XCTAssertEqual(f.mode, .off)
        f.tap(); f.tap()             // armed → locked (manual lock via tap-cycle)
        f.fireFKey(); XCTAssertEqual(f.mode, .locked)  // firing does not exit lock
    }

    func testResetReturnsArmedAndLockedToOff() {
        var f = FnState()
        f.tap()                        // armed
        f.reset(); XCTAssertEqual(f.mode, .off)
        XCTAssertFalse(f.engaged)
        f.tap(); f.tap()               // locked
        f.reset(); XCTAssertEqual(f.mode, .off)
        f.tap(); XCTAssertEqual(f.mode, .armed)   // cycle restarts from off
    }
}
