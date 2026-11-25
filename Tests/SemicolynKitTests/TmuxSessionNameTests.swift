// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class TmuxSessionNameTests: XCTestCase {
    // normalizedTmuxSessionName, trim + empty→nil
    func testNormalizeTrims() { XCTAssertEqual(normalizedTmuxSessionName("  x  "), "x") }
    func testNormalizeEmptyIsNil() { XCTAssertNil(normalizedTmuxSessionName("")) }
    func testNormalizeWhitespaceOnlyIsNil() { XCTAssertNil(normalizedTmuxSessionName("   ")) }
    func testNormalizeKeepsValidName() { XCTAssertEqual(normalizedTmuxSessionName("semicolyn"), "semicolyn") }

    // isValidTmuxSessionName, Critical tier (command-injection surface): EP + adversarial
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

    // Length cap (BVA around maxTmuxSessionNameLength = 29)
    func testAcceptsOneCharacter() { XCTAssertTrue(isValidTmuxSessionName("a")) }
    func testAcceptsTwentyEightCharacters() { XCTAssertTrue(isValidTmuxSessionName(String(repeating: "a", count: 28))) }
    func testAcceptsTwentyNineCharacters() { XCTAssertTrue(isValidTmuxSessionName(String(repeating: "a", count: 29))) }
    func testRejectsThirtyCharacters() { XCTAssertFalse(isValidTmuxSessionName(String(repeating: "a", count: 30))) }
    func testRejectsVeryLongName() { XCTAssertFalse(isValidTmuxSessionName(String(repeating: "a", count: 500))) }
    func testCapCountsTrimmedName() {
        // Surrounding spaces are trimmed before the cap: 29 characters padded is valid.
        XCTAssertTrue(isValidTmuxSessionName("  " + String(repeating: "a", count: 29) + "  "))
    }

    func testBuiltinDefaultIsSemicolyn() { XCTAssertEqual(builtInTmuxSessionName, "semicolyn") }
    func testBuiltinDefaultIsItselfValid() { XCTAssertTrue(isValidTmuxSessionName(builtInTmuxSessionName)) }
}
