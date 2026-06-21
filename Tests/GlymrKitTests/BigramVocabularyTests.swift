// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import GlymrKit

/// BigramVocabulary — Core tier. Next-token prediction: after a committed token,
/// rank the tokens that usually follow it. See
/// `2026-06-21-predictor-bigram-next-token-design`.
final class BigramVocabularyTests: XCTestCase {
    private func bigram() -> BigramVocabulary { BigramVocabulary(depth: 4, width: 1 << 16) }

    func testSuccessorsDecodedToBareNextTokens() {
        // Candidates come back as the bare `next` token, never the composite key.
        var b = bigram()
        b.record(previous: "git", next: "status", count: 5)
        b.record(previous: "git", next: "commit", count: 2)
        // candidates(after:) is byte-sorted (ranking is the suggester's job):
        // "commit" < "status".
        XCTAssertEqual(b.candidates(after: "git"),
                       [TokenCount(token: "commit", count: 2),
                        TokenCount(token: "status", count: 5)])
    }

    func testNextPrefixNarrowsSuccessors() {
        var b = bigram()
        b.record(previous: "git", next: "status", count: 5)
        b.record(previous: "git", next: "stash", count: 3)
        b.record(previous: "git", next: "commit", count: 4)
        XCTAssertEqual(b.candidates(after: "git", prefix: "st"),
                       [TokenCount(token: "stash", count: 3),
                        TokenCount(token: "status", count: 5)])
    }

    func testEmptyPrefixReturnsAllSuccessors() {
        var b = bigram()
        b.record(previous: "kubectl", next: "get", count: 3)
        b.record(previous: "kubectl", next: "apply", count: 1)
        XCTAssertEqual(b.candidates(after: "kubectl").map { $0.token }, ["apply", "get"])
    }

    func testPreviousPrefixDoesNotBleedAcrossTokens() {
        // The contiguous-run guarantee: `git`'s successors must not include
        // `github`'s, even though "git" is a byte-prefix of "github". This is the
        // load-bearing correctness property of the US-separator encoding.
        var b = bigram()
        b.record(previous: "git", next: "status", count: 5)
        b.record(previous: "github", next: "pulls", count: 9)
        XCTAssertEqual(b.candidates(after: "git").map { $0.token }, ["status"])
        XCTAssertEqual(b.candidates(after: "github").map { $0.token }, ["pulls"])
    }

    func testUnknownPreviousReturnsEmpty() {
        var b = bigram()
        b.record(previous: "git", next: "status", count: 5)
        XCTAssertEqual(b.candidates(after: "docker"), [])
    }

    func testEmptyPreviousNotRecorded() {
        var b = bigram()
        b.record(previous: "", next: "status", count: 5)
        // Nothing learned → querying the empty previous finds nothing.
        XCTAssertEqual(b.candidates(after: ""), [])
    }

    func testEmptyNextNotRecorded() {
        var b = bigram()
        b.record(previous: "git", next: "", count: 5)
        XCTAssertEqual(b.candidates(after: "git"), [])
    }

    func testZeroCountNotRecorded() {
        var b = bigram()
        b.record(previous: "git", next: "status", count: 0)
        XCTAssertEqual(b.candidates(after: "git"), [],
                       "a zero-count adjacency must not be recorded")
    }

    func testSeparatorByteInTokenNotRecorded() {
        // A token carrying the US (0x1F) separator would corrupt the encoding;
        // both sides are rejected, fail-closed.
        var b = bigram()
        b.record(previous: "gi\u{1F}t", next: "status", count: 5)
        b.record(previous: "git", next: "sta\u{1F}tus", count: 5)
        XCTAssertEqual(b.candidates(after: "git"), [],
                       "a token containing the separator byte must be rejected")
    }

    // MARK: - Composition (the design's payoff: windowing/deference come free)

    func testNextSourceRanksByFrequencyThroughSeededSuggester() {
        // The marquee: commit `git`, see `status` first because it's most-used.
        var user = bigram()
        for _ in 0..<5 { user.record(previous: "git", next: "status") }
        for _ in 0..<2 { user.record(previous: "git", next: "stash") }
        let emptySeed = bigram()
        let s = SeededSuggester(learned: user.nextSource(after: "git"),
                                seed: emptySeed.nextSource(after: "git"))
        XCTAssertEqual(s.suggestions(forPrefix: ""), ["status", "stash"])
    }

    func testSeedSuccessorsSurfaceWhenUserHasNoHistory() {
        // N-gram deference: no learned `git X` → seed `git push` fills the slot.
        var seed = bigram()
        seed.record(previous: "git", next: "push", count: 3)
        let user = bigram()
        let s = SeededSuggester(learned: user.nextSource(after: "git"),
                                seed: seed.nextSource(after: "git"))
        XCTAssertEqual(s.suggestions(forPrefix: ""), ["push"])
    }
}
