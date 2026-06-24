// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class ControlModeOutputTests: XCTestCase {
    private func feed(_ s: String) -> [ControlModeEvent] {
        ControlModeParser().feed(Array(s.utf8))
    }

    func testOutputDecodesEscapedData() {
        // %output %1 hi\033[0m
        XCTAssertEqual(feed("%output %1 hi\\033[0m\n"),
                       [.output(pane: PaneID(raw: 1), data: Array("hi".utf8) + [0x1B, 0x5B, 0x30, 0x6D])])
    }
    func testOutputWithSpacesInData() {
        XCTAssertEqual(feed("%output %2 a b c\n"),
                       [.output(pane: PaneID(raw: 2), data: Array("a b c".utf8))])
    }
    func testOutputWithEmptyData() {
        XCTAssertEqual(feed("%output %2 \n"),
                       [.output(pane: PaneID(raw: 2), data: [])])
    }
    func testOutputBadEscapeIsMalformed() {
        if case .malformed = feed("%output %1 bad\\\n").first {} else {
            XCTFail("expected .malformed for a dangling backslash escape")
        }
    }
    func testOutputBadPaneIsMalformed() {
        if case .malformed = feed("%output @1 data\n").first {} else {
            XCTFail("expected .malformed for a non-pane id")
        }
    }
}
