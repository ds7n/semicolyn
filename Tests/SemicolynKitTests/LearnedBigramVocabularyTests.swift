// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// LearnedBigramVocabulary, Core tier (serialization and pruning: Critical).
/// Next-token prediction over one composite-key sketch: record, query one
/// previous token's successors, fade, prune, cap, round-trip. See
/// `2026-11-08-predictor-learned-fade-design`.
final class LearnedBigramVocabularyTests: XCTestCase {
    /// The count for the exact successor `next` of `previous`, or nil if absent.
    /// Black-box via the public query surface.
    private func count(_ store: LearnedBigramVocabulary, previous: String, next: String) -> UInt32? {
        store.candidates(after: previous, prefix: next)
            .first { $0.token == next }?.count
    }

    // MARK: record / query

    func testRecordContributes() {
        var s = LearnedBigramVocabulary()
        s.record(previous: "git", next: "status", count: 3)
        XCTAssertEqual(count(s, previous: "git", next: "status"), 3)
    }

    func testAccumulatesAcrossRecords() {
        var s = LearnedBigramVocabulary()
        s.record(previous: "git", next: "status", count: 2)
        s.record(previous: "git", next: "status", count: 3)
        XCTAssertEqual(count(s, previous: "git", next: "status"), 5)
    }

    func testNoBleedAcrossSharedPrefixPrevious() {
        // `git`'s successors must not include `github`'s.
        var s = LearnedBigramVocabulary()
        s.record(previous: "git", next: "status", count: 4)
        s.record(previous: "github", next: "pulls", count: 9)
        s.record(previous: "git", next: "stash", count: 1)
        XCTAssertEqual(s.candidates(after: "git"),
                       [TokenCount(token: "stash", count: 1), TokenCount(token: "status", count: 4)])
    }

    func testNextSourceRanks() {
        var user = LearnedBigramVocabulary()
        user.record(previous: "git", next: "commit", count: 3)
        user.record(previous: "git", next: "status", count: 5)
        XCTAssertEqual(user.nextSource(after: "git").candidates(forPrefix: "").sorted { $0.count > $1.count },
                       [TokenCount(token: "status", count: 5), TokenCount(token: "commit", count: 3)])
    }

    func testGuardsRejectUnrecordablePairs() {
        var s = LearnedBigramVocabulary()
        s.record(previous: "", next: "status", count: 5)
        s.record(previous: "git", next: "", count: 5)
        s.record(previous: "git", next: "status", count: 0)
        s.record(previous: "gi\u{1F}t", next: "status", count: 5)
        s.record(previous: "git", next: "sta\u{1F}tus", count: 5)
        XCTAssertEqual(s.candidates(after: "git"), [],
                       "empty/zero/separator-bearing pairs must not be recorded")
        XCTAssertNil(count(s, previous: "", next: "status"))
        XCTAssertEqual(s.literalCount, 0)
    }

    func testLiteralCountCountsDistinctPairs() {
        var s = LearnedBigramVocabulary()
        s.record(previous: "git", next: "status")
        s.record(previous: "git", next: "status")
        s.record(previous: "git", next: "commit")
        s.record(previous: "login", next: "hunter2", storeLiteral: false)
        XCTAssertEqual(s.literalCount, 2)
    }

    // MARK: storeLiteral flag

    func testBigramRecordCountOnlyWithholdsLiteral() {
        var bigram = LearnedBigramVocabulary()
        bigram.record(previous: "login", next: "hunter2token", count: 2, storeLiteral: false)
        XCTAssertEqual(bigram.candidates(after: "login", prefix: "hunter"), [],
                       "count-only bigram successor must not surface as a completion")
    }

    func testBigramRecordWithLiteralCompletes() {
        var bigram = LearnedBigramVocabulary()
        bigram.record(previous: "git", next: "commit", count: 2, storeLiteral: true)
        XCTAssertEqual(bigram.candidates(after: "git", prefix: "com"),
                       [TokenCount(token: "commit", count: 2)])
    }

    // MARK: fade / prune / cap

    func testFadedLiteralStillSurfacesAsOne() {
        var s = LearnedBigramVocabulary()
        s.record(previous: "git", next: "status")
        s.scale(by: 0.3)
        XCTAssertEqual(count(s, previous: "git", next: "status"), 1)
    }

    func testScaleMultipliesCounts() {
        var s = LearnedBigramVocabulary()
        s.record(previous: "git", next: "status", count: 8)
        s.scale(by: 0.25)
        XCTAssertEqual(count(s, previous: "git", next: "status"), 2)
    }

    func testPruneBelowBoundary() {
        var s = LearnedBigramVocabulary()
        s.record(previous: "git", next: "dim")
        s.scale(by: 0.999)
        s.record(previous: "git", next: "edge")
        s.scale(by: 0.1)                        // edge = 0.1 exactly, dim = 0.0999
        XCTAssertEqual(s.pruneLiterals(below: 0.1), 1)
        XCTAssertEqual(s.candidates(after: "git"), [TokenCount(token: "edge", count: 1)])
        XCTAssertEqual(s.literalCount, 1)
    }

    func testCapPrunesLowestToTarget() {
        var s = LearnedBigramVocabulary()
        for i in 1...6 { s.record(previous: "p", next: "n\(i)", count: UInt32(i)) }
        XCTAssertEqual(s.capLiterals(max: 5, target: 3), 3)
        XCTAssertEqual(s.candidates(after: "p").map(\.count).sorted(), [4, 5, 6])
        XCTAssertEqual(s.candidates(after: "p").map(\.token), ["n4", "n5", "n6"])
    }

    func testCapNoOpAtMax() {
        var s = LearnedBigramVocabulary()
        for i in 1...5 { s.record(previous: "p", next: "n\(i)", count: UInt32(i)) }
        XCTAssertEqual(s.capLiterals(max: 5, target: 3), 0)
        XCTAssertEqual(s.literalCount, 5)
    }

    // MARK: serialization (Critical tier, persisted learned state)

    func testSerializationRoundTripPreservesAdjacency() {
        var s = LearnedBigramVocabulary()
        s.record(previous: "git", next: "status", count: 2)
        s.record(previous: "git", next: "commit", count: 3)
        let restored = LearnedBigramVocabulary(deserializing: s.serialize())
        XCTAssertEqual(restored, s)
        XCTAssertEqual(restored?.candidates(after: "git"),
                       [TokenCount(token: "commit", count: 3),
                        TokenCount(token: "status", count: 2)])
    }

    func testSerializedLayoutWrapsInnerVocabulary() {
        let s = LearnedBigramVocabulary()
        let blob = s.serialize()
        XCTAssertEqual(Array(blob[0..<5]), Array("GLBG".utf8) + [0x01])
        XCTAssertEqual(Array(blob[5...]), LearnedVocabulary(depth: 4, width: 1 << 16).serialize())
    }

    func testDeserializeRejectsUnigramBlob() {
        // A GLVC (unigram) state must not load as a GLBG bigram store.
        var u = LearnedVocabulary(depth: 4, width: 1 << 16)
        u.record("git", count: 3)
        XCTAssertNil(LearnedBigramVocabulary(deserializing: u.serialize()),
                     "a unigram blob must not deserialize as a bigram store")
    }

    func testDeserializeRejectsMismatchedDimensions() {
        // A bigram wrapper around a unigram-sized (4 x 2^14) sketch is rejected.
        var blob: [UInt8] = Array("GLBG".utf8) + [0x01]
        blob += LearnedVocabulary().serialize()
        XCTAssertNil(LearnedBigramVocabulary(deserializing: blob))
    }

    func testDeserializeRejectsWrongMagicVersionTrailingAndEmpty() {
        var s = LearnedBigramVocabulary()
        s.record(previous: "git", next: "status")
        let good = s.serialize()
        var badMagic = good
        badMagic[0] = 0x00
        XCTAssertNil(LearnedBigramVocabulary(deserializing: badMagic))
        var badVersion = good
        badVersion[4] = 0x02
        XCTAssertNil(LearnedBigramVocabulary(deserializing: badVersion))
        XCTAssertNil(LearnedBigramVocabulary(deserializing: good + [0x00]))
        XCTAssertNil(LearnedBigramVocabulary(deserializing: []))
    }
}
