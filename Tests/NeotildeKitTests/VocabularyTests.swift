// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

/// Vocabulary — Core tier. The learned-vocabulary suggestion engine: prefix →
/// frequency-ranked candidates.
final class VocabularyTests: XCTestCase {
    private func vocab() -> Vocabulary { Vocabulary(depth: 4, width: 1 << 14) }

    func testMarqueeClaudeBeatsCrayon() {
        // The headline behavior: learned frequency, not Apple's dictionary.
        var v = vocab()
        for _ in 0..<10 { v.record("claude") }
        for _ in 0..<2 { v.record("crayon") }
        XCTAssertEqual(v.suggestions(forPrefix: "c", limit: 3), ["claude", "crayon"])
        XCTAssertEqual(v.suggestions(forPrefix: "cl", limit: 3), ["claude"])
        XCTAssertEqual(v.suggestions(forPrefix: "z", limit: 3), [])
    }

    func testFrequencyIsPrimaryOverLexicographic() {
        // "pz" outranks "pa" by frequency despite sorting after it — proves the
        // primary key is the estimate, not the token.
        var v = vocab()
        v.record("pa", count: 2)
        v.record("pz", count: 10)
        XCTAssertEqual(v.suggestions(forPrefix: "p", limit: 2), ["pz", "pa"])
    }

    func testTieBrokenLexicographically() {
        var v = vocab()
        v.record("abd", count: 5)
        v.record("abc", count: 5)
        XCTAssertEqual(v.suggestions(forPrefix: "ab", limit: 3), ["abc", "abd"])
    }

    func testLimitCapsResults() {
        var v = vocab()
        v.record("xa", count: 5)
        v.record("xb", count: 4)
        v.record("xc", count: 3)
        XCTAssertEqual(v.suggestions(forPrefix: "x", limit: 2), ["xa", "xb"])
    }

    func testNonPositiveLimitReturnsEmpty() {
        var v = vocab()
        v.record("git", count: 5)
        XCTAssertEqual(v.suggestions(forPrefix: "g", limit: 0), [])
        XCTAssertEqual(v.suggestions(forPrefix: "g", limit: -1), [])
    }

    func testNoPrefixMatchReturnsEmpty() {
        var v = vocab()
        v.record("git", count: 5)
        XCTAssertEqual(v.suggestions(forPrefix: "k", limit: 3), [])
    }

    func testCandidatesReturnTokensWithCounts() {
        var v = vocab()
        v.record("git", count: 5)
        v.record("go", count: 2)
        // matching is byte-sorted: "git" < "go".
        XCTAssertEqual(v.candidates(forPrefix: "g"),
                       [TokenCount(token: "git", count: 5), TokenCount(token: "go", count: 2)])
    }

    func testZeroCountNotRecorded() {
        var v = vocab()
        v.record("ghost", count: 0)
        v.record("git", count: 3)
        XCTAssertEqual(v.suggestions(forPrefix: "g", limit: 3), ["git"],
                       "a zero-count token must not be indexed or suggested")
    }

    func testEmptyTokenIgnored() {
        var v = vocab()
        v.record("")
        v.record("git", count: 3)
        XCTAssertEqual(v.suggestions(forPrefix: "", limit: 3), ["git"],
                       "empty token must never be recorded or suggested")
    }

    // MARK: serialization (Critical tier — blob is a synced/seed format)

    func testSerializationRoundTrip() {
        var v = vocab()
        v.record("claude", count: 10)
        v.record("crayon", count: 2)
        let restored = Vocabulary(deserializing: v.serialize())
        XCTAssertEqual(restored, v)
        // Behavioral: restored store ranks identically.
        XCTAssertEqual(restored?.suggestions(forPrefix: "c", limit: 3), ["claude", "crayon"])
        XCTAssertEqual(restored?.candidates(forPrefix: "claude"),
                       [TokenCount(token: "claude", count: 10)])
    }

    func testEmptyVocabularyRoundTrip() {
        let v = vocab()
        let restored = Vocabulary(deserializing: v.serialize())
        XCTAssertEqual(restored, v)
        XCTAssertEqual(restored?.suggestions(forPrefix: "", limit: 3), [])
    }

    func testDeserializeRejectsTruncatedBlob() {
        var v = vocab()
        v.record("git", count: 3)
        var blob = v.serialize()
        blob.removeLast()
        XCTAssertNil(Vocabulary(deserializing: blob))
    }

    func testDeserializeRejectsWrongMagic() {
        var v = vocab()
        v.record("git")
        var blob = v.serialize()
        blob[0] = 0x00
        XCTAssertNil(Vocabulary(deserializing: blob))
    }

    func testDeserializeRejectsWrongVersion() {
        var v = vocab()
        v.record("git")
        var blob = v.serialize()
        blob[4] = 0x02
        XCTAssertNil(Vocabulary(deserializing: blob))
    }

    func testDeserializeRejectsCorruptEmbeddedSubBlob() {
        // The embedded PrefixIndex sub-blob starts right after the GVOC header
        // (magic 4 + version 1 + idxLen 4 = offset 9) with its own "GPIX" magic.
        // Flipping that magic must make the sub-deserializer fail and propagate to
        // nil — never a half-built vocabulary.
        var v = vocab()
        v.record("git", count: 3)
        var blob = v.serialize()
        blob[9] = 0x00   // corrupt the embedded PrefixIndex magic
        XCTAssertNil(Vocabulary(deserializing: blob))
    }

    func testDeserializeRejectsEmpty() {
        XCTAssertNil(Vocabulary(deserializing: []))
    }
}
