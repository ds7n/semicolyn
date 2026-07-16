// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class DecisionLineTests: XCTestCase {
    func testInputsOutputsAndReason() {
        let line = decisionLine("grid",
                                inputs: [("bounds", "402"), ("cell", "4.8")],
                                outputs: [("cols", "83")],
                                reason: "fractional-cell")
        XCTAssertEqual(line, "grid bounds=402 cell=4.8 → cols=83 reason=fractional-cell")
    }

    func testNoReasonOmitsReasonField() {
        let line = decisionLine("grid",
                                inputs: [("bounds", "402")],
                                outputs: [("cols", "83")])
        XCTAssertEqual(line, "grid bounds=402 → cols=83")
    }

    func testEmptyInputsHasNoLeadingSpace() {
        let line = decisionLine("poll", inputs: [], outputs: [("panes", "9")])
        XCTAssertEqual(line, "poll → panes=9")
    }

    func testMultipleOutputs() {
        let line = decisionLine("size", inputs: [("w", "402")], outputs: [("cols", "80"), ("rows", "40")])
        XCTAssertEqual(line, "size w=402 → cols=80 rows=40")
    }
}
