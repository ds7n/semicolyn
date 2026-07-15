// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class AltScrollRegistryTests: XCTestCase {
    let reg = AltScrollRegistry.bundledDefault

    // The four known AI CLIs are registered.
    func testBundledDefaultContainsKnownApps() {
        XCTAssertTrue(reg.wantsPageKeys(command: "claude"))
        XCTAssertTrue(reg.wantsPageKeys(command: "gemini"))
        XCTAssertTrue(reg.wantsPageKeys(command: "codex"))
        XCTAssertTrue(reg.wantsPageKeys(command: "qwen"))
    }

    // Case-insensitive exact match.
    func testCommandMatchIsCaseInsensitive() {
        XCTAssertTrue(reg.wantsPageKeys(command: "Claude"))
        XCTAssertTrue(reg.wantsPageKeys(command: "CLAUDE"))
    }

    // An unregistered process does NOT match.
    func testUnregisteredCommandDoesNotMatch() {
        XCTAssertFalse(reg.wantsPageKeys(command: "bash"))
        XCTAssertFalse(reg.wantsPageKeys(command: "vim"))
    }

    // nil / empty / whitespace command never matches (no false positive).
    func testEmptyOrNilCommandDoesNotMatch() {
        XCTAssertFalse(reg.wantsPageKeys(command: nil))
        XCTAssertFalse(reg.wantsPageKeys(command: ""))
        XCTAssertFalse(reg.wantsPageKeys(command: "   "))
    }

    // EXACT token, not substring: a wrapper name must NOT match.
    func testCommandSubstringDoesNotFalseMatch() {
        XCTAssertFalse(reg.wantsPageKeys(command: "claude-wrapper"))
        XCTAssertFalse(reg.wantsPageKeys(command: "myclaude"))
    }

    // Title match: word-boundary token, case-insensitive.
    func testTitleWordBoundaryMatch() {
        XCTAssertTrue(reg.wantsPageKeys(title: "myrepo — claude: fix auth"))
        XCTAssertTrue(reg.wantsPageKeys(title: "CLAUDE"))
        XCTAssertFalse(reg.wantsPageKeys(title: "unclaudely commit"))  // no word boundary
        XCTAssertFalse(reg.wantsPageKeys(title: "vim README.md"))
        XCTAssertFalse(reg.wantsPageKeys(title: nil))
    }
}
