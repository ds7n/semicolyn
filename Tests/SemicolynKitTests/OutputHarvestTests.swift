// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// OutputHarvest — Core tier. A bounded recency store of command-output tokens
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
