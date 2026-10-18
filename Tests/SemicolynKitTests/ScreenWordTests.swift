// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ScreenWordTests: XCTestCase {
    func testShape() {
        XCTAssertTrue(isScreenWordShaped("main.swift")); XCTAssertTrue(isScreenWordShaped("feat/x"))
        XCTAssertFalse(isScreenWordShaped("ab"))                       // below 3
        XCTAssertTrue(isScreenWordShaped("abc"))                       // boundary
        XCTAssertTrue(isScreenWordShaped(String(repeating: "a", count: 64)))
        XCTAssertFalse(isScreenWordShaped(String(repeating: "a", count: 65)))
        XCTAssertFalse(isScreenWordShaped("123")); XCTAssertFalse(isScreenWordShaped("❯"))
        XCTAssertFalse(isScreenWordShaped("a=b-c"))                    // '=' outside the set
        XCTAssertFalse(isScreenWordShaped("caf\u{e9}"))                // non-ASCII letter
        XCTAssertTrue(isScreenWordShaped("~/1.2-x"))                   // symbols allowed, one letter
        XCTAssertFalse(isScreenWordShaped("1.2.3"))                    // no letter
    }

    func testHarvestFiltersSecretsAndPromptGlyphs() throws {
        var e = try RankFixture.engine()
        e.harvest(output: "\u{1b}[32m❯\u{1b}[0m README.md --password hunter2 ghp_abcdefghijklmnop1234")
        XCTAssertEqual(e.suggestions(line: "REA", lineOptedOut: false).first?.text, "README.md")
        XCTAssertFalse(e.suggestions(line: "hun", lineOptedOut: false).map(\.text).contains("hunter2"))
        XCTAssertFalse(e.suggestions(line: "ghp", lineOptedOut: false).map(\.text).contains { $0.hasPrefix("ghp_") })
    }

    func testHarvestDropsShortTokensButKeepsBoundary() throws {
        var e = try RankFixture.engine()
        e.harvest(output: "zq zqx")
        let got = e.suggestions(line: "zq", lineOptedOut: false).map(\.text)
        XCTAssertTrue(got.contains("zqx"))
        XCTAssertFalse(got.contains("zq"))
    }

    func testSecretValueAfterDroppedFlagStillDropped() throws {
        // The flag itself is not screen-shaped-excluded; the value after it must go
        // even when the flag precedes it across a dropped token boundary.
        var e = try RankFixture.engine()
        e.harvest(output: "--token abcsecretvalue visible.txt")
        XCTAssertFalse(e.suggestions(line: "abc", lineOptedOut: false).map(\.text).contains("abcsecretvalue"))
        XCTAssertTrue(e.suggestions(line: "vis", lineOptedOut: false).map(\.text).contains("visible.txt"))
    }
}
