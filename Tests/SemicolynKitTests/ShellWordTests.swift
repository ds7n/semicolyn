// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// `shellWord` (security audit L3): a user-typed mosh-server path reaches the remote
/// login shell as exactly one literal word.
final class ShellWordTests: XCTestCase {
    // EP: a plain path stays unquoted so logs read naturally.
    func testSafePathUnchanged() {
        XCTAssertEqual(shellWord("/usr/local/bin/mosh-server"), "/usr/local/bin/mosh-server")
    }

    // A space would split the word: quoted.
    func testSpaceIsQuoted() {
        XCTAssertEqual(shellWord("/opt/my tools/mosh-server"), "'/opt/my tools/mosh-server'")
    }

    // Adversarial: command injection through ; $() and backticks stays literal.
    func testInjectionIsQuoted() {
        XCTAssertEqual(shellWord("/x;rm -rf ~"), "'/x;rm -rf ~'")
        XCTAssertEqual(shellWord("$(id)"), "'$(id)'")
        XCTAssertEqual(shellWord("`id`"), "'`id`'")
    }

    // Adversarial: an embedded single quote cannot close the quoting early.
    func testSingleQuoteEscaped() {
        XCTAssertEqual(shellWord("/a'b"), "'/a'\\''b'")
        XCTAssertEqual(shellWord("'; id; '"), "''\\''; id; '\\'''")
    }

    // A leading ~/ keeps working as the home directory.
    func testTildePrefixStaysExpandable() {
        XCTAssertEqual(shellWord("~/bin/mosh-server"), "~/bin/mosh-server")
        XCTAssertEqual(shellWord("~/my bin/mosh-server"), "~/'my bin/mosh-server'")
        XCTAssertEqual(shellWord("~/"), "~/")
    }

    // BVA: a bare ~ or ~user is not the ~/ form and is quoted literally.
    func testOtherTildeFormsQuoted() {
        XCTAssertEqual(shellWord("~"), "'~'")
        XCTAssertEqual(shellWord("~root/x"), "'~root/x'")
    }

    // BVA: empty stays a word instead of disappearing.
    func testEmptyIsQuotedEmpty() {
        XCTAssertEqual(shellWord(""), "''")
    }

    // Newlines and globs are quoted.
    func testNewlineAndGlobQuoted() {
        XCTAssertEqual(shellWord("a\nb"), "'a\nb'")
        XCTAssertEqual(shellWord("/bin/*"), "'/bin/*'")
    }
}
