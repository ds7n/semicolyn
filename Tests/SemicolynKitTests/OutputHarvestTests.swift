// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// OutputHarvest, Core tier. A bounded recency store of command-output tokens
/// that surface as prefix suggestions. See
/// `2026-06-21-predictor-output-harvesting-design`.
final class OutputHarvestTests: XCTestCase {
    private func tokens(_ h: OutputHarvest, _ prefix: String) -> [String] {
        h.candidates(forPrefix: prefix).map { $0.token }
    }

    func testHarvestedTokensMatchByPrefixNewestFirst() {
        var h = OutputHarvest()
        h.harvest(["pod-alpha", "pod-beta", "service-x"])
        // "pod-beta" harvested after "pod-alpha" → newer → ranks first.
        XCTAssertEqual(tokens(h, "pod"), ["pod-beta", "pod-alpha"])
        XCTAssertEqual(tokens(h, "service"), ["service-x"])
    }

    func testReHarvestMovesTokenToNewest() {
        var h = OutputHarvest()
        h.harvest(["a-one", "a-two"])
        XCTAssertEqual(tokens(h, "a"), ["a-two", "a-one"])
        h.harvest("a-one")                       // re-seen → now newest
        XCTAssertEqual(tokens(h, "a"), ["a-one", "a-two"])
    }

    func testCapacityEvictsOldest() {
        var h = OutputHarvest(capacity: 2)
        h.harvest(["x1", "x2", "x3"])            // x1 evicted
        XCTAssertEqual(tokens(h, "x"), ["x3", "x2"])
    }

    func testReHarvestDoesNotGrowPastCapacity() {
        var h = OutputHarvest(capacity: 2)
        h.harvest(["x1", "x2"])
        h.harvest("x1")                          // move, not add → still 2
        h.harvest("x3")                          // evicts x2 (oldest after move)
        XCTAssertEqual(tokens(h, "x"), ["x3", "x1"])
    }

    func testEmptyTokenNotHarvested() {
        var h = OutputHarvest()
        h.harvest("")
        h.harvest("real")
        XCTAssertEqual(tokens(h, ""), ["real"])
    }

    func testClearDropsEverything() {
        var h = OutputHarvest()
        h.harvest(["a", "b"])
        h.clear()
        XCTAssertEqual(tokens(h, ""), [])
    }

    func testNoPrefixMatchReturnsEmpty() {
        var h = OutputHarvest()
        h.harvest(["alpha", "beta"])
        XCTAssertEqual(tokens(h, "z"), [])
    }

    /// The pre-index implementation (linear duplicate scan over a recency array),
    /// kept here as the reference the indexed store must match exactly.
    private struct ReferenceHarvest {
        var order: [String] = []
        let capacity: Int
        mutating func harvest(_ token: String) {
            guard !token.isEmpty else { return }
            if let i = order.firstIndex(where: { $0.utf8.elementsEqual(token.utf8) }) { order.remove(at: i) }
            order.append(token)
            if order.count > capacity { order.removeFirst(order.count - capacity) }
        }
        func candidates(forPrefix prefix: String) -> [TokenCount] {
            let p = Array(prefix.utf8)
            return order.enumerated().reversed()
                .filter { p.isEmpty || $0.element.utf8.starts(with: p) }
                .map { TokenCount(token: $0.element, count: UInt32($0.offset + 1)) }
        }
    }

    /// Timing-free equivalence: a long deterministic stream with heavy repeats,
    /// evictions and clears gives exactly the reference's tokens AND recency counts
    /// after every step, for several prefixes and capacities.
    func testIndexedStoreMatchesReferenceSemantics() {
        let vocab = ["a1", "a2", "ab", "abc", "b1", "b2", "bb", "c", "", "a1", "cafe\u{301}", "caf\u{e9}"]
        for capacity in [1, 2, 3, 5, 8] {
            var h = OutputHarvest(capacity: capacity)
            var ref = ReferenceHarvest(capacity: capacity)
            var seed: UInt64 = 0x9E37_79B9_7F4A_7C15 &+ UInt64(capacity)
            for step in 0..<3000 {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let token = vocab[Int((seed >> 33) % UInt64(vocab.count))]
                if step % 997 == 996 {
                    h.clear()
                    ref.order.removeAll()
                } else {
                    h.harvest(token)
                    ref.harvest(token)
                }
                for prefix in ["", "a", "ab", "b", "c", "caf", "z"] {
                    XCTAssertEqual(h.candidates(forPrefix: prefix), ref.candidates(forPrefix: prefix),
                                   "capacity \(capacity) step \(step) prefix \(prefix)")
                }
            }
        }
    }

    /// Byte identity, as before: canonically-equal but byte-different tokens are
    /// two entries (the store compares UTF-8 bytes, not `String` equality).
    func testCanonicallyEqualButByteDifferentTokensAreDistinct() {
        var h = OutputHarvest()
        h.harvest(["cafe\u{301}", "caf\u{e9}"])
        XCTAssertEqual(h.candidates(forPrefix: "caf").count, 2)
    }

    func testRecencyCountIsHigherForNewer() {
        var h = OutputHarvest()
        h.harvest(["old", "older-nope"])   // distinct prefixes
        h.harvest("oldish")
        let c = h.candidates(forPrefix: "old")
        // newest first, and the newest carries the highest recency count.
        XCTAssertEqual(c.first?.token, "oldish")
        XCTAssertGreaterThan(c.first!.count, c.last!.count)
    }
}
