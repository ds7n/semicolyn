// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ResizeDebounceTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 2_000_000)

    func testHoldsBeforeQuietWindow() {
        var d = ResizeDebounce()
        d.note(cols: 80, rows: 24, at: t0)
        XCTAssertNil(d.tick(at: t0.addingTimeInterval(0.05)))   // < 100ms
    }
    func testEmitsAfterQuietWindow() {
        var d = ResizeDebounce()
        d.note(cols: 80, rows: 24, at: t0)
        let out = d.tick(at: t0.addingTimeInterval(0.1))
        XCTAssertEqual(out?.cols, 80); XCTAssertEqual(out?.rows, 24)
    }
    func testCoalescesBurstToLatest() {
        var d = ResizeDebounce()
        d.note(cols: 80, rows: 24, at: t0)
        d.note(cols: 100, rows: 30, at: t0.addingTimeInterval(0.03))   // resets the quiet timer
        XCTAssertNil(d.tick(at: t0.addingTimeInterval(0.1)))           // only 70ms since last note
        let out = d.tick(at: t0.addingTimeInterval(0.14))
        XCTAssertEqual(out?.cols, 100); XCTAssertEqual(out?.rows, 30)  // latest wins
    }
    func testEmitsOnceThenClears() {
        var d = ResizeDebounce()
        d.note(cols: 80, rows: 24, at: t0)
        _ = d.tick(at: t0.addingTimeInterval(0.1))
        XCTAssertNil(d.tick(at: t0.addingTimeInterval(0.2)))           // nothing pending
    }

    // Suppress a no-change resize: after 80x24 is emitted, noting the SAME size again must
    // NOT re-emit (device 2026-07-20: a spring-back's layout churn re-noted the unchanged
    // grid, which sent tmux a `refresh-client` and forced a full-screen repaint = flicker).
    func testDoesNotReEmitUnchangedSize() {
        var d = ResizeDebounce()
        d.note(cols: 80, rows: 24, at: t0)
        XCTAssertNotNil(d.tick(at: t0.addingTimeInterval(0.1)))        // first emit: 80x24
        d.note(cols: 80, rows: 24, at: t0.addingTimeInterval(0.2))    // same size re-noted
        XCTAssertNil(d.tick(at: t0.addingTimeInterval(0.31)))          // suppressed: no change
    }

    // A real change after an emit still emits (the suppression is only for the UNCHANGED size).
    func testEmitsChangedSizeAfterPriorEmit() {
        var d = ResizeDebounce()
        d.note(cols: 80, rows: 24, at: t0)
        _ = d.tick(at: t0.addingTimeInterval(0.1))                     // emit 80x24
        d.note(cols: 80, rows: 40, at: t0.addingTimeInterval(0.2))    // rows changed
        let out = d.tick(at: t0.addingTimeInterval(0.31))
        XCTAssertEqual(out?.cols, 80); XCTAssertEqual(out?.rows, 40)   // still emits the change
    }
}
