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

    // rawContext(for:) is the un-debounced, un-gated current command the alt-scroll
    // decider reads: it must report a NON-known app (e.g. "claude", absent from the
    // keybar's knownProcesses) that engagedContext never surfaces. Bug 1 (2026-07-16):
    // alt-scroll read engagedContext -> nil for Claude -> arrows not pageKeys.
    func testRawContextReportsUnknownApp() {
        var store = PaneContextStore(knownProcesses: ["vim"])  // claude NOT known
        _ = store.observe([(p0, "claude")], at: 0.0)
        XCTAssertEqual(store.rawContext(for: p0), "claude")     // raw sees it
        XCTAssertNil(store.context(for: p0))                    // engaged does NOT (unknown)
    }

    // rawContext is immediate: available on the FIRST snapshot, no 250ms engage dwell.
    // (engagedContext needs two same readings 250ms apart; raw needs one.)
    func testRawContextIsImmediateNoDwell() {
        var store = PaneContextStore(knownProcesses: ["vim"])
        _ = store.observe([(p0, "vim")], at: 0.0)              // single reading, t=0
        XCTAssertEqual(store.rawContext(for: p0), "vim")        // raw available now
        XCTAssertNil(store.context(for: p0))                    // engaged not yet (needs dwell)
    }

    // rawContext tracks the latest reading (a pane whose command changed).
    func testRawContextTracksLatestReading() {
        var store = PaneContextStore(knownProcesses: ["vim"])
        _ = store.observe([(p0, "bash")], at: 0.0)
        XCTAssertEqual(store.rawContext(for: p0), "bash")
        _ = store.observe([(p0, "claude")], at: 0.1)
        XCTAssertEqual(store.rawContext(for: p0), "claude")
    }

    // A pruned (closed) pane has no raw context either.
    func testRawContextNilForPrunedPane() {
        var store = PaneContextStore(knownProcesses: ["vim"])
        _ = store.observe([(p0, "claude"), (p1, "bash")], at: 0.0)
        XCTAssertEqual(store.rawContext(for: p1), "bash")
        _ = store.observe([(p0, "claude")], at: 0.1)            // p1 closed
        XCTAssertNil(store.rawContext(for: p1))
    }
}
