// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

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
}
