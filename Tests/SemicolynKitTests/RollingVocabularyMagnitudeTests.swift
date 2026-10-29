// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// RollingVocabulary.magnitude(window:), Core tier. The ~90th-percentile count of
/// `today ⊕ rolling_<window>` that puts the learned source on the seeds' scale
/// before blending.
final class RollingVocabularyMagnitudeTests: XCTestCase {
    private func vocab() -> RollingVocabulary { RollingVocabulary(depth: 4, width: 1 << 12) }

    func testEmptyVocabularyReturnsZero() {
        XCTAssertEqual(vocab().magnitude(window: .days30), 0)
    }

    func testSingleTokenReturnsItsOwnCount() {
        var v = vocab()
        v.record("solo", count: 42)
        XCTAssertEqual(v.magnitude(window: .days30), 42)
    }

    func testMagnitudeIsHighPercentileNotMinOrMean() {
        // Counts 10, 20, ..., 100: nearest-rank p90 index floor(10 * 0.9) = 9 -> 100.
        // min = 10 and mean = 55 both fall below the floor asserted here.
        var v = vocab()
        for i in 1...10 { v.record("t\(i)", count: UInt32(i * 10)) }
        let mag = v.magnitude(window: .days30)
        // The sketch only overestimates, so the true p90 (100) is a floor.
        XCTAssertGreaterThanOrEqual(mag, 100)
        XCTAssertLessThanOrEqual(mag, 200, "must stay near the true p90")
    }

    func testMagnitudeUnaffectedByLowFrequencyLongTail() {
        // [1 x 9, 500]: p90 index 9 -> 500, an average would land near 51.
        var v = vocab()
        for i in 1...9 { v.record("rare\(i)", count: 1) }
        v.record("frequent", count: 500)
        XCTAssertEqual(v.magnitude(window: .days30), 500)
    }

    func testMagnitudeSumsTodayAndTheRollingWindow() {
        var v = vocab()
        v.record("deploy", count: 30)
        v.rollover()                       // 30 sealed into the rolling windows
        v.record("deploy", count: 12)      // 12 more today
        XCTAssertEqual(v.magnitude(window: .days7), 42)
    }

    func testMagnitudeReadsOnlyTheRequestedWindow() {
        var v = vocab()
        v.record("old", count: 5)
        for _ in 0..<8 { v.rollover() }    // day 1 leaves rolling7, stays in rolling30
        XCTAssertEqual(v.magnitude(window: .days7), 0, "an evicted count must not inflate the 7-day magnitude")
        XCTAssertEqual(v.magnitude(window: .days30), 5)
    }
}
