// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class TitleSanitizeTests: XCTestCase {
    func testNormalTitlePassesTrimmed() {
        XCTAssertEqual(sanitizeTerminalTitle("  ~/code — vim  "), "~/code — vim")
    }
    func testEmptyOrWhitespaceRejected() {
        XCTAssertNil(sanitizeTerminalTitle(""))
        XCTAssertNil(sanitizeTerminalTitle("   "))
    }
    func testControlCharsRejected() {
        XCTAssertNil(sanitizeTerminalTitle("ev\u{07}il"))      // BEL
        XCTAssertNil(sanitizeTerminalTitle("line\u{0A}break")) // LF
        XCTAssertNil(sanitizeTerminalTitle("\u{7f}"))          // DEL
    }
}
