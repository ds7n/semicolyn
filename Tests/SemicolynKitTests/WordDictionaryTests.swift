// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

import XCTest

@testable import SemicolynKit

final class WordDictionaryTests: XCTestCase {
    func fixture() throws -> WordDictionary {
        try WordDictionary(
            entries: [
                .init(text: "the", score: 255), .init(text: "they", score: 200), .init(text: "then", score: 150),
                .init(text: "Thursday", score: 120), .init(text: "Linux", score: 180), .init(text: "API", score: 160),
                .init(text: "apple", score: 100), .init(text: "Apple", score: 90),
                .init(text: "cat", score: 50), .init(text: "dog", score: 40), .init(text: "think", score: 60),
                .init(text: "I", score: 230),
            ],
            successors: [
                "the": [.init(text: "cat", score: 200), .init(text: "dog", score: 100)],
                "i": [.init(text: "think", score: 250)],
            ])
    }

    func testCompletionsCaseRules() throws {
        let d = try fixture()
        XCTAssertEqual(d.completions(typed: "th", limit: 10).map(\.text), ["the", "they", "then", "Thursday", "think"])
        XCTAssertEqual(d.completions(typed: "Th", limit: 10).map(\.text), ["The", "They", "Then", "Thursday", "Think"])
        XCTAssertEqual(d.completions(typed: "lin", limit: 10), [.init(text: "Linux", score: 180)])
        XCTAssertEqual(d.completions(typed: "LIN", limit: 10), [])
        XCTAssertEqual(d.completions(typed: "ap", limit: 10).map(\.text), ["API", "apple", "Apple"])
        // "API" matches too (lowercase "p" matches "P"); "apple" and "Apple" both display "Apple", higher score kept.
        XCTAssertEqual(
            d.completions(typed: "Ap", limit: 10), [.init(text: "API", score: 160), .init(text: "Apple", score: 100)])
    }

    func testLimitBoundaries() throws {
        let d = try fixture()
        XCTAssertEqual(d.completions(typed: "th", limit: 2).map(\.text), ["the", "they"])
        XCTAssertEqual(d.completions(typed: "th", limit: 0), [])
        XCTAssertEqual(d.completions(typed: "zz", limit: 5), [])
    }

    func testSuccessors() throws {
        let d = try fixture()
        XCTAssertEqual(d.successors(of: "The", limit: 5).map(\.text), ["cat", "dog"])
        XCTAssertEqual(d.successors(of: "I", limit: 1), [.init(text: "think", score: 250)])
        XCTAssertEqual(d.successors(of: "dog", limit: 5), [])
    }

    func testFoldedLookups() throws {
        let d = try fixture()
        XCTAssertTrue(d.containsFolded("THE"))
        XCTAssertFalse(d.containsFolded("thee"))
        XCTAssertEqual(d.score(ofFolded: "apple"), 100)
        XCTAssertNil(d.score(ofFolded: "pear"))
        XCTAssertEqual(d.wordCount, 12)
    }

    func testInitErrors() {
        XCTAssertThrowsError(
            try WordDictionary(entries: [.init(text: "a", score: 1), .init(text: "a", score: 2)], successors: [:])
        ) {
            XCTAssertEqual($0 as? WordDictionaryError, .duplicateWord("a"))
        }
        XCTAssertThrowsError(try WordDictionary(entries: [.init(text: "a", score: 0)], successors: [:])) {
            XCTAssertEqual($0 as? WordDictionaryError, .zeroScore("a"))
        }
        XCTAssertThrowsError(
            try WordDictionary(entries: [.init(text: String(repeating: "x", count: 256), score: 1)], successors: [:])
        ) {
            XCTAssertEqual($0 as? WordDictionaryError, .wordTooLong(String(repeating: "x", count: 256)))
        }
        XCTAssertThrowsError(try WordDictionary(entries: [.init(text: "", score: 1)], successors: [:])) {
            XCTAssertEqual($0 as? WordDictionaryError, .emptyWord)
        }
        XCTAssertThrowsError(
            try WordDictionary(entries: [.init(text: "a", score: 1)], successors: ["a": [.init(text: "b", score: 1)]])
        ) {
            XCTAssertEqual($0 as? WordDictionaryError, .unknownSuccessorWord("b"))
        }
    }

    func testMaxLengthWordAccepted() throws {
        let w = String(repeating: "x", count: 255)
        let d = try WordDictionary(entries: [.init(text: w, score: 1)], successors: [:])
        XCTAssertEqual(d.wordCount, 1)
        XCTAssertEqual(WordDictionary(deserializing: d.serialize())?.score(ofFolded: w), 1)
    }

    func testRoundTripAndFailClosed() throws {
        let d = try fixture()
        let blob = d.serialize()
        let back = try XCTUnwrap(WordDictionary(deserializing: blob))
        XCTAssertEqual(back.completions(typed: "th", limit: 10), d.completions(typed: "th", limit: 10))
        XCTAssertEqual(back.completions(typed: "Ap", limit: 10), d.completions(typed: "Ap", limit: 10))
        XCTAssertEqual(back.successors(of: "the", limit: 5), d.successors(of: "the", limit: 5))
        XCTAssertEqual(back.wordCount, 12)
        XCTAssertEqual(back.serialize(), blob)
        XCTAssertNil(WordDictionary(deserializing: [0x00] + Array(blob.dropFirst())))  // bad magic
        var badVersion = blob
        badVersion[4] = 2
        XCTAssertNil(WordDictionary(deserializing: badVersion))
        XCTAssertNil(WordDictionary(deserializing: Array(blob.dropLast())))  // truncated
        XCTAssertNil(WordDictionary(deserializing: blob + [0]))  // trailing slack
        var huge = Array(blob.prefix(5))
        huge += [0xff, 0xff, 0xff, 0xff]
        XCTAssertNil(WordDictionary(deserializing: huge))  // count overruns, no crash
    }

    private func header(count: UInt32) -> [UInt8] {
        var b: [UInt8] = [0x47, 0x44, 0x49, 0x43, 1]
        appendLE32(&b, count)
        return b
    }

    func testDeserializeRejectsUnsortedWords() {
        var blob = header(count: 2)
        blob += [1, 0x62, 5]  // "b"
        blob += [1, 0x61, 5]  // "a" sorts before "b"
        appendLE32(&blob, 0)
        XCTAssertNil(WordDictionary(deserializing: blob))
        // Control: the same blob in sorted order is accepted.
        var ok = header(count: 2)
        ok += [1, 0x61, 5, 1, 0x62, 5]
        appendLE32(&ok, 0)
        XCTAssertEqual(WordDictionary(deserializing: ok)?.wordCount, 2)
    }

    func testDeserializeRejectsDuplicateZeroScoreAndBadIndex() {
        var dup = header(count: 2)
        dup += [1, 0x61, 5, 1, 0x61, 5]
        appendLE32(&dup, 0)
        XCTAssertNil(WordDictionary(deserializing: dup))

        var zero = header(count: 1)
        zero += [1, 0x61, 0]
        appendLE32(&zero, 0)
        XCTAssertNil(WordDictionary(deserializing: zero))

        var badKey = header(count: 1)
        badKey += [1, 0x61, 5]
        appendLE32(&badKey, 1)
        appendLE32(&badKey, 7)  // wordIndex out of range
        badKey += [0]
        XCTAssertNil(WordDictionary(deserializing: badKey))

        var badSucc = header(count: 1)
        badSucc += [1, 0x61, 5]
        appendLE32(&badSucc, 1)
        appendLE32(&badSucc, 0)
        badSucc += [1]
        appendLE32(&badSucc, 9)  // succIndex out of range
        badSucc += [5]
        XCTAssertNil(WordDictionary(deserializing: badSucc))

        var goodSucc = header(count: 1)
        goodSucc += [1, 0x61, 5]
        appendLE32(&goodSucc, 1)
        appendLE32(&goodSucc, 0)
        goodSucc += [1]
        appendLE32(&goodSucc, 0)
        goodSucc += [5]
        XCTAssertEqual(WordDictionary(deserializing: goodSucc)?.successors(of: "a", limit: 3), [.init(text: "a", score: 5)])
    }

    func testTopKAtScale() throws {
        // 150k synthetic words "a00000"... with scores cycling 1...255; the true top 12 for "a" are the 12 score-255 words in byte order.
        var entries: [ScoredWord] = []
        for i in 0..<150_000 { entries.append(.init(text: "a" + String(format: "%06d", i), score: UInt8(i % 255 + 1))) }
        let d = try WordDictionary(entries: entries, successors: [:])
        let expected = (0..<150_000).filter { $0 % 255 == 254 }.prefix(12).map { "a" + String(format: "%06d", $0) }
        XCTAssertEqual(d.completions(typed: "a", limit: 12).map(\.text), Array(expected))
    }

    func testBestStoredForm() throws {
        let d = try fixture()
        XCTAssertEqual(d.bestStoredForm(ofFolded: "linux"), ScoredWord(text: "Linux", score: 180))
        XCTAssertEqual(d.bestStoredForm(ofFolded: "api"), ScoredWord(text: "API", score: 160))
        XCTAssertEqual(d.bestStoredForm(ofFolded: "apple"), ScoredWord(text: "apple", score: 100))
        XCTAssertNil(d.bestStoredForm(ofFolded: "th"))
        XCTAssertNil(d.bestStoredForm(ofFolded: "zzz"))
        let tie = try WordDictionary(entries: [.init(text: "Ab", score: 5), .init(text: "aB", score: 5)], successors: [:])
        XCTAssertEqual(tie.bestStoredForm(ofFolded: "ab"), ScoredWord(text: "Ab", score: 5))
    }
}
