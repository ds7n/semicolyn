// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// LearnedVocabulary, Core tier (serialization and pruning: Critical, persisted
/// learned state). One sketch plus one prefix index: record, query, fade, prune,
/// cap, round-trip. See `2026-11-08-predictor-learned-fade-design`.
final class LearnedVocabularyTests: XCTestCase {
    /// The learned count for the exact `token`, or nil if the token isn't in the
    /// index. Black-box via the public query surface.
    private func count(_ store: LearnedVocabulary, _ token: String) -> UInt32? {
        store.learnedSource()
            .candidates(forPrefix: token)
            .first { $0.token == token }?.count
    }

    /// Every literal still held, in index (byte) order.
    private func literals(_ store: LearnedVocabulary) -> [String] {
        store.learnedSource().candidates(forPrefix: "").map(\.token)
    }

    // MARK: record / query

    func testRecordContributes() {
        var s = LearnedVocabulary()
        s.record("deploy", count: 3)
        XCTAssertEqual(count(s, "deploy"), 3)
    }

    func testAccumulatesAcrossRecords() {
        var s = LearnedVocabulary()
        s.record("deploy", count: 2)
        s.record("deploy", count: 3)
        XCTAssertEqual(count(s, "deploy"), 5)
    }

    func testEmptyAndZeroCountIgnored() {
        var s = LearnedVocabulary()
        s.record("", count: 5)
        s.record("ghost", count: 0)
        s.record("git", count: 2)
        XCTAssertEqual(count(s, "git"), 2)
        XCTAssertNil(count(s, "ghost"), "zero-count token must not be recorded")
        XCTAssertNil(count(s, ""), "empty token must not be recorded")
        XCTAssertEqual(s.literalCount, 1)
    }

    func testLiteralCountCountsDistinctLiteralsOnly() {
        var s = LearnedVocabulary()
        XCTAssertEqual(s.literalCount, 0)
        s.record("git")
        s.record("git", count: 4)
        s.record("deploy")
        s.record("hunter2", storeLiteral: false)
        XCTAssertEqual(s.literalCount, 2, "repeats and count-only tokens add no literal")
    }

    // MARK: storeLiteral split (L7 count-only)

    func testRecordCountOnlyWithholdsLiteralFromIndex() {
        var vocab = LearnedVocabulary()
        vocab.record("aws_secret_key_value", count: 2, storeLiteral: false)
        XCTAssertEqual(vocab.estimate("aws_secret_key_value"), 2, "the count still contributes")
        XCTAssertEqual(vocab.learnedSource().candidates(forPrefix: "aws_"), [],
                       "count-only token must never surface as a completion")
    }

    func testRecordWithLiteralStillCompletes() {
        var vocab = LearnedVocabulary()
        vocab.record("awsconsole", count: 2, storeLiteral: true)
        XCTAssertEqual(vocab.learnedSource().candidates(forPrefix: "aws"),
                       [TokenCount(token: "awsconsole", count: 2)])
    }

    func testContainsLiteralIsExactByteMatch() {
        var s = LearnedVocabulary()
        s.record("deploy")
        XCTAssertTrue(s.containsLiteral("deploy"))
        XCTAssertFalse(s.containsLiteral("dep"), "a prefix is not the literal")
        XCTAssertFalse(s.containsLiteral("deploys"), "a longer token is not the literal")
        XCTAssertFalse(s.containsLiteral("Deploy"), "case differs, bytes differ")
        XCTAssertFalse(s.containsLiteral(""))
    }

    func testContainsLiteralFalseForCountOnlyToken() {
        var s = LearnedVocabulary()
        s.record("hunter2", storeLiteral: false)
        XCTAssertFalse(s.containsLiteral("hunter2"), "a low-confidence token keeps no literal")
    }

    // MARK: fade (scale) and candidate rounding

    func testScaleMultipliesEstimates() {
        var s = LearnedVocabulary()
        s.record("git", count: 8)
        s.scale(by: 0.5)
        XCTAssertEqual(s.estimate("git"), 4)
        XCTAssertEqual(count(s, "git"), 4)
    }

    func testFadedLiteralStillSurfacesAsOne() {
        var s = LearnedVocabulary()
        s.record("git")
        s.scale(by: 0.3)
        XCTAssertEqual(s.estimate("git"), Float(0.3))
        XCTAssertEqual(count(s, "git"), 1, "a faded-but-unpruned literal rounds up to 1")
    }

    func testFractionalCountRoundsUp() {
        var s = LearnedVocabulary()
        s.record("git", count: 3)
        s.scale(by: 0.5)                       // 1.5
        XCTAssertEqual(count(s, "git"), 2)
    }

    func testRoundedUpCountClampsAtUInt32Max() {
        XCTAssertEqual(roundedUpCount(0), 0)
        XCTAssertEqual(roundedUpCount(1), 1)
        XCTAssertEqual(roundedUpCount(1.01), 2)
        XCTAssertEqual(roundedUpCount(Float(UInt32.max)), .max, "2^32 as Float must not trap")
        XCTAssertEqual(roundedUpCount(.greatestFiniteMagnitude), .max)
    }

    // MARK: pruneLiterals(below:)

    func testPruneBelowBoundary() {
        var s = LearnedVocabulary()
        s.record("dim")
        s.scale(by: 0.999)                      // dim = 0.999
        s.record("edge")
        s.scale(by: 0.1)                        // edge = 0.1 exactly, dim = 0.0999
        XCTAssertEqual(s.estimate("edge"), Float(0.1), "setup: edge sits exactly on the threshold")
        XCTAssertLessThan(s.estimate("dim"), Float(0.1), "setup: dim sits just below")
        XCTAssertGreaterThan(s.estimate("dim"), Float(0.0998))

        XCTAssertEqual(s.pruneLiterals(below: 0.1), 1)
        XCTAssertTrue(s.containsLiteral("edge"), "an estimate equal to the threshold is kept")
        XCTAssertFalse(s.containsLiteral("dim"), "an estimate below the threshold is pruned")
        XCTAssertEqual(literals(s), ["edge"])
    }

    func testPruneNothingBelowReturnsZero() {
        var s = LearnedVocabulary()
        s.record("git", count: 2)
        s.record("ls")
        XCTAssertEqual(s.pruneLiterals(below: 0.1), 0)
        XCTAssertEqual(literals(s), ["git", "ls"])
    }

    func testPruneLeavesCountOnlySketchMassAlone() {
        // Pruning drops literals only; the sketch keeps its (fading) counts.
        var s = LearnedVocabulary()
        s.record("rare")
        s.scale(by: 0.05)
        XCTAssertEqual(s.pruneLiterals(below: 0.1), 1)
        XCTAssertEqual(s.estimate("rare"), Float(0.05))
        XCTAssertEqual(s.literalCount, 0)
    }

    // MARK: capLiterals(max:target:)

    func testCapPrunesLowestToTarget() {
        var s = LearnedVocabulary()
        for i in 1...6 { s.record("w\(i)", count: UInt32(i)) }
        XCTAssertEqual(s.capLiterals(max: 5, target: 3), 3)
        XCTAssertEqual(literals(s).compactMap { count(s, $0) }.sorted(), [4, 5, 6])
        XCTAssertEqual(literals(s), ["w4", "w5", "w6"])
        XCTAssertEqual(s.literalCount, 3)
    }

    func testCapNoOpAtMax() {
        var s = LearnedVocabulary()
        for i in 1...5 { s.record("w\(i)", count: UInt32(i)) }
        XCTAssertEqual(s.capLiterals(max: 5, target: 3), 0)
        XCTAssertEqual(literals(s), ["w1", "w2", "w3", "w4", "w5"])
    }

    func testCapTiesBrokenByByteOrder() {
        // Equal estimates: the byte-smaller literal goes first, deterministically.
        var s = LearnedVocabulary()
        for t in ["d", "b", "a", "c"] { s.record(t) }
        XCTAssertEqual(s.capLiterals(max: 3, target: 2), 2)
        XCTAssertEqual(literals(s), ["c", "d"])
    }

    // MARK: magnitude (p90 rule)

    private func vocab() -> LearnedVocabulary { LearnedVocabulary(depth: 4, width: 1 << 12) }

    func testMagnitudeEmptyVocabularyReturnsZero() {
        XCTAssertEqual(vocab().magnitude(), 0)
    }

    func testMagnitudeSingleTokenReturnsItsOwnCount() {
        var v = vocab()
        v.record("solo", count: 42)
        XCTAssertEqual(v.magnitude(), 42)
    }

    func testMagnitudeIsHighPercentileNotMinOrMean() {
        // Counts 10, 20, ..., 100: nearest-rank p90 index floor(10 * 0.9) = 9 -> 100.
        var v = vocab()
        for i in 1...10 { v.record("t\(i)", count: UInt32(i * 10)) }
        let mag = v.magnitude()
        // The sketch only overestimates, so the true p90 (100) is a floor.
        XCTAssertGreaterThanOrEqual(mag, 100)
        XCTAssertLessThanOrEqual(mag, 200, "must stay near the true p90")
    }

    func testMagnitudeUnaffectedByLowFrequencyLongTail() {
        // [1 x 9, 500]: p90 index 9 -> 500, an average would land near 51.
        var v = vocab()
        for i in 1...9 { v.record("rare\(i)", count: 1) }
        v.record("frequent", count: 500)
        XCTAssertEqual(v.magnitude(), 500)
    }

    func testMagnitudeRoundsFadedCountsUp() {
        var v = vocab()
        v.record("solo", count: 3)
        v.scale(by: 0.5)                       // 1.5
        XCTAssertEqual(v.magnitude(), 2)
    }

    // MARK: serialization (Critical tier, persisted learned state)

    func testSerializationRoundTrip() {
        var s = LearnedVocabulary()
        s.record("deploy", count: 2)
        s.record("git", count: 3)
        s.record("hidden", storeLiteral: false)
        s.scale(by: 0.5)
        let restored = LearnedVocabulary(deserializing: s.serialize())
        XCTAssertEqual(restored, s)
        XCTAssertEqual(restored?.estimate("deploy"), 1)
        XCTAssertEqual(restored?.estimate("git"), 1.5)
        XCTAssertEqual(restored.map(literals), ["deploy", "git"])
    }

    func testSerializedLayout() {
        var s = LearnedVocabulary(depth: 2, width: 8)
        s.record("git")
        let blob = s.serialize()
        var expected: [UInt8] = Array("GLVC".utf8) + [0x01]
        var index = PrefixIndex()
        index.insert("git")
        appendSubBlob(&expected, index.serialize())
        var sketch = CountMinSketch(depth: 2, width: 8)
        sketch.add("git")
        appendSubBlob(&expected, sketch.serialize())
        XCTAssertEqual(blob, expected)
    }

    func testEmptyStateRoundTrip() {
        let s = LearnedVocabulary()
        XCTAssertEqual(LearnedVocabulary(deserializing: s.serialize()), s)
    }

    func testCustomDimensionsRoundTripWhenExpected() {
        var s = LearnedVocabulary(depth: 2, width: 64)
        s.record("git")
        XCTAssertEqual(LearnedVocabulary(deserializing: s.serialize(), depth: 2, width: 64), s)
    }

    func testDeserializeRejectsMismatchedDimensions() {
        let small = LearnedVocabulary(depth: 4, width: 1 << 12).serialize()
        XCTAssertNil(LearnedVocabulary(deserializing: small),
                     "a sketch narrower than the expected 4 x 2^14 must be rejected")
        let shallow = LearnedVocabulary(depth: 3, width: 1 << 14).serialize()
        XCTAssertNil(LearnedVocabulary(deserializing: shallow),
                     "a sketch shallower than the expected depth must be rejected")
    }

    func testDeserializeRejectsTruncated() {
        var s = LearnedVocabulary()
        s.record("git")
        var blob = s.serialize()
        blob.removeLast()
        XCTAssertNil(LearnedVocabulary(deserializing: blob))
    }

    func testDeserializeRejectsTrailingByte() {
        var s = LearnedVocabulary()
        s.record("git")
        XCTAssertNil(LearnedVocabulary(deserializing: s.serialize() + [0x00]))
    }

    func testDeserializeRejectsWrongMagic() {
        var s = LearnedVocabulary()
        s.record("git")
        var blob = s.serialize()
        blob[0] = 0x00
        XCTAssertNil(LearnedVocabulary(deserializing: blob))
    }

    func testDeserializeRejectsWrongVersion() {
        var s = LearnedVocabulary()
        s.record("git")
        var blob = s.serialize()
        blob[4] = 0x02
        XCTAssertNil(LearnedVocabulary(deserializing: blob))
        blob[4] = 0x00
        XCTAssertNil(LearnedVocabulary(deserializing: blob))
    }

    func testDeserializeRejectsEmpty() {
        XCTAssertNil(LearnedVocabulary(deserializing: []))
    }
}

/// PrefixIndex.remove, Core tier.
final class PrefixIndexRemoveTests: XCTestCase {
    func testPrefixIndexRemove() {
        var index = PrefixIndex()
        for t in ["git", "github", "gitk"] { index.insert(t) }
        index.remove("github")
        XCTAssertEqual(index.matching(prefix: "git"), ["git", "gitk"])
        XCTAssertFalse(index.contains("github"), "a removed token no longer matches")
        XCTAssertEqual(index.count, 2)

        index.remove("absent")
        index.remove("gi")                     // a prefix of held tokens, itself absent
        XCTAssertEqual(index.matching(prefix: ""), ["git", "gitk"], "removing an absent token is a no-op")
        XCTAssertEqual(index.count, 2)
    }

    func testRemoveIsByteExact() {
        var index = PrefixIndex()
        index.insert("Deploy")
        index.remove("deploy")
        XCTAssertEqual(index.matching(prefix: ""), ["Deploy"], "case differs, bytes differ: no removal")
    }

    func testRemoveKeepsSortedInvariantForLaterInserts() {
        var index = PrefixIndex()
        for t in ["a", "b", "c"] { index.insert(t) }
        index.remove("b")
        index.insert("bb")
        XCTAssertEqual(index.matching(prefix: ""), ["a", "bb", "c"])
        XCTAssertEqual(PrefixIndex(deserializing: index.serialize()), index)
    }
}
