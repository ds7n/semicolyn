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

    func testDoubleTapLocks() {
        var f = FnState()
        f.doubleTap(); XCTAssertEqual(f.mode, .locked)
    }

    func testFireFKeyClearsArmedButNotLocked() {
        var f = FnState()
        f.tap()                      // armed
        f.fireFKey(); XCTAssertEqual(f.mode, .off)
        f.doubleTap()                // locked
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
        f.autoEngage(); f.tap()        // override set
        f.doubleTap()                  // manual re-lock clears override
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
        f.doubleTap()                    // user manually locks
        f.autoDisengage()                // poll again
        XCTAssertEqual(f.mode, .locked)  // manual lock survives
    }
}
