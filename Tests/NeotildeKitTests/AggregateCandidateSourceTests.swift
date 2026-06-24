// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

/// AggregateCandidateSource — Core tier. Realizes `today ⊕ rolling` on the read
/// side: union the candidate tokens, sum their counts (saturating).
final class AggregateCandidateSourceTests: XCTestCase {
    private func vocab(_ entries: [(String, UInt32)]) -> Vocabulary {
        var v = Vocabulary(depth: 4, width: 1 << 14)
        for (t, c) in entries { v.record(t, count: c) }
        return v
    }

    func testSumsCountForSharedToken() {
        let agg = AggregateCandidateSource([vocab([("git", 3)]), vocab([("git", 5)])])
        XCTAssertEqual(agg.candidates(forPrefix: "git"), [TokenCount(token: "git", count: 8)])
    }

    func testUnionsTokensSortedByBytes() {
        let agg = AggregateCandidateSource([vocab([("go", 2)]), vocab([("git", 4)])])
        XCTAssertEqual(agg.candidates(forPrefix: "g"),
                       [TokenCount(token: "git", count: 4), TokenCount(token: "go", count: 2)])
    }

    func testTokenInOnlyOneSource() {
        let agg = AggregateCandidateSource([vocab([("git", 4)]), vocab([("go", 2)])])
        XCTAssertEqual(agg.candidates(forPrefix: "gi"), [TokenCount(token: "git", count: 4)])
    }

    func testSumSaturatesNeverWraps() {
        var a = Vocabulary(depth: 4, width: 1 << 14); a.record("x", count: .max)
        var b = Vocabulary(depth: 4, width: 1 << 14); b.record("x", count: 100)
        let agg = AggregateCandidateSource([a, b])
        XCTAssertEqual(agg.candidates(forPrefix: "x"), [TokenCount(token: "x", count: .max)],
                       "summed counts must saturate at UInt32.max, not wrap")
    }

    func testEmptyAggregate() {
        let agg = AggregateCandidateSource([])
        XCTAssertEqual(agg.candidates(forPrefix: "g"), [])
    }

    func testSingleSourcePassthrough() {
        let agg = AggregateCandidateSource([vocab([("git", 3), ("go", 1)])])
        XCTAssertEqual(agg.candidates(forPrefix: "g"),
                       [TokenCount(token: "git", count: 3), TokenCount(token: "go", count: 1)])
    }
}
