// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import SemicolynKit
@testable import SeedKit

/// SeedBuilder — Core tier. Token sequences → unigram + bigram seed blobs that
/// round-trip into queryable stores. See
/// `2026-06-21-predictor-seed-ingestion-design`.
final class SeedBuilderTests: XCTestCase {
    func testBigramAdjacencyFromSequences() {
        var b = SeedBuilder()
        b.ingest(["git", "commit", "--message"])
        let bigram = BigramVocabulary(deserializing: b.blobs().bigram)
        // (git, commit) and (commit, --message) are the adjacent pairs.
        XCTAssertEqual(bigram?.candidates(after: "git").map { $0.token }, ["commit"])
        XCTAssertEqual(bigram?.candidates(after: "commit").map { $0.token }, ["--message"])
    }

    func testRepeatedAdjacencyAccumulatesCount() {
        var b = SeedBuilder()
        for _ in 0..<3 { b.ingest(["git", "status"]) }
        b.ingest(["git", "commit"])
        let bigram = BigramVocabulary(deserializing: b.blobs().bigram)
        XCTAssertEqual(bigram?.candidates(after: "git"),
                       [TokenCount(token: "commit", count: 1),
                        TokenCount(token: "status", count: 3)])
    }

    func testUnigramCountsAccumulate() {
        var b = SeedBuilder()
        b.ingest(["git", "status"])
        b.ingest(["git", "commit"])
        let uni = Vocabulary(deserializing: b.blobs().unigram)
        // "git" seen twice, "status"/"commit" once each.
        XCTAssertEqual(uni?.candidates(forPrefix: "git"), [TokenCount(token: "git", count: 2)])
        XCTAssertEqual(uni?.suggestions(forPrefix: "", limit: 1), ["git"])
    }

    func testMarqueeSeedSurfacesThroughSeededSuggester() {
        // The payoff: a seed built from a corpus drives next-token suggestions for
        // a user with no history of their own.
        var b = SeedBuilder()
        for _ in 0..<5 { b.ingest(["git", "status"]) }
        for _ in 0..<2 { b.ingest(["git", "commit"]) }
        let seed = BigramVocabulary(deserializing: b.blobs().bigram)!
        let user = BigramVocabulary()
        let s = SeededSuggester(learned: user.nextSource(after: "git"),
                                seed: seed.nextSource(after: "git"))
        XCTAssertEqual(s.suggestions(forPrefix: ""), ["status", "commit"])
    }

    func testSingleTokenSequenceHasNoBigram() {
        var b = SeedBuilder()
        b.ingest(["ls"])
        let bigram = BigramVocabulary(deserializing: b.blobs().bigram)
        XCTAssertEqual(bigram?.candidates(after: "ls"), [],
                       "a lone token forms no adjacency")
        let uni = Vocabulary(deserializing: b.blobs().unigram)
        XCTAssertEqual(uni?.candidates(forPrefix: "ls"), [TokenCount(token: "ls", count: 1)])
    }

    func testEmptyBuilderProducesValidEmptyBlobs() {
        let b = SeedBuilder()
        let blobs = b.blobs()
        XCTAssertNotNil(Vocabulary(deserializing: blobs.unigram))
        XCTAssertNotNil(BigramVocabulary(deserializing: blobs.bigram))
        XCTAssertEqual(BigramVocabulary(deserializing: blobs.bigram)?.candidates(after: "git"), [])
    }
}
