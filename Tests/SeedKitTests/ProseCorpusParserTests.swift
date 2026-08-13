// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SeedKit

final class ProseCorpusParserTests: XCTestCase {
    func testSplitsSentencesAndLowercases() {
        let out = ProseCorpusParser.sentences(fromText: "Fix the bug. Add a test!")
        XCTAssertEqual(out, [["fix", "the", "bug"], ["add", "a", "test"]])
    }

    func testStripsSurroundingPunctuationAndSymbols() {
        // "(really)" -> "really"; "v2.0" keeps letters? -> pure-number/symbol tokens dropped.
        let out = ProseCorpusParser.sentences(fromText: "Update (really) now 42 ---")
        XCTAssertEqual(out, [["update", "really", "now"]])
    }

    func testNewlineIsASentenceBoundary() {
        let out = ProseCorpusParser.sentences(fromText: "one two\nthree four")
        XCTAssertEqual(out, [["one", "two"], ["three", "four"]])
    }

    func testEmptyInputYieldsNoSentences() {
        XCTAssertEqual(ProseCorpusParser.sentences(fromText: "   \n  "), [])
    }
}
