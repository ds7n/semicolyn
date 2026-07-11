// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Ordering state machine that seeds a tmux pane's history before live output,
/// buffering %output that races the capture response.
final class PaneSeedStateTests: XCTestCase {
    // EP: fresh state needs a seed.
    func testFreshNeedsSeed() {
        let s = PaneSeedState()
        XCTAssertTrue(s.needsSeed)
    }

    // Output arriving before any seed is buffered (returns nothing to feed yet).
    func testOutputBeforeSeedIsBuffered() {
        var s = PaneSeedState()
        XCTAssertEqual(s.onOutput([1, 2]), [])
    }

    // Core ordering: history is fed FIRST, then buffered output in arrival order.
    func testCompleteSeedEmitsHistoryThenBufferedOutput() {
        var s = PaneSeedState()
        s.beginSeeding()
        XCTAssertEqual(s.onOutput([10]), [])       // buffered during seeding
        XCTAssertEqual(s.onOutput([11, 12]), [])   // buffered during seeding
        // history ++ o1 ++ o2
        XCTAssertEqual(s.completeSeed(history: [0, 1, 2]), [0, 1, 2, 10, 11, 12])
        XCTAssertFalse(s.needsSeed)
    }

    // After seeding, live output passes straight through.
    func testAfterSeedOutputPassesThrough() {
        var s = PaneSeedState()
        s.beginSeeding()
        _ = s.completeSeed(history: [])
        XCTAssertEqual(s.onOutput([9, 9]), [9, 9])
    }

    // Buffer is cleared after completeSeed (no replay on the next output).
    func testBufferClearedAfterSeed() {
        var s = PaneSeedState()
        s.beginSeeding()
        _ = s.onOutput([5])
        _ = s.completeSeed(history: [])   // flushes [5]
        XCTAssertEqual(s.onOutput([6]), [6])   // only the new byte, no [5] replay
    }

    // resync returns to needing a seed and drops any buffered output.
    func testResyncReturnsToUnseeded() {
        var s = PaneSeedState()
        s.beginSeeding()
        _ = s.completeSeed(history: [1])
        s.resync()
        XCTAssertTrue(s.needsSeed)
    }

    // A second seed (after resync) starts clean: buffered-during-second-seed output
    // flushes after the new history, with no first-seed leftovers.
    func testResyncThenReseedIsClean() {
        var s = PaneSeedState()
        s.beginSeeding()
        _ = s.completeSeed(history: [1, 2])
        s.resync()
        s.beginSeeding()
        _ = s.onOutput([7])
        XCTAssertEqual(s.completeSeed(history: [3, 4]), [3, 4, 7])   // no 1,2 leftovers
    }

    // completeSeed directly from .unseeded (no beginSeeding): output buffered while
    // unseeded still flushes after history, in order.
    func testCompleteSeedDirectlyFromUnseeded() {
        var s = PaneSeedState()
        _ = s.onOutput([8])                 // buffered while .unseeded
        XCTAssertEqual(s.completeSeed(history: [0]), [0, 8])
        XCTAssertFalse(s.needsSeed)         // now .seeded
        XCTAssertEqual(s.onOutput([9]), [9])  // passthrough after seed
    }
}
