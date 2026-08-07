// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class TransportMenuTests: XCTestCase {
    func testTmuxToggleShownForSSH() {
        XCTAssertTrue(showsTmuxControlToggle(transport: .ssh))
    }
    func testTmuxToggleShownForET() {
        // tmux -CC is transport-agnostic in principle; ET can run it (wiring pending).
        XCTAssertTrue(showsTmuxControlToggle(transport: .et))
    }
    func testTmuxToggleHiddenForMosh() {
        // Mosh structurally cannot run tmux -CC.
        XCTAssertFalse(showsTmuxControlToggle(transport: .mosh))
    }
}
