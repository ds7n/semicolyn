// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// AggregateCandidateSource — Core tier. Realizes `today ⊕ rolling` on the read
/// side: union the candidate tokens, sum their counts (saturating).
final class AggregateCandidateSourceTests: XCTestCase {
    /// A source holding exact counts: answers a prefix with its matching entries.
    private struct FixedSource: CandidateSource {
        let entries: [String: UInt32]
        func candidates(forPrefix prefix: String) -> [TokenCount] {
            entries.filter { $0.key.hasPrefix(prefix) }.map { TokenCount(token: $0.key, count: $0.value) }
        }
    }

    private func vocab(_ entries: [(String, UInt32)]) -> FixedSource {
        FixedSource(entries: Dictionary(uniqueKeysWithValues: entries))
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
        let agg = AggregateCandidateSource([vocab([("x", .max)]), vocab([("x", 100)])])
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
