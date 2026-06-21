// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import GlymrKit

/// PrefixIndex — Core tier. Sorted-unique invariant + prefix lookup.
final class PrefixIndexTests: XCTestCase {
    private func index(_ tokens: [String]) -> PrefixIndex {
        var i = PrefixIndex()
        for t in tokens { i.insert(t) }
        return i
    }

    func testMatchingReturnsSortedMatches() {
        let i = index(["grep", "git", "go"])
        XCTAssertEqual(i.matching(prefix: "g"), ["git", "go", "grep"])
    }

    func testInsertDeduplicates() {
        let i = index(["git", "git", "git"])
        XCTAssertEqual(i.count, 1)
        XCTAssertEqual(i.matching(prefix: "git"), ["git"])
    }

    func testNarrowerPrefixNarrowsMatches() {
        let i = index(["git", "go", "grep", "gcc"])
        XCTAssertEqual(i.matching(prefix: "gi"), ["git"])
        XCTAssertEqual(i.matching(prefix: "g"), ["gcc", "git", "go", "grep"])
    }

    func testNoMatchReturnsEmpty() {
        let i = index(["git", "go"])
        XCTAssertEqual(i.matching(prefix: "z"), [])
    }

    func testFullTokenAsPrefixIncludesIt() {
        let i = index(["git", "github", "go"])
        XCTAssertEqual(i.matching(prefix: "git"), ["git", "github"])
    }

    func testEmptyPrefixMatchesAll() {
        let i = index(["b", "a", "c"])
        XCTAssertEqual(i.matching(prefix: ""), ["a", "b", "c"])
    }

    func testPrefixLongerThanAnyToken() {
        let i = index(["git"])
        XCTAssertEqual(i.matching(prefix: "gittttt"), [])
    }

    func testCaseSensitive() {
        let i = index(["Git", "git"])
        XCTAssertEqual(i.matching(prefix: "git"), ["git"], "lowercase prefix must not match capitalized token")
        XCTAssertEqual(i.matching(prefix: "Git"), ["Git"])
    }

    func testNonAsciiTokenPrefixMatch() {
        // Precomposed "café" sorts and prefix-matches by UTF-8 bytes.
        let i = index(["café", "cat", "cab"])
        XCTAssertEqual(i.matching(prefix: "ca"), ["cab", "caf\u{e9}", "cat"])
        XCTAssertEqual(i.matching(prefix: "caf"), ["caf\u{e9}"])
    }

    func testBytePrefixMatchesCombiningMarkTokenContiguously() {
        // "e\u{301}" is e + COMBINING ACUTE — ONE grapheme, so grapheme hasPrefix
        // would NOT match "e". Byte-prefix DOES (first byte is 0x65) and keeps the
        // matching run contiguous. This is the guarantee the byte ordering buys.
        let combining = "e\u{301}"
        let i = index(["a", combining, "ef", "z"])
        XCTAssertEqual(i.matching(prefix: "e"), ["ef", combining])
    }
}
