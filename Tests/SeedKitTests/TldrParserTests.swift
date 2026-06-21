// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SeedKit

/// TldrParser — Core tier. Markdown tldr page → command-invocation token
/// sequences. See `2026-06-21-predictor-seed-ingestion-design`.
final class TldrParserTests: XCTestCase {
    func testExtractsCommandTokensFromCodeSpan() {
        let page = """
        # git status

        > Show the working tree status.

        - Show the status:

        `git status`
        """
        XCTAssertEqual(TldrParser.invocations(fromPage: page), [["git", "status"]])
    }

    func testStripsPlaceholders() {
        // {{...}} are user-substituted args, not vocabulary.
        let page = "`git commit --message \"{{message}}\"`"
        XCTAssertEqual(TldrParser.invocations(fromPage: page), [["git", "commit", "--message"]])
    }

    func testStripsSurroundingQuotes() {
        // A quoted literal (no placeholder) keeps its inner text; quotes are noise.
        let page = "`echo \"hello\"`"
        XCTAssertEqual(TldrParser.invocations(fromPage: page), [["echo", "hello"]])
    }

    func testIgnoresProseAndHeaders() {
        // Only backtick-delimited spans contribute; prose lines have none.
        let page = """
        # kubectl

        > Kubernetes cluster manager.
        > More information: <https://kubernetes.io>.
        """
        XCTAssertEqual(TldrParser.invocations(fromPage: page), [])
    }

    func testMultipleExamplesYieldMultipleSequences() {
        let page = """
        # git

        - Stage a file:

        `git add {{file}}`

        - Commit:

        `git commit`
        """
        XCTAssertEqual(TldrParser.invocations(fromPage: page),
                       [["git", "add"], ["git", "commit"]])
    }

    func testPlaceholderOnlyTokenLeavesCommandIntact() {
        // `git add {{path/to/file}}` → the placeholder drops, leaving "git add".
        let page = "`git add {{path/to/file}}`"
        XCTAssertEqual(TldrParser.invocations(fromPage: page), [["git", "add"]])
    }

    func testEmptyAndNoCodePagesReturnEmpty() {
        XCTAssertEqual(TldrParser.invocations(fromPage: ""), [])
        XCTAssertEqual(TldrParser.invocations(fromPage: "no backticks here"), [])
    }

    func testSplitsOnPipeIntoSeparateSegments() {
        // A bigram must never cross a pipe: no (log, grep) pair.
        let page = "`git log | grep fix`"
        XCTAssertEqual(TldrParser.invocations(fromPage: page),
                       [["git", "log"], ["grep", "fix"]])
    }

    func testSplitsOnAndAndSemicolon() {
        let page = "`cd dir && ls; pwd`"
        XCTAssertEqual(TldrParser.invocations(fromPage: page),
                       [["cd", "dir"], ["ls"], ["pwd"]])
    }

    func testRedirectionOperatorsAreNotVocabulary() {
        // `>` (and the placeholder target) drop; only "echo hi" survives.
        let page = "`echo hi > {{file}}`"
        XCTAssertEqual(TldrParser.invocations(fromPage: page), [["echo", "hi"]])
    }

    func testRedirectionVariantsDrop() {
        // `2>&1` is a redirection token, not vocabulary.
        let page = "`cmd run 2>&1`"
        XCTAssertEqual(TldrParser.invocations(fromPage: page), [["cmd", "run"]])
    }

    func testMatchedQuoteLiteralSurvives() {
        // `tr "'" "x"`: the literal single-quote argument must live on as `'`,
        // not be erased by over-eager quote stripping.
        let page = "`tr \"'\" x`"
        XCTAssertEqual(TldrParser.invocations(fromPage: page), [["tr", "'", "x"]])
    }
}
