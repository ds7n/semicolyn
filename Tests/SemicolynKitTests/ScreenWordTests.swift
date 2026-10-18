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
        e.harvest(output: "zq zqx\n")
        let got = e.suggestions(line: "zq", lineOptedOut: false).map(\.text)
        XCTAssertTrue(got.contains("zqx"))
        XCTAssertFalse(got.contains("zq"))
    }

    func testSecretValueAfterDroppedFlagStillDropped() throws {
        // The flag itself is not screen-shaped-excluded; the value after it must go
        // even when the flag precedes it across a dropped token boundary.
        var e = try RankFixture.engine()
        e.harvest(output: "--token abcsecretvalue visible.txt\n")
        XCTAssertFalse(e.suggestions(line: "abc", lineOptedOut: false).map(\.text).contains("abcsecretvalue"))
        XCTAssertTrue(e.suggestions(line: "vis", lineOptedOut: false).map(\.text).contains("visible.txt"))
    }

    func testSecretFlagContextCarriesAcrossChunks() throws {
        var e = try RankFixture.engine()
        e.harvest(output: "--password ")
        e.harvest(output: "hunter2 README.md\n")
        let got = e.suggestions(line: "hun", lineOptedOut: false).map(\.text)
        XCTAssertFalse(got.contains("hunter2"))
        XCTAssertEqual(e.suggestions(line: "REA", lineOptedOut: false).first?.text, "README.md")
    }

    func testEscapeSplitAcrossChunksDoesNotLeak() throws {
        var e = try RankFixture.engine()
        e.harvest(output: "\u{1b}[3")
        e.harvest(output: "1mREADME.md ok\n")
        XCTAssertEqual(e.suggestions(line: "REA", lineOptedOut: false).first?.text, "README.md")
        XCTAssertFalse(e.suggestions(line: "1m", lineOptedOut: false).map(\.text).contains { $0.hasPrefix("1m") })
    }

    func testPartialTrailingTokenJoinsNextChunk() throws {
        var e = try RankFixture.engine()
        e.harvest(output: "READ")
        e.harvest(output: "ME.md x\n")
        XCTAssertEqual(e.suggestions(line: "REA", lineOptedOut: false).first?.text, "README.md")
        XCTAssertFalse(e.suggestions(line: "ME.", lineOptedOut: false).map(\.text).contains("ME.md"))
        XCTAssertFalse(e.suggestions(line: "READ", lineOptedOut: false).map(\.text).contains("READ"))
    }

    func testClearHarvestResetsCarriedContext() throws {
        var e = try RankFixture.engine()
        e.harvest(output: "--password READ")
        e.clearHarvest()
        e.harvest(output: "ME.md hunter2\n")
        XCTAssertFalse(e.suggestions(line: "READ", lineOptedOut: false).map(\.text).contains("README.md"))
        XCTAssertTrue(e.suggestions(line: "hun", lineOptedOut: false).map(\.text).contains("hunter2"))
    }

    func testShapeValidSecretLookingTokensNotHarvested() throws {
        var e = try RankFixture.engine()
        // FINDING (Task 17): a 40-char lowercase hex digest IS harvested today, since
        // hex tops out at exactly 4.0 bits/char and the entropy backstop needs > 4.0.
        // Deliberately not asserted here; TokenFilter is out of scope for Task 14.
        let akia = "AKIAIOSFODNN7EXAMPLE"                        // 20 chars
        XCTAssertTrue(isScreenWordShaped(akia))
        e.harvest(output: "\(akia) visible.txt\n")
        XCTAssertFalse(e.suggestions(line: "AKIA", lineOptedOut: false).map(\.text).contains(akia))
        XCTAssertTrue(e.suggestions(line: "vis", lineOptedOut: false).map(\.text).contains("visible.txt"))
    }
}
