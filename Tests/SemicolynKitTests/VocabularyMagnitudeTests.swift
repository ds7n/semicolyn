// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Vocabulary.magnitude(), Core tier. The ~90th-percentile representative
/// high-frequency count used to normalize differently-sized seeds onto a common
/// scale before blending.
final class VocabularyMagnitudeTests: XCTestCase {
    private func vocab() -> Vocabulary { Vocabulary(depth: 4, width: 1 << 12) }

    func testEmptyVocabularyReturnsZero() {
        let v = vocab()
        XCTAssertEqual(v.magnitude(), 0)
    }

    func testSingleTokenReturnsItsOwnCount() {
        var v = vocab()
        v.record("solo", count: 42)
        // CountMinSketch overestimates but with a wide sketch and one token the
        // estimate should be exact.
        XCTAssertEqual(v.magnitude(), 42)
    }

    func testMagnitudeIsHighPercentileNotMinOrMean() {
        // Ten tokens with counts 10, 20, ..., 100 (skewed, evenly spaced).
        // Sorted estimates: [10,20,30,40,50,60,70,80,90,100].
        // p90 nearest-rank index = floor(10 * 0.9) = 9 -> value 100 (the max).
        // min = 10, mean = 55. Bounds below distinguish p90 (~100) from both.
        var v = vocab()
        for i in 1...10 {
            v.record("t\(i)", count: UInt32(i * 10))
        }
        let mag = v.magnitude()
        // CountMinSketch only overestimates, so the true p90 (100) is a floor.
        XCTAssertGreaterThanOrEqual(mag, 100, "magnitude must be at least the true p90 (100), not below it")
        // An upper ceiling well below what min (10) or mean (55) would produce,
        // even allowing for sketch overestimation collisions in a 4x4096 table.
        XCTAssertLessThanOrEqual(mag, 200, "magnitude must stay near the true p90, not balloon or collapse to min/mean")
    }

    func testMagnitudeUnaffectedByLowFrequencyLongTail() {
        // A large long tail of rarely-used tokens (count 1) should not drag the
        // p90 down toward the min, proves this is a percentile, not an average.
        var v = vocab()
        for i in 1...9 {
            v.record("rare\(i)", count: 1)
        }
        v.record("frequent", count: 500)
        // 10 tokens sorted: [1,1,1,1,1,1,1,1,1,500]; p90 index = floor(10*0.9) = 9 -> 500.
        XCTAssertEqual(v.magnitude(), 500)
    }
}
