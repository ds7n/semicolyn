// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import SemicolynKit
@testable import SeedKit

final class DictionaryInspectorTests: XCTestCase {
    func testEnglishRoundTripReport() throws {
        let entries = [ScoredWord(text: "the", score: 250), ScoredWord(text: "to", score: 200),
                       ScoredWord(text: "I", score: 240), ScoredWord(text: "Linux", score: 150),
                       ScoredWord(text: "API", score: 100), ScoredWord(text: "apple", score: 90)]
        let successors = ["the": [ScoredWord(text: "Linux", score: 150)],
                          "i": [ScoredWord(text: "to", score: 7)]]
        let blob = try WordDictionary(entries: entries, successors: successors).serialize()
        let report = try inspectDictionary(blob)
        XCTAssertEqual(report.split(separator: "\n").map(String.init), [
            "format: GDIC english",
            "bytes: \(blob.count)",
            "words: 6",
            "complete t: the:250 to:200",
            "complete th: the:250",
            "complete Th: The:250",
            "complete i: I:240",
            "complete I: I:240",
            "complete lin: Linux:150",
            "complete ap: API:100 apple:90",
            "complete AP: API:100",
            "after the: Linux:150",
            "after I: to:7",
            "after to: (none)",
        ])
    }

    func testCommandRoundTripReport() throws {
        let commit = CommandNode(name: "commit", score: 200, children: [], flags: [ScoredWord(text: "-m", score: 9)])
        let git = CommandNode(name: "git", score: 255, children: [commit], flags: [])
        let ls = CommandNode(name: "ls", score: 180, children: [], flags: [ScoredWord(text: "-l", score: 50)])
        let blob = CommandTree(tools: [git, ls], pipeTargets: [ScoredWord(text: "grep", score: 240)]).serialize()
        let report = try inspectDictionary(blob)
        XCTAssertEqual(report.split(separator: "\n").map(String.init), [
            "format: GCMT commands",
            "bytes: \(blob.count)",
            "tools: 2",
            "probe 'line start': git:255 ls:180",
            "probe 'git ': commit:200",
            "probe 'git c': commit:200",
            "probe 'docker ': (none)",
            "probe 'ls -': -l:50",
            "probe '| ': grep:240 git:127 ls:90",
        ])
    }

    func testUnknownAndCorruptBlobsAreNamed() throws {
        XCTAssertThrowsError(try inspectDictionary(Array("NOPE1234".utf8))) { error in
            XCTAssertEqual(error as? DictionaryInspectError, .unknownFormat)
        }
        XCTAssertThrowsError(try inspectDictionary([0x47, 0x44, 0x49])) { error in
            XCTAssertEqual(error as? DictionaryInspectError, .unknownFormat)
        }
        let truncated = Array(try WordDictionary(entries: [ScoredWord(text: "a", score: 1)], successors: [:])
            .serialize().dropLast())
        XCTAssertThrowsError(try inspectDictionary(truncated)) { error in
            XCTAssertEqual(error as? DictionaryInspectError, .corrupt("GDIC"))
        }
        XCTAssertThrowsError(try inspectDictionary(Array("GCMT".utf8) + [1])) { error in
            XCTAssertEqual(error as? DictionaryInspectError, .corrupt("GCMT"))
        }
    }
}
