// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Next-word mode of the single ranker (empty current word, and lower-weight
/// successors after a finished word) plus the normalized learning in `record`.
/// Core tier: expected orders and scores are derived from the documented formula.
final class NextWordRankingTests: XCTestCase {
    func run(_ line: String, optedOut: Bool = false) throws -> [Suggestion] {
        try RankFixture.engine().suggestions(line: line, lineOptedOut: optedOut, limit: 12)
    }

    /// `log2(1 + learnedSaturation)` for the default saturation of 64.
    private let saturationLog = log2(65.0)

    /// The score at `index`, or NaN (which fails every accuracy comparison) when absent,
    /// so a short result fails the assertion instead of trapping the test process.
    private func score(_ s: [Suggestion], _ index: Int) -> Double {
        index < s.count ? s[index].score : .nan
    }

    /// Records `token` after three distinct previous words so it graduates (threshold 3).
    private func graduate(_ e: inout PredictorEngine, _ token: String, after previous: [String]) {
        for prev in previous { e.record(token, after: prev) }
    }

    // MARK: - Brief tests

    func testSubcommandsAfterTool() throws {
        let s = try run("git ")
        XCTAssertEqual(s.map(\.text), ["status", "commit", "stash", "still"])
        XCTAssertEqual(Set(s.map(\.kind)), [.nextWord])
    }

    func testEnglishSuccessors() throws {
        XCTAssertEqual(try run("feed the ").map(\.text), ["cat"])
    }

    func testGates() throws {
        XCTAssertEqual(try run("git ", optedOut: true), [])
        XCTAssertEqual(try run(""), [])
        XCTAssertEqual(try run("git --password "), [])     // next token would be a secret value
    }

    func testNextWordAfterFinishedWordRanksLow() throws {
        let s = try run("feed the")
        XCTAssertEqual(s.first?.text, "they")             // completion of "the"
        XCTAssertTrue(s.contains(Suggestion(text: "cat", kind: .nextWord, score: 0.45)))
    }

    func testNoNextWordAfterHalfWord() throws {
        XCTAssertFalse(try run("feed th").contains { $0.kind == .nextWord })  // "th" is not a word
    }

    func testRecordNormalizes() throws {
        var e = try RankFixture.engine()
        for prev in ["(a", "b,", "c."] { e.record("Zebra,", after: prev) }
        XCTAssertEqual(e.suggestions(line: "zeb", lineOptedOut: false).map(\.text), ["Zebra"])
        e.record("((", after: nil)
        XCTAssertEqual(e.state.unigram.containsLiteral("(("), false)
    }

    // MARK: - Exact scores per source

    func testSubcommandScoresExact() throws {
        let s = try run("git ")
        XCTAssertEqual(s.count, 4)
        XCTAssertEqual(score(s, 0), 0.9, accuracy: 1e-12)
        XCTAssertEqual(score(s, 1), 0.9 * 200 / 255, accuracy: 1e-12)
        XCTAssertEqual(score(s, 2), 0.9 * 180 / 255, accuracy: 1e-12)
        // English successor at the command-line half weight.
        XCTAssertEqual(score(s, 3), 0.9 * 10 / 255 * 0.5, accuracy: 1e-12)
    }

    func testProseLineHasNoSubcommandsAndFullEnglishWeight() throws {
        // Three completed words, first not a tool: prose, so no command candidates.
        let s = try run("I like git ")
        XCTAssertEqual(s, [Suggestion(text: "still", kind: .nextWord, score: 0.9 * (10.0 / 255))])
    }

    func testAfterPipeOffersToolsAtHalfScore() throws {
        let s = try run("ls | ")
        XCTAssertEqual(s.map(\.text), ["git", "theme"])
        XCTAssertEqual(score(s, 0), 0.9 * 127 / 255, accuracy: 1e-12)
        XCTAssertEqual(score(s, 1), 0.9 * 125 / 255, accuracy: 1e-12)
        XCTAssertEqual(Set(s.map(\.kind)), [.nextWord])
    }

    func testStartOfLineGateBoundaries() throws {
        XCTAssertEqual(try run(" "), [])                  // only whitespace: no previous word, no segment
        XCTAssertEqual(try run("ls ; "), [])              // fresh segment after `;`, not a pipe: nothing to follow
    }

    func testSecretFlagGateIsSpecific() throws {
        XCTAssertEqual(try run("git -p "), [])            // short secret flag
        XCTAssertEqual(try run("curl --token "), [])
        // A flag that is not a secret flag keeps next-word mode alive (subcommands of git).
        XCTAssertEqual(try run("git --verbose ").map(\.text), ["status", "commit", "stash"])
    }

    func testOptedOutLineStillCompletesButNoNextWord() throws {
        let s = try run("feed the", optedOut: true)
        XCTAssertEqual(s.map(\.text), ["they", "theme"])
        XCTAssertFalse(s.contains { $0.kind == .nextWord })
    }

    func testNoNextWordChipsAfterASecretValue() throws {
        // An empty pattern list lets the secret-shaped literals be learned, so each line
        // below WOULD offer a learned next word if the secret-value guard were missing.
        var e = PredictorEngine(learned: .empty, english: try RankFixture.english(),
                                commands: RankFixture.commands(), filter: TokenFilter(patterns: []))
        for secret in ["summer", "sunshine"] {
            for _ in 0..<3 { e.record(secret, after: nil) }        // finished word: a learned literal
            graduate(&e, "again", after: [secret, "x", "y"])       // learned successor of the secret
        }
        func nextWords(_ line: String) -> [Suggestion] {
            e.suggestions(line: line, lineOptedOut: false).filter { $0.kind == .nextWord }
        }
        // Controls: the same finished words outside a secret slot do get the successor.
        XCTAssertEqual(nextWords("feed summer").map(\.text), ["again"])
        XCTAssertEqual(nextWords("mysql sunshine").map(\.text), ["again"])
        XCTAssertEqual(nextWords("feed the").map(\.text), ["cat"])
        // Secret values: a bare secret flag before the word.
        XCTAssertEqual(nextWords("curl --token summer"), [])
        XCTAssertEqual(nextWords("mysql -p sunshine"), [])
    }

    func testNoNextWordChipsAfterAnEmbeddedSecretValue() throws {
        // No patterns and no entropy band: these 18+ character literals would otherwise
        // graduate count-only (soft entropy band) and never count as finished words.
        let f = TokenFilter(patterns: [], entropyThreshold: nil)
        var e = PredictorEngine(learned: .empty, english: nil, commands: nil, filter: f)
        for _ in 0..<3 { e.record("--verbose=sunshine", after: nil) }
        for _ in 0..<3 { e.record("--password=sunshine", after: nil) }
        graduate(&e, "again", after: ["--verbose=sunshine", "--password=sunshine", "y"])
        let kinds = { (line: String) in
            e.suggestions(line: line, lineOptedOut: false).filter { $0.kind == .nextWord }.map(\.text)
        }
        XCTAssertEqual(kinds("mysql --verbose=sunshine"), ["again"])  // control: not a secret flag
        XCTAssertEqual(kinds("mysql --password=sunshine"), [])
    }

    func testNextWordFilteredAtReadTime() throws {
        let f = TokenFilter(patterns: TokenFilter.defaultPatterns + [.blocklist(["cat"])])
        let e = try RankFixture.engine(filter: f)
        XCTAssertEqual(e.suggestions(line: "feed the ", lineOptedOut: false), [])
        XCTAssertFalse(e.suggestions(line: "feed the", lineOptedOut: false).contains { $0.text == "cat" })
    }

    func testLimitAppliesToNextWord() throws {
        let e = try RankFixture.engine()
        XCTAssertEqual(e.suggestions(line: "git ", lineOptedOut: false, limit: 2).map(\.text), ["status", "commit"])
        XCTAssertEqual(e.suggestions(line: "git ", lineOptedOut: false, limit: 0), [])
    }

    // MARK: - After a finished word

    func testFinishedKnownToolOffersSubcommandsAtLowWeight() throws {
        let s = try run("git")
        XCTAssertEqual(s.map(\.text), ["status", "commit", "stash", "still"])
        XCTAssertEqual(Set(s.map(\.kind)), [.nextWord])
        XCTAssertEqual(score(s, 0), 0.45, accuracy: 1e-12)
        XCTAssertEqual(score(s, 1), 0.45 * 200 / 255, accuracy: 1e-12)
        XCTAssertEqual(score(s, 3), 0.45 * 10 / 255 * 0.5, accuracy: 1e-12)
    }

    func testFinishedWordSuccessorsRankAfterCompletions() throws {
        let s = try run("feed the")
        XCTAssertEqual(s.map(\.text), ["they", "theme", "cat"])
        XCTAssertEqual(s.map(\.kind), [.completion, .completion, .nextWord])
    }

    func testFinishedLearnedLiteralOffersLearnedSuccessor() throws {
        var e = try RankFixture.engine()
        for _ in 0..<3 { e.record("zebra", after: nil) }          // graduates at start of line
        graduate(&e, "stripes", after: ["zebra", "a", "b"])
        let s = e.suggestions(line: "feed zebra", lineOptedOut: false)
        XCTAssertEqual(s, [Suggestion(text: "stripes", kind: .nextWord, score: 0.45 * (1 / saturationLog))])
        // A half word of the same learned literal is not finished: no next word.
        XCTAssertEqual(e.suggestions(line: "feed zebr", lineOptedOut: false).map(\.text), ["zebra"])
    }

    func testNextWordDoesNotDuplicateACompletion() throws {
        var e = try RankFixture.engine()
        graduate(&e, "theme", after: ["the", "a", "my"])           // learned bigram the -> theme
        let s = e.suggestions(line: "feed the", lineOptedOut: false)
        XCTAssertEqual(s.filter { $0.text == "theme" }.map(\.kind), [.completion])
        // The completion keeps its own score: English + learned (count 3); the previous
        // word is "feed", so no context term. The 0.45 / log2(65) next-word copy is dropped.
        let theme = try XCTUnwrap(s.first { $0.text == "theme" })
        XCTAssertEqual(theme.score, 120.0 / 255 + 2 / saturationLog, accuracy: 1e-12)
    }

    // MARK: - Learned bigrams keyed on the folded previous word

    func testLearnedSuccessorAfterCapitalizedPreviousWord() throws {
        var e = try RankFixture.engine()
        graduate(&e, "think", after: ["I", "we", "you"])
        XCTAssertEqual(e.suggestions(line: "I ", lineOptedOut: false),
                       [Suggestion(text: "think", kind: .nextWord, score: 0.9 * (1 / saturationLog))])
        // Lowercase previous word reads the same folded key.
        XCTAssertEqual(e.suggestions(line: "i ", lineOptedOut: false).map(\.text), ["think"])
    }

    func testContextBonusAfterCapitalizedPreviousWord() throws {
        var e = try RankFixture.engine()
        graduate(&e, "think", after: ["I", "we", "you"])
        let s = e.suggestions(line: "I th", lineOptedOut: false)
        XCTAssertEqual(s.map(\.text), ["the", "they", "theme", "think"])
        // Learned term (count 3) plus the context term for the learned bigram i -> think (count 1).
        XCTAssertEqual(score(s, 3), 2 / saturationLog + 0.5 / saturationLog, accuracy: 1e-12)
    }

    func testEnglishAndLearnedSuccessorsSumAfterCapitalizedThe() throws {
        var e = try RankFixture.engine()
        graduate(&e, "cat", after: ["The", "A", "My"])
        let s = e.suggestions(line: "The ", lineOptedOut: false)
        XCTAssertEqual(s.map(\.text), ["cat"])
        XCTAssertEqual(score(s, 0), 0.9 + 0.9 / saturationLog, accuracy: 1e-12)
    }

    // MARK: - record normalization

    func testRecordFoldsAndTrimsBigramKey() throws {
        var e = try RankFixture.engine()
        graduate(&e, "think", after: ["(I", "We,", "\"You"])
        let bigram = e.state.bigram
        XCTAssertEqual(bigram.candidates(after: "i", window: .days30).map(\.token), ["think"])
        XCTAssertEqual(bigram.candidates(after: "we", window: .days30).map(\.token), ["think"])
        XCTAssertEqual(bigram.candidates(after: "you", window: .days30).map(\.token), ["think"])
        XCTAssertEqual(bigram.candidates(after: "(I", window: .days30), [])
        XCTAssertEqual(bigram.candidates(after: "I", window: .days30), [])
    }

    func testRecordStoresTrimmedWordNotRawToken() throws {
        var e = try RankFixture.engine()
        graduate(&e, "(Zebra),", after: ["a", "b", "c"])
        XCTAssertTrue(e.state.unigram.containsLiteral("Zebra"))
        XCTAssertFalse(e.state.unigram.containsLiteral("(Zebra),"))
    }

    func testRecordKeepsPathAndFlagTokensWhole() throws {
        var e = try RankFixture.engine()
        graduate(&e, "./run.sh", after: ["a", "b", "c"])
        graduate(&e, "--verbose", after: ["a", "b", "c"])
        XCTAssertTrue(e.state.unigram.containsLiteral("./run.sh"))
        XCTAssertTrue(e.state.unigram.containsLiteral("--verbose"))
    }

    func testRecordDropsPurePunctuationEvenWhenRepeated() throws {
        var e = try RankFixture.engine()
        graduate(&e, "((", after: ["a", "b", "c"])           // would graduate if it were a word
        for _ in 0..<3 { e.record("...", after: nil) }
        XCTAssertFalse(e.state.unigram.containsLiteral("(("))
        XCTAssertFalse(e.state.unigram.containsLiteral(""))
        XCTAssertFalse(e.state.unigram.containsLiteral("..."))
        XCTAssertEqual(e.state.unigram.learnedSource(window: .days30).candidates(forPrefix: ""), [])
    }

    func testPunctuationOnlyPreviousRecordsNoBigram() throws {
        var e = try RankFixture.engine()
        for _ in 0..<3 { e.record("zebra", after: "((") }
        XCTAssertTrue(e.state.unigram.containsLiteral("zebra"))   // treated as start of line
        XCTAssertEqual(e.state.bigram.candidates(after: "", window: .days30), [])
        XCTAssertEqual(e.state.bigram.candidates(after: "((", window: .days30), [])
    }

    func testExcludedPreviousStillSuppressesAdjacencyAfterTrimming() throws {
        // `(damn` is not blocklisted as a raw token, but its trimmed word is.
        let f = TokenFilter(patterns: TokenFilter.defaultPatterns + [.blocklist(["damn"])])
        var e = PredictorEngine(learned: .empty, english: try RankFixture.english(),
                                commands: RankFixture.commands(), filter: f)
        graduate(&e, "zebra", after: ["(damn", "b", "c"])
        XCTAssertTrue(e.state.unigram.containsLiteral("zebra"))
        XCTAssertEqual(e.state.bigram.candidates(after: "damn", window: .days30), [])
        XCTAssertEqual(e.state.bigram.candidates(after: "(damn", window: .days30), [])
        XCTAssertEqual(e.state.bigram.candidates(after: "b", window: .days30).map(\.token), ["zebra"])
    }

    func testExcludedTrimmedTokenNotRecorded() throws {
        let f = TokenFilter(patterns: TokenFilter.defaultPatterns + [.blocklist(["damn"])])
        var e = PredictorEngine(learned: .empty, english: nil, commands: nil, filter: f)
        graduate(&e, "damn,", after: ["a", "b", "c"])
        XCTAssertFalse(e.state.unigram.containsLiteral("damn"))
        XCTAssertFalse(e.state.unigram.containsLiteral("damn,"))
        XCTAssertEqual(e.state.unigram.learnedSource(window: .days30).candidates(forPrefix: "d"), [])
    }
}
