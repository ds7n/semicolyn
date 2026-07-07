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

    func testAutoEngageLocksAndDisengageReturnsOff() {
        var f = FnState()
        f.autoEngage(); XCTAssertEqual(f.mode, .locked)
        XCTAssertTrue(f.engaged)
        f.autoDisengage(); XCTAssertEqual(f.mode, .off)
    }

    func testUserOverrideBlocksReengageUntilEpisodeEnds() {
        var f = FnState()
        f.autoEngage()                 // auto-locked
        f.tap()                        // user turns it off during the auto episode
        XCTAssertEqual(f.mode, .off)
        f.autoEngage()                 // same episode: must NOT re-lock
        XCTAssertEqual(f.mode, .off)
        f.autoDisengage()              // episode ends → override resets
        f.autoEngage()                 // new episode: locks again
        XCTAssertEqual(f.mode, .locked)
    }

    func testManualRelockClearsOverride() {
        var f = FnState()
        f.autoEngage(); f.tap()        // auto-locked, then user taps off → override set
        f.tap(); f.tap()               // off→armed→locked: manual re-lock clears override
        XCTAssertEqual(f.mode, .locked)
        f.tap()                        // off again — but override was cleared by the relock...
        f.autoEngage()                 // ...so a fresh autoEngage re-locks
        XCTAssertEqual(f.mode, .locked)
    }

    func testResetClearsEverything() {
        var f = FnState()
        f.autoEngage(); f.tap()        // off + override
        f.reset()
        f.autoEngage(); XCTAssertEqual(f.mode, .locked)  // override cleared by reset
    }

    func testAutoDisengageDoesNotClobberManualFn() {
        var f = FnState()
        f.tap()                          // user manually arms in a non-auto context
        XCTAssertEqual(f.mode, .armed)
        f.autoDisengage()                // routine poll, no auto-episode active
        XCTAssertEqual(f.mode, .armed)   // must NOT be cleared
        f.tap()                          // armed → locked (user manually locks)
        XCTAssertEqual(f.mode, .locked)
        f.autoDisengage()                // poll again
        XCTAssertEqual(f.mode, .locked)  // manual lock survives
    }
}
