// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class PromotionTests: XCTestCase {
    func testBundledDefaultCoversSpecProcesses() {
        let reg = PromotionRegistry.bundledDefault
        // Every spec §11 process name is present.
        for name in ["vim", "nvim", "less", "more", "man", "python", "python3",
                     "ipython", "node", "psql", "mysql", "sqlite3", "redis-cli"] {
            XCTAssertNotNil(reg.set(for: name), "missing bundled set for \(name)")
        }
        // htop/top/mc are Fn-spec, NOT symbol promotions.
        XCTAssertNil(reg.set(for: "htop"))
        XCTAssertNil(reg.set(for: "top"))
        XCTAssertNil(reg.set(for: "mc"))
    }

    func testBundledVimSlotsMatchSpec() {
        let vim = PromotionRegistry.bundledDefault.set(for: "vim")
        XCTAssertEqual(vim?.promote.map(\.tap), [":", "*", "%"])
        XCTAssertEqual(vim?.promote.first, PromotionSlot(tap: ":", up: ";", down: nil))
        XCTAssertEqual(vim?.promote.last, PromotionSlot(tap: "%", up: "^", down: "$"))
    }

    func testKnownProcessesIsKeySet() {
        let reg = PromotionRegistry(sets: ["vim": PromotionSet(promote: [PromotionSlot(tap: ":", up: nil, down: nil)])])
        XCTAssertEqual(reg.knownProcesses, ["vim"])
        XCTAssertNil(reg.set(for: "zsh"))
    }

    func testMergeUserOverrideWinsPerProcess() {
        let bundled = PromotionRegistry(sets: [
            "vim": PromotionSet(promote: [PromotionSlot(tap: ":", up: nil, down: nil)]),
            "psql": PromotionSet(promote: [PromotionSlot(tap: ";", up: nil, down: nil)]),
        ])
        let user = PromotionRegistry(sets: [
            "vim": PromotionSet(promote: [PromotionSlot(tap: "Z", up: nil, down: nil)]),  // overrides
            "jq": PromotionSet(promote: [PromotionSlot(tap: ".", up: nil, down: nil)]),    // new
        ])
        let merged = PromotionRegistry.merge(bundled: bundled, user: user)
        // User's whole set replaces the bundled one for vim.
        XCTAssertEqual(merged.set(for: "vim")?.promote.map(\.tap), ["Z"])
        // Untouched bundled entry survives.
        XCTAssertEqual(merged.set(for: "psql")?.promote.map(\.tap), [";"])
        // New user process is registered.
        XCTAssertEqual(merged.set(for: "jq")?.promote.map(\.tap), ["."])
    }
}
