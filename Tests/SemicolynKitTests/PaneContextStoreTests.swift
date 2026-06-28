// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class PaneContextStoreTests: XCTestCase {
    private let p0 = PaneID(raw: 0)
    private let p1 = PaneID(raw: 1)

    func testPerPaneIndependentEngagement() {
        var store = PaneContextStore(knownProcesses: ["vim", "python"])
        _ = store.observe([(p0, "vim"), (p1, "python")], at: 0.0)
        let changed = store.observe([(p0, "vim"), (p1, "python")], at: 0.25)
        XCTAssertEqual(changed, [p0, p1])             // both crossed the 250ms threshold
        XCTAssertEqual(store.context(for: p0), "vim")
        XCTAssertEqual(store.context(for: p1), "python")
    }

    func testOnlyChangedPanesReported() {
        var store = PaneContextStore(knownProcesses: ["vim", "python"])
        _ = store.observe([(p0, "vim"), (p1, "zsh")], at: 0.0)
        let changed = store.observe([(p0, "vim"), (p1, "zsh")], at: 0.25)
        XCTAssertEqual(changed, [p0])                 // p1 (zsh, unknown) never engaged
        XCTAssertNil(store.context(for: p1))
    }

    func testClosedPaneIsPrunedAndForgotten() {
        var store = PaneContextStore(knownProcesses: ["vim"])
        _ = store.observe([(p0, "vim"), (p1, "vim")], at: 0.0)
        _ = store.observe([(p0, "vim"), (p1, "vim")], at: 0.25)
        XCTAssertEqual(store.context(for: p1), "vim")
        // p1 disappears from the snapshot → pruned.
        _ = store.observe([(p0, "vim")], at: 0.5)
        XCTAssertNil(store.context(for: p1))
        XCTAssertEqual(store.context(for: p0), "vim")
    }

    func testUnknownPaneContextIsNil() {
        let store = PaneContextStore(knownProcesses: ["vim"])
        XCTAssertNil(store.context(for: p0))
    }
}
