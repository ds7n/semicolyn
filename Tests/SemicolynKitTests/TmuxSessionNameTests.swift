// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class TmuxSessionNameTests: XCTestCase {
    // normalizedTmuxSessionName — trim + empty→nil
    func testNormalizeTrims() { XCTAssertEqual(normalizedTmuxSessionName("  x  "), "x") }
    func testNormalizeEmptyIsNil() { XCTAssertNil(normalizedTmuxSessionName("")) }
    func testNormalizeWhitespaceOnlyIsNil() { XCTAssertNil(normalizedTmuxSessionName("   ")) }
    func testNormalizeKeepsValidName() { XCTAssertEqual(normalizedTmuxSessionName("semicolyn"), "semicolyn") }

    // isValidTmuxSessionName — Critical tier (command-injection surface): EP + adversarial
    func testValidNames() {
        for n in ["semicolyn", "work", "my-session", "dev_2", "A1"] {
            XCTAssertTrue(isValidTmuxSessionName(n), "\(n) should be valid")
        }
    }
    func testRejectsDot() { XCTAssertFalse(isValidTmuxSessionName("a.b")) }        // tmux-forbidden
    func testRejectsColon() { XCTAssertFalse(isValidTmuxSessionName("a:b")) }      // tmux-forbidden
    func testRejectsSpace() { XCTAssertFalse(isValidTmuxSessionName("a b")) }
    func testRejectsShellMetachar() { XCTAssertFalse(isValidTmuxSessionName("a;rm -rf")) } // injection
    func testRejectsEmpty() { XCTAssertFalse(isValidTmuxSessionName("")) }
    func testRejectsWhitespaceOnly() { XCTAssertFalse(isValidTmuxSessionName("   ")) }
    func testRejectsControlChar() { XCTAssertFalse(isValidTmuxSessionName("a\u{0007}b")) }
    func testRejectsSlash() { XCTAssertFalse(isValidTmuxSessionName("a/b")) }
    func testRejectsLeadingTrailingSpaceButValidCore() {
        // "  work  " trims to a valid "work" → valid (editor trims on save).
        XCTAssertTrue(isValidTmuxSessionName("  work  "))
    }

    func testBuiltinDefaultIsSemicolyn() { XCTAssertEqual(builtInTmuxSessionName, "semicolyn") }
    func testBuiltinDefaultIsItselfValid() { XCTAssertTrue(isValidTmuxSessionName(builtInTmuxSessionName)) }
}
