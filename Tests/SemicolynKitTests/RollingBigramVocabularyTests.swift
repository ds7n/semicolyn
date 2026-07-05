// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// RollingBigramVocabulary — Core tier. Next-token prediction with daily
/// time-windowing: record → today, rollover slides each window, queries read
/// `today ⊕ rolling_W` for one previous token's successors. See
/// `2026-06-21-predictor-bigram-rollover-design`.
final class RollingBigramVocabularyTests: XCTestCase {
    /// Summed `today ⊕ rolling_W` count for the exact successor `next` of
    /// `previous`, or nil if absent. Black-box via the public query surface.
    private func count(_ store: RollingBigramVocabulary, _ window: RollingWindow,
                       previous: String, next: String) -> UInt32? {
        store.candidates(after: previous, window: window, prefix: next)
            .first { $0.token == next }?.count
    }

    func testTodayContributesBeforeRollover() {
        var s = RollingBigramVocabulary()
        s.record(previous: "git", next: "status", count: 3)
        XCTAssertEqual(count(s, .days7, previous: "git", next: "status"), 3)
    }

    func testRolloverMovesTodayIntoRollingAndResetsToday() {
        var s = RollingBigramVocabulary()
        s.record(previous: "git", next: "status", count: 3)
        s.rollover()
        s.record(previous: "git", next: "commit", count: 2)
        // "status" is now in rolling7 (today reset, not double-counted); "commit"
        // is in the fresh today. Both surface for previous "git".
        XCTAssertEqual(count(s, .days7, previous: "git", next: "status"), 3)
        XCTAssertEqual(count(s, .days7, previous: "git", next: "commit"), 2)
    }

    func testAccumulatesAcrossInWindowDays() {
        var s = RollingBigramVocabulary()
        s.record(previous: "git", next: "status", count: 2)
        s.rollover()                               // day 1 → rolling7
        s.record(previous: "git", next: "status", count: 3)  // today
        XCTAssertEqual(count(s, .days7, previous: "git", next: "status"), 5,
                       "rolling(2) + today(3)")
    }

    func testSevenDayWindowEvictsAfterEighthRollover() {
        var s = RollingBigramVocabulary()
        s.record(previous: "git", next: "status", count: 5)
        for _ in 0..<7 { s.rollover() }
        XCTAssertEqual(count(s, .days7, previous: "git", next: "status"), 5)
        s.rollover()                               // 8th: day 1 falls out of 7d
        XCTAssertEqual(count(s, .days7, previous: "git", next: "status"), 0,
                       "day 1 must be evicted from rolling7")
    }

    func testThirtyDayRetainsWhatSevenDayEvicts() {
        var s = RollingBigramVocabulary()
        s.record(previous: "git", next: "status", count: 5)
        for _ in 0..<8 { s.rollover() }
        XCTAssertEqual(count(s, .days7, previous: "git", next: "status"), 0)
        XCTAssertEqual(count(s, .days30, previous: "git", next: "status"), 5,
                       "30d window must still hold day 1")
    }

    func testNoBleedAcrossSharedPrefixPreviousWithinWindow() {
        // The 4g no-bleed guarantee must survive windowing: `git`'s successors
        // must not include `github`'s, even summed across today ⊕ rolling.
        var s = RollingBigramVocabulary()
        s.record(previous: "git", next: "status", count: 4)
        s.record(previous: "github", next: "pulls", count: 9)
        s.rollover()
        s.record(previous: "git", next: "stash", count: 1)
        XCTAssertEqual(s.candidates(after: "git", window: .days7).map { $0.token },
                       ["stash", "status"])
    }

    func testNextSourceRanksWindowedThroughSeededSuggester() {
        // The marquee, windowed: recent `git status` beats older `git commit`.
        var user = RollingBigramVocabulary()
        user.record(previous: "git", next: "commit", count: 3)
        user.rollover()
        user.record(previous: "git", next: "status", count: 5)
        let emptySeed = BigramVocabulary()
        let s = SeededSuggester(learned: user.nextSource(after: "git", window: .days7),
                                seed: emptySeed.nextSource(after: "git"))
        XCTAssertEqual(s.suggestions(forPrefix: ""), ["status", "commit"])
    }

    func testGuardsRejectUnrecordablePairs() {
        var s = RollingBigramVocabulary()
        s.record(previous: "", next: "status", count: 5)
        s.record(previous: "git", next: "", count: 5)
        s.record(previous: "git", next: "status", count: 0)
        s.record(previous: "gi\u{1F}t", next: "status", count: 5)
        XCTAssertEqual(s.candidates(after: "git", window: .days7), [],
                       "empty/zero/separator-bearing pairs must not be recorded")
        XCTAssertNil(count(s, .days7, previous: "", next: "status"))
    }

    // MARK: serialization (Critical tier — persisted learned state)

    func testSerializationRoundTripPreservesWindowsAndAdjacency() {
        var s = RollingBigramVocabulary()
        s.record(previous: "git", next: "status", count: 2)
        s.rollover()
        s.record(previous: "git", next: "commit", count: 3)
        let restored = RollingBigramVocabulary(deserializing: s.serialize())
        XCTAssertEqual(restored, s)
        XCTAssertEqual(restored?.candidates(after: "git", window: .days7),
                       [TokenCount(token: "commit", count: 3),
                        TokenCount(token: "status", count: 2)])
    }

    func testRolloverStillWorksAfterRoundTrip() {
        var s = RollingBigramVocabulary()
        s.record(previous: "git", next: "status", count: 5)
        for _ in 0..<7 { s.rollover() }
        var restored = RollingBigramVocabulary(deserializing: s.serialize())!
        XCTAssertEqual(count(restored, .days7, previous: "git", next: "status"), 5)
        restored.rollover()
        XCTAssertEqual(count(restored, .days7, previous: "git", next: "status"), 0,
                       "restored dailies must drive correct eviction")
    }

    func testDeserializeRejectsUnigramRollingBlob() {
        // A GRLV (unigram) rolling state must not load as a GRBG bigram store.
        var u = RollingVocabulary()
        u.record("git", count: 3)
        XCTAssertNil(RollingBigramVocabulary(deserializing: u.serialize()),
                     "a unigram rolling blob must not deserialize as a bigram store")
    }

    func testDeserializeRejectsWrongMagicAndEmpty() {
        var s = RollingBigramVocabulary()
        s.record(previous: "git", next: "status")
        var blob = s.serialize()
        blob[0] = 0x00
        XCTAssertNil(RollingBigramVocabulary(deserializing: blob))
        XCTAssertNil(RollingBigramVocabulary(deserializing: []))
    }

    // MARK: storeLiteral flag (Task 3)

    func testBigramRecordCountOnlyWithholdsLiteral() {
        var bigram = RollingBigramVocabulary()
        bigram.record(previous: "login", next: "hunter2token", count: 2, storeLiteral: false)
        // The successor is not completable after "login".
        let after = bigram.candidates(after: "login", window: .days30, prefix: "hunter")
        XCTAssertTrue(after.isEmpty, "count-only bigram successor must not surface as a completion")
    }

    func testBigramRecordWithLiteralCompletes() {
        var bigram = RollingBigramVocabulary()
        bigram.record(previous: "git", next: "commit", count: 2, storeLiteral: true)
        let after = bigram.candidates(after: "git", window: .days30, prefix: "com")
        XCTAssertEqual(after.map(\.token), ["commit"])
    }
}
