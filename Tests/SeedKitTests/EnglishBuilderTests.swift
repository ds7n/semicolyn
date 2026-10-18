// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import SemicolynKit
@testable import SeedKit

final class EnglishBuilderTests: XCTestCase {
    func testCaseForms() {
        XCTAssertEqual(selectCaseForms(["the": 900, "The": 100]), ["the": 1000])
        XCTAssertEqual(selectCaseForms(["linux": 5, "Linux": 95]), ["Linux": 100])
        XCTAssertEqual(selectCaseForms(["us": 700, "US": 300]), ["us": 700, "US": 300])
        XCTAssertEqual(selectCaseForms(["api": 10, "API": 90]), ["API": 100])
        XCTAssertEqual(selectCaseForms(["Apple": 60, "apple": 40]), ["Apple": 60, "apple": 40])
        XCTAssertEqual(selectCaseForms(["Apple": 49, "apple": 51]), ["apple": 100])   // 49% capitalized is below 50%
        XCTAssertEqual(selectCaseForms(["a": 1]), ["a": 1])
    }

    func testCaseFormBoundaries() {
        // Exactly 25% of the total for a multi-capital variant is kept; just below is dropped.
        XCTAssertEqual(selectCaseForms(["us": 75, "US": 25]), ["us": 75, "US": 25])
        XCTAssertEqual(selectCaseForms(["us": 76, "US": 24]), ["us": 100])
        // Exactly 50% for a first-letter-only capital is kept.
        XCTAssertEqual(selectCaseForms(["Apple": 50, "apple": 50]), ["Apple": 50, "apple": 50])
        // Nothing qualifies: the largest variant takes the whole total.
        XCTAssertEqual(selectCaseForms(["abc": 20, "abC": 20, "aBc": 20, "ABC": 22, "aBC": 18]), ["ABC": 100])
        XCTAssertEqual(selectCaseForms(["Abc": 40]), ["Abc": 40])
        XCTAssertEqual(selectCaseForms([:]), [:])
    }

    func testScoresAreLogScaled() {
        let s = EnglishSources(books: [:], wordfreq: ["aa": 2e-2, "bb": 2e-4, "cc": 2e-6], realWords: ["aa", "bb", "cc"], titleWords: [], blocklist: [])
        XCTAssertEqual(buildEnglishEntries(s, config: .init()), [.init(text: "aa", score: 255), .init(text: "bb", score: 128), .init(text: "cc", score: 1)])
    }

    func testSingleWordScoresMax() {
        let s = EnglishSources(books: [:], wordfreq: ["aa": 2e-2], realWords: ["aa"], titleWords: [], blocklist: [])
        XCTAssertEqual(buildEnglishEntries(s, config: .init()), [.init(text: "aa", score: 255)])
    }

    func testAdmissionAndBlocklist() {
        let s = EnglishSources(books: ["Zorbly": 10, "qqq": 10], wordfreq: ["damn": 1e-4, "rare": 1e-7], realWords: ["damn"],
                               titleWords: ["Zorbly"], blocklist: ["damn"])
        // "Zorbly": title with a books count, admitted; "qqq": not real, no wordfreq, not a title; "rare": zipf 2 < 3; "damn": blocklisted.
        XCTAssertEqual(buildEnglishEntries(s, config: .init()).map(\.text), ["Zorbly"])
    }

    func testZipfBoundaryAdmission() {
        // zipf = log10(f) + 9: 1e-6 is exactly 3.0 (admitted), 9e-7 is below.
        let s = EnglishSources(books: [:], wordfreq: ["edge": 1e-6, "under": 9e-7], realWords: [], titleWords: [], blocklist: [])
        XCTAssertEqual(buildEnglishEntries(s, config: .init()).map(\.text), ["edge"])
    }

    func testBlocklistIsCaseFoldedAgainstBooksForms() {
        let s = EnglishSources(books: ["Damn": 100], wordfreq: [:], realWords: ["damn"], titleWords: [], blocklist: ["damn"])
        XCTAssertEqual(buildEnglishEntries(s, config: .init()), [])
    }

    func testOverlongWordDropped() {
        let long = String(repeating: "a", count: 256)
        let ok = String(repeating: "b", count: 255)
        let s = EnglishSources(books: [:], wordfreq: [long: 1e-3, ok: 1e-3], realWords: [long, ok], titleWords: [], blocklist: [])
        XCTAssertEqual(buildEnglishEntries(s, config: .init()).map(\.text), [ok])
    }

    func testBooksAndWordfreqCombineGeometrically() {
        // books: aa 3/4, bb 1/4 of total; wordfreq: aa 0.01, bb 0.0001.
        // f(aa) = sqrt(0.75 * 0.01), f(bb) = sqrt(0.25 * 0.0001); only books-backed words so scores span 255..1.
        let s = EnglishSources(books: ["aa": 75, "bb": 25], wordfreq: ["aa": 1e-2, "bb": 1e-4], realWords: ["aa", "bb"], titleWords: [], blocklist: [])
        XCTAssertEqual(buildEnglishEntries(s, config: .init()), [.init(text: "aa", score: 255), .init(text: "bb", score: 1)])
    }

    func testCaseShareSplitsWordfreq() {
        // Apple 60 / apple 40 of the "apple" group; wordfreq 1e-3 splits 60/40; books total 100.
        // f(Apple) = sqrt(.6 * 6e-4), f(apple) = sqrt(.4 * 4e-4). The ratio fixes the 255/1 scores.
        let s = EnglishSources(books: ["Apple": 60, "apple": 40], wordfreq: ["apple": 1e-3], realWords: ["apple"], titleWords: [], blocklist: [])
        XCTAssertEqual(buildEnglishEntries(s, config: .init()), [.init(text: "Apple", score: 255), .init(text: "apple", score: 1)])
    }

    func testSingleSourceWordsUseHalfFrequency() {
        // cc books-only: f = 0.5 * 0.5 = 0.25; dd wordfreq-only: f = 0.5 * 0.125 = 0.0625;
        // ee both: sqrt(0.5 * 0.5) = 0.5. cc sits at ln4 / ln8 = 2/3 of the log range: 1 + round(254 * 2/3) = 170.
        let s = EnglishSources(books: ["cc": 50, "ee": 50], wordfreq: ["dd": 0.125, "ee": 0.5], realWords: ["cc", "dd", "ee"], titleWords: [], blocklist: [])
        XCTAssertEqual(buildEnglishEntries(s, config: .init()),
                       [.init(text: "ee", score: 255), .init(text: "cc", score: 170), .init(text: "dd", score: 1)])
    }

    func testMaxWordsBoundary() {
        var c = EnglishBuildConfig(); c.maxWords = 2
        let s = EnglishSources(books: [:], wordfreq: ["aa": 3e-2, "bb": 2e-2, "cc": 1e-2], realWords: ["aa", "bb", "cc"], titleWords: [], blocklist: [])
        XCTAssertEqual(buildEnglishEntries(s, config: c).map(\.text), ["aa", "bb"])
    }

    func testSuccessors() {
        var c = EnglishBuildConfig(); c.successorsPerWord = 2
        let entries: [ScoredWord] = [.init(text: "the", score: 255), .init(text: "cat", score: 9), .init(text: "dog", score: 8), .init(text: "Linux", score: 7)]
        let pairs: [(prev: String, next: String, count: UInt64)] = [("the", "cat", 100), ("The", "cat", 100), ("the", "dog", 50), ("the", "linux", 10), ("the", "zebra", 999)]
        XCTAssertEqual(buildSuccessors(pairs: pairs, entries: entries, config: c),
                       ["the": [.init(text: "cat", score: 255), .init(text: "dog", score: 65)]])
    }

    func testSuccessorWordsLimitsKeys() {
        var c = EnglishBuildConfig(); c.successorWords = 1
        let entries: [ScoredWord] = [.init(text: "the", score: 255), .init(text: "cat", score: 9)]
        let pairs: [(prev: String, next: String, count: UInt64)] = [("the", "cat", 5), ("cat", "the", 5)]
        XCTAssertEqual(buildSuccessors(pairs: pairs, entries: entries, config: c), ["the": [.init(text: "cat", score: 255)]])
    }

    func testSuccessorsAcceptedWhenMaxWordsDropsWords() throws {
        var c = EnglishBuildConfig(); c.maxWords = 2
        let s = EnglishSources(books: [:], wordfreq: ["the": 5e-2, "cat": 1e-2, "dog": 1e-3, "emu": 1e-4],
                               realWords: ["the", "cat", "dog", "emu"], titleWords: [], blocklist: [])
        let entries = buildEnglishEntries(s, config: c)
        XCTAssertEqual(entries.map(\.text), ["the", "cat"])
        let pairs: [(prev: String, next: String, count: UInt64)] = [
            ("the", "cat", 5), ("the", "dog", 9), ("dog", "the", 4), ("cat", "emu", 3), ("cat", "the", 2),
        ]
        let successors = buildSuccessors(pairs: pairs, entries: entries, config: c)
        XCTAssertEqual(successors, ["the": [.init(text: "cat", score: 255)], "cat": [.init(text: "the", score: 255)]])
        XCTAssertEqual(try WordDictionary(entries: entries, successors: successors).wordCount, 2)
    }

    func testSuccessorKeysAlwaysAcceptedByWordDictionary() throws {
        let s = EnglishSources(
            books: ["The": 40, "the": 60, "Linux": 95, "linux": 5, "us": 70, "US": 30, "cat": 10],
            wordfreq: ["the": 5e-2, "linux": 1e-5, "us": 1e-3, "cat": 1e-4],
            realWords: ["the", "us", "cat"], titleWords: ["Linux"], blocklist: [])
        let entries = buildEnglishEntries(s, config: .init())
        XCTAssertEqual(Set(entries.map(\.text)), ["the", "Linux", "us", "US", "cat"])
        let pairs: [(prev: String, next: String, count: UInt64)] = [
            ("The", "Linux", 9), ("the", "linux", 3), ("US", "cat", 4), ("Linux", "the", 2), ("cat", "US", 7), ("cat", "nope", 1),
        ]
        let successors = buildSuccessors(pairs: pairs, entries: entries, config: .init())
        XCTAssertEqual(Set(successors.keys), ["the", "linux", "us", "cat"])
        let dict = try WordDictionary(entries: entries, successors: successors)
        XCTAssertEqual(dict.wordCount, 5)
    }
}
