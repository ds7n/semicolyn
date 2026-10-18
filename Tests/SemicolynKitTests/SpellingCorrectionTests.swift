// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import SemicolynKit

final class SpellingCorrectionTests: XCTestCase {
    func dict() throws -> WordDictionary {
        try WordDictionary(entries: [.init(text: "the", score: 255), .init(text: "receive", score: 150),
            .init(text: "form", score: 100), .init(text: "from", score: 200), .init(text: "ten", score: 90), .init(text: "Linux", score: 180)],
            successors: [:])
    }
    func s(_ t: String, _ n: Int = 5) throws -> [String] { spellingCorrections(for: t, in: try dict(), limit: n).map(\.text) }
    func testCommonTypos() throws {
        XCTAssertEqual(try s("teh"), ["the", "ten"])      // transpose; replace h->n
        XCTAssertEqual(try s("recieve"), ["receive"])
        XCTAssertEqual(try s("fomr"), ["form"])           // "from" is distance 2
        XCTAssertEqual(try s("Teh"), ["The", "Ten"])
        XCTAssertEqual(try s("linx"), ["Linux"])          // insert, stored case kept
    }
    func testGuards() throws {
        XCTAssertEqual(try s("the"), [])     // already a word
        XCTAssertEqual(try s("th"), [])      // below length 3
        XCTAssertEqual(try s("tqe"), ["the"]) // length 3 boundary
        XCTAssertEqual(try s("x1y"), [])     // not letters
        XCTAssertEqual(try s("teh", 1), ["the"])
        XCTAssertEqual(try s("teh", 0), [])
    }
    func testExactFormBeatsLongerPrefixMatches() throws {
        // "then" (255) would outrank "the" in a plain prefix query for "the".
        let d = try WordDictionary(entries: [.init(text: "the", score: 10), .init(text: "then", score: 255),
            .init(text: "they", score: 250)], successors: [:])
        XCTAssertEqual(spellingCorrections(for: "teh", in: d, limit: 5).map(\.text), ["the"])
    }
    func testScoresCarriedThrough() throws {
        let r = spellingCorrections(for: "teh", in: try dict(), limit: 5)
        XCTAssertEqual(r, [ScoredWord(text: "the", score: 255), ScoredWord(text: "ten", score: 90)])
    }
    func testStoredCaseSurvivesManyPrefixExtensions() throws {
        var entries = [ScoredWord(text: "Linux", score: 180)]
        for i in 0..<100 { entries.append(ScoredWord(text: "linuxa\(i)", score: 250)) }
        let d = try WordDictionary(entries: entries, successors: [:])
        XCTAssertEqual(spellingCorrections(for: "linx", in: d, limit: 5), [ScoredWord(text: "Linux", score: 180)])
    }
}
