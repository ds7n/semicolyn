// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Shared ranking fixture (reused by the next-word tests).
enum RankFixture {
    static func english() throws -> WordDictionary {
        try WordDictionary(entries: [
            .init(text: "the", score: 255), .init(text: "they", score: 200), .init(text: "still", score: 240),
            .init(text: "status", score: 60), .init(text: "theme", score: 120), .init(text: "cat", score: 100),
            .init(text: "car", score: 150), .init(text: "Linux", score: 180), .init(text: "including", score: 140),
            .init(text: "damn", score: 120), .init(text: "teh", score: 1), .init(text: "receive", score: 150),
            // "git" must be an entry for its successor key to be valid (WordDictionary rule).
            .init(text: "git", score: 1)],
            successors: ["the": [.init(text: "cat", score: 255)], "git": [.init(text: "still", score: 10)]])
    }
    static func commands() -> CommandTree {
        CommandTree(tools: [
            CommandNode(name: "git", score: 255, children: [
                CommandNode(name: "status", score: 255, children: [], flags: []),
                CommandNode(name: "stash", score: 180, children: [], flags: []),
                CommandNode(name: "commit", score: 200, children: [], flags: [])], flags: []),
            CommandNode(name: "theme", score: 250, children: [], flags: [])], pipeTargets: [])
    }
    static func engine(filter: TokenFilter = .init()) throws -> PredictorEngine {
        PredictorEngine(learned: .empty, english: try english(), commands: commands(), filter: filter)
    }
}

/// The single ranker behind `PredictorEngine.suggestions(line:lineOptedOut:limit:)`, completion mode.
/// Core tier: expected orders and scores are derived from the documented formula.
final class SuggestionRankerTests: XCTestCase {
    func texts(_ e: PredictorEngine, _ line: String, _ n: Int = 12) -> [String] {
        e.suggestions(line: line, lineOptedOut: false, limit: n).map(\.text)
    }

    /// `log2(1 + learnedSaturation)` for the default saturation of 64.
    private let saturationLog = log2(65.0)

    func testOneLetterGetsSuggestions() throws {
        XCTAssertEqual(texts(try RankFixture.engine(), "t", 2), ["theme", "the"])  // undecided line: theme = 120/255 English + 250/255 command
    }

    func testCommandContextWins() throws {
        let e = try RankFixture.engine()
        XCTAssertEqual(texts(e, "git st", 2), ["status", "stash"])
        XCTAssertEqual(e.suggestions(line: "git st", lineOptedOut: false, limit: 1).first?.kind, .completion)
    }

    func testCommandLineScoresSumEnglishHalfWeightAndCommand() throws {
        let s = try RankFixture.engine().suggestions(line: "git st", lineOptedOut: false)
        XCTAssertEqual(s.map(\.text), ["status", "stash", "still"])
        XCTAssertEqual(s[0].score, 1.0 + 0.5 * 60 / 255, accuracy: 1e-9)
        XCTAssertEqual(s[1].score, 180.0 / 255, accuracy: 1e-9)
        // English at half weight plus the "git -> still" successor context term.
        XCTAssertEqual(s[2].score, 0.5 * 240 / 255 + 0.5 * 10 / 255, accuracy: 1e-9)
    }

    func testProseHasNoCommandWords() throws {
        let e = try RankFixture.engine()
        XCTAssertEqual(texts(e, "can you check the th"), ["the", "they", "theme"])  // prose: theme scores as English only, no command term
    }

    func testBigramContextReorders() throws {
        XCTAssertEqual(texts(try RankFixture.engine(), "feed the ca", 2), ["cat", "car"])
    }

    func testCaseAndPunctuation() throws {
        let e = try RankFixture.engine()
        XCTAssertEqual(texts(e, "lin"), ["Linux"])
        XCTAssertEqual(texts(e, "go (inc"), ["including"])
        XCTAssertEqual(texts(e, "me, x,"), [])                                 // cursor after trailing punctuation
    }

    func testExactTypedWordNotSuggested() throws {
        XCTAssertFalse(texts(try RankFixture.engine(), "say they").contains("they"))
    }

    func testCorrectionOffered() throws {
        let s = try RankFixture.engine().suggestions(line: "recieve", lineOptedOut: false)
        XCTAssertEqual(s.map(\.text), ["receive"]); XCTAssertEqual(s.first?.kind, .correction)
        XCTAssertEqual(s.first?.score ?? 0, 0.7 * 150 / 255, accuracy: 1e-9)
    }

    func testCorrectionPassesReadTimeFilter() throws {
        let f = TokenFilter(patterns: TokenFilter.defaultPatterns + [.blocklist(["receive"])])
        XCTAssertEqual(try RankFixture.engine(filter: f).suggestions(line: "recieve", lineOptedOut: false), [])
    }

    func testReadTimeFilter() throws {
        let f = TokenFilter(patterns: TokenFilter.defaultPatterns + [.blocklist(["damn"])])
        XCTAssertFalse(texts(try RankFixture.engine(filter: f), "da").contains("damn"))
        XCTAssertTrue(texts(try RankFixture.engine(), "da").contains("damn"))
    }

    func testLearnedOutranksAndAppears() throws {
        var e = try RankFixture.engine()
        for prev in ["a", "b", "c", "d", "e", "f"] { e.record("semicolyn", after: prev) }
        XCTAssertEqual(texts(e, "se", 1), ["semicolyn"])
        XCTAssertEqual(e.suggestions(line: "se", lineOptedOut: false).first?.score ?? 0,
                       log2(7.0) / saturationLog, accuracy: 1e-9)
    }

    func testLearnedMixedCaseFound() throws {
        var e = try RankFixture.engine()
        for prev in ["a", "b", "c"] { e.record("GitHub", after: prev) }
        // "git" is the edit-distance-1 correction of "gith": 0.7 * 1/255, below GitHub's learned 2/log2(65).
        XCTAssertEqual(texts(e, "gith"), ["GitHub", "git"])
    }

    func testLearnedCaseConflictNotOffered() throws {
        var e = try RankFixture.engine()
        for prev in ["a", "b", "c"] { e.record("foobar", after: prev) }
        // An uppercase typed letter must match exactly unless the candidate is all lowercase.
        XCTAssertEqual(texts(e, "FooB"), [])
        XCTAssertEqual(texts(e, "Foob"), ["Foobar"])
    }

    func testLearnedBigramContextAddsTerm() throws {
        var e = try RankFixture.engine()
        for prev in ["my", "x", "y"] { e.record("car", after: prev) }
        let withContext = e.suggestions(line: "feed my ca", lineOptedOut: false)
        XCTAssertEqual(withContext.map(\.text), ["car", "cat"])
        XCTAssertEqual(withContext[0].score, 150.0 / 255 + 2 / saturationLog + 0.5 * 1 / saturationLog, accuracy: 1e-9)
        let without = e.suggestions(line: "feed your ca", lineOptedOut: false)
        XCTAssertEqual(without[0].score, 150.0 / 255 + 2 / saturationLog, accuracy: 1e-9)
    }

    func testScreenWordsDecayByRecency() throws {
        var e = try RankFixture.engine()
        e.harvest(output: "thermal thermos")
        let s = e.suggestions(line: "so so therm", lineOptedOut: false)
        XCTAssertEqual(s.map(\.text), ["thermos", "thermal"])
        XCTAssertEqual(s[0].score, 0.6, accuracy: 1e-9)
        XCTAssertEqual(s[1].score, 0.3, accuracy: 1e-9)
    }

    func testScreenWordsMatchCaseInsensitively() throws {
        var e = try RankFixture.engine()
        e.harvest(output: "README.md")
        XCTAssertEqual(texts(e, "so so rea"), ["README.md"])
    }

    func testNoSourcesYieldsNothing() {
        let e = PredictorEngine(learned: .empty, english: nil, commands: nil)
        XCTAssertEqual(texts(e, "t"), [])
        XCTAssertEqual(texts(e, "recieve"), [])
    }

    func testEnglishOnlyEngineSkipsCommands() throws {
        let e = PredictorEngine(learned: .empty, english: try RankFixture.english(), commands: nil)
        XCTAssertEqual(texts(e, "git st"), ["still", "status"])  // no known tools: the one-word line stays undecided, English keeps full weight
    }

    func testLimitBoundary() throws {
        let e = try RankFixture.engine()
        XCTAssertEqual(texts(e, "t", 0), [])
        XCTAssertEqual(texts(e, "t", 1).count, 1)
        XCTAssertEqual(texts(e, "t", 1), ["theme"])
        XCTAssertEqual(texts(e, "t", 4), ["theme", "the", "they", "teh"])
        XCTAssertEqual(texts(e, "t", 5), ["theme", "the", "they", "teh"])
    }

    func testDefaultWeights() {
        let w = RankingWeights()
        XCTAssertEqual(w.english, 1.0); XCTAssertEqual(w.englishInCommand, 0.5); XCTAssertEqual(w.commands, 1.0)
        XCTAssertEqual(w.learnedSaturation, 64); XCTAssertEqual(w.screen, 0.6); XCTAssertEqual(w.correction, 0.7)
        XCTAssertEqual(w.nextWord, 0.9); XCTAssertEqual(w.nextWordAfterWord, 0.45); XCTAssertEqual(w.context, 0.5)
    }
}
