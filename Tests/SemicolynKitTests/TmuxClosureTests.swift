// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class TmuxClosureTests: XCTestCase {
    func testCleanExitCarriesReason() {
        XCTAssertEqual(classifyTmuxClosure(lifecycle: .exited(reason: "server exited")),
                       .cleanExit(reason: "server exited"))
        XCTAssertEqual(classifyTmuxClosure(lifecycle: .exited(reason: nil)),
                       .cleanExit(reason: nil))
    }

    func testEOFWhileAttachedIsCrash() {
        // Channel closed with no %exit while attached → crash.
        XCTAssertEqual(classifyTmuxClosure(lifecycle: .attached), .crashed)
    }

    func testEOFWhileAttachingIsCrash() {
        XCTAssertEqual(classifyTmuxClosure(lifecycle: .attaching), .crashed)
    }

    func testIdleClosureDefaultsToCrash() {
        // Defensive: a channel can't close before start in practice.
        XCTAssertEqual(classifyTmuxClosure(lifecycle: .idle), .crashed)
    }
}
