// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ControlModeBlockTests: XCTestCase {
    private func feed(_ s: String) -> [ControlModeEvent] {
        ControlModeParser().feed(Array(s.utf8))
    }

    func testOkBlockCoalescesBodyLines() {
        let s = "%begin 1700000000 7 0\nline one\nline two\n%end 1700000000 7 0\n"
        XCTAssertEqual(feed(s), [.commandResult(number: 7, outcome: .ok(["line one", "line two"]))])
    }
    func testEmptyOkBlock() {
        let s = "%begin 1 4 0\n%end 1 4 0\n"
        XCTAssertEqual(feed(s), [.commandResult(number: 4, outcome: .ok([]))])
    }
    func testErrorBlock() {
        let s = "%begin 1 9 0\nno server running\n%error 1 9 0\n"
        XCTAssertEqual(feed(s), [.commandResult(number: 9, outcome: .error(["no server running"]))])
    }
    func testNotificationsSuppressedInsideBlock() {
        // A body line that itself looks like a notification stays a body line.
        let s = "%begin 1 2 0\n%window-add @4\n%end 1 2 0\n"
        XCTAssertEqual(feed(s), [.commandResult(number: 2, outcome: .ok(["%window-add @4"]))])
    }
    func testNumberMismatchIsMalformedAndResets() {
        let s = "%begin 1 2 0\nbody\n%end 1 3 0\n%sessions-changed\n"
        let events = feed(s)
        guard case .malformed = events.first else {
            return XCTFail("expected .malformed on number mismatch, got \(events)")
        }
        // After reset, the following notification parses normally.
        XCTAssertEqual(events.last, .sessionsChanged)
    }
    func testTerminatorWithNoOpenBlockIsMalformed() {
        if case .malformed = feed("%end 1 1 0\n").first {} else {
            XCTFail("expected .malformed for %end with no open block")
        }
    }
}
