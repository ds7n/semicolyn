// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import GlymrKit

/// RollingVocabulary — Core tier. The daily-windowing state machine: record →
/// today, rollover slides each window, queries read today ⊕ rolling.
final class RollingVocabularyTests: XCTestCase {
    /// Summed `today ⊕ rolling_<window>` count for the exact `token`, or nil if
    /// the token isn't in the index. Black-box via the public query surface.
    private func count(_ store: RollingVocabulary, _ window: RollingWindow,
                       _ token: String) -> UInt32? {
        store.learnedSource(window: window)
            .candidates(forPrefix: token)
            .first { $0.token == token }?.count
    }

    func testTodayContributesBeforeRollover() {
        var s = RollingVocabulary()
        s.record("deploy", count: 3)
        XCTAssertEqual(count(s, .days7, "deploy"), 3)
    }

    func testRolloverMovesTodayIntoRollingAndResetsToday() {
        var s = RollingVocabulary()
        s.record("deploy", count: 3)
        s.rollover()
        s.record("git", count: 2)
        // "deploy" is now in rolling7 (today was reset, so it isn't double-counted);
        // "git" is in the fresh today.
        XCTAssertEqual(count(s, .days7, "deploy"), 3)
        XCTAssertEqual(count(s, .days7, "git"), 2)
    }

    func testAccumulatesAcrossInWindowDays() {
        var s = RollingVocabulary()
        s.record("deploy", count: 2)
        s.rollover()                       // day 1: deploy 2 → rolling7
        s.record("deploy", count: 3)       // today: deploy 3
        XCTAssertEqual(count(s, .days7, "deploy"), 5, "rolling(2) + today(3)")
    }

    func testSevenDayWindowEvictsAfterEighthRollover() {
        var s = RollingVocabulary()
        s.record("old", count: 5)
        for _ in 0..<7 { s.rollover() }    // "old" sealed as day 1, still within 7d
        XCTAssertEqual(count(s, .days7, "old"), 5)
        s.rollover()                       // 8th: day 1 falls out of the 7d window
        XCTAssertEqual(count(s, .days7, "old"), 0, "day 1 must be evicted from rolling7")
    }

    func testThirtyDayRetainsWhatSevenDayEvicts() {
        var s = RollingVocabulary()
        s.record("old", count: 5)
        for _ in 0..<8 { s.rollover() }    // evicted from 7d, still well within 30d
        XCTAssertEqual(count(s, .days7, "old"), 0)
        XCTAssertEqual(count(s, .days30, "old"), 5, "30d window must still hold day 1")
    }

    func testNinetyDayBoundaryEvictsAtNinetyFirstRollover() {
        var s = RollingVocabulary()
        s.record("ancient", count: 7)
        for _ in 0..<90 { s.rollover() }   // day 1 still the oldest day inside 90d
        XCTAssertEqual(count(s, .days90, "ancient"), 7)
        s.rollover()                       // 91st: day 1 falls out (and is pruned)
        XCTAssertEqual(count(s, .days90, "ancient"), 0)
    }

    func testSevenDayEvictionStaysCorrectAfterPruningIsActive() {
        // Drive past the 90-day horizon so the dailies array is being pruned
        // (shifted) on every rollover, then verify the 7-day window still evicts
        // at exactly the right boundary — catching any index drift introduced by
        // the post-prune array shift.
        var s = RollingVocabulary()
        for _ in 0..<95 { s.rollover() }       // pruning now active each rollover
        s.record("fresh", count: 4)
        s.rollover()                            // seal "fresh" (1st rollover since recording)
        for _ in 0..<6 { s.rollover() }         // 7 total → still inside the 7-day window
        XCTAssertEqual(count(s, .days7, "fresh"), 4, "eviction must stay correct after prunes")
        s.rollover()                            // 8th → evicted
        XCTAssertEqual(count(s, .days7, "fresh"), 0)
    }

    func testEmptyAndZeroCountIgnored() {
        var s = RollingVocabulary()
        s.record("", count: 5)
        s.record("ghost", count: 0)
        s.record("git", count: 2)
        XCTAssertEqual(count(s, .days7, "git"), 2)
        XCTAssertNil(count(s, .days7, "ghost"), "zero-count token must not be recorded")
        XCTAssertNil(count(s, .days7, ""), "empty token must not be recorded")
    }
}
