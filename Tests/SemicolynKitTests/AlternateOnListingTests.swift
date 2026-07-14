// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class AlternateOnListingTests: XCTestCase {
    // Alt-screen pane (flag 1) → true.
    func testParsesAltOnPane() {
        let r = parseAlternateOnListing(["%0 1"])
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].pane, PaneID(raw: 0))
        XCTAssertTrue(r[0].isAlt)
    }

    // Normal-screen pane (flag 0) → false. NOTE: the result tuple array is not
    // Equatable, so always assert on `.count` + individual fields, never `==` on the
    // whole array.
    func testParsesAltOffPane() {
        let r = parseAlternateOnListing(["%10 0"])
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].pane, PaneID(raw: 10))
        XCTAssertFalse(r[0].isAlt)
    }

    // Multiple panes, mixed states, preserved in order.
    func testParsesMultiplePanes() {
        let r = parseAlternateOnListing(["%0 1", "%4 0", "%6 1"])
        XCTAssertEqual(r.map { $0.pane }, [PaneID(raw: 0), PaneID(raw: 4), PaneID(raw: 6)])
        XCTAssertEqual(r.map { $0.isAlt }, [true, false, true])
    }

    // Malformed line (no flag) is skipped, valid lines still parsed.
    func testSkipsMalformedLine() {
        let r = parseAlternateOnListing(["%0 1", "garbage", "%4 0"])
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r.map { $0.pane }, [PaneID(raw: 0), PaneID(raw: 4)])
    }

    // Non-boolean flag value (e.g. 2) is skipped, not coerced.
    func testSkipsNonBooleanFlag() {
        XCTAssertEqual(parseAlternateOnListing(["%0 2"]).count, 0)
    }

    // Missing `%` prefix on the id is malformed → skipped.
    func testSkipsIdWithoutPercentPrefix() {
        XCTAssertEqual(parseAlternateOnListing(["0 1"]).count, 0)
    }

    // Empty reply → empty result (not a crash).
    func testEmptyReply() {
        XCTAssertEqual(parseAlternateOnListing([]).count, 0)
    }
}
