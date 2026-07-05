// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class InputTokenTrackerTests: XCTestCase {
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testTypingBuildsCurrentToken() {
        var t = InputTokenTracker()
        let committed = t.observe(bytes("clau"))
        XCTAssertTrue(committed.isEmpty)
        XCTAssertEqual(t.current, "clau")
        XCTAssertNil(t.previous)
    }

    func testSpaceCommitsAndShiftsPrevious() {
        var t = InputTokenTracker()
        let committed = t.observe(bytes("git "))
        XCTAssertEqual(committed, [CommittedToken(token: "git", previous: nil)])
        XCTAssertEqual(t.current, "")
        XCTAssertEqual(t.previous, "git")
    }

    func testSecondTokenCarriesPreviousForBigram() {
        var t = InputTokenTracker()
        let committed = t.observe(bytes("git commit"))
        XCTAssertEqual(committed, [CommittedToken(token: "git", previous: nil)])
        XCTAssertEqual(t.current, "commit")
        XCTAssertEqual(t.previous, "git")   // drives suggestions(forPrefix:"commit", after:"git")
    }

    func testMultipleTokensInOneChunk() {
        var t = InputTokenTracker()
        let committed = t.observe(bytes("a b c"))
        XCTAssertEqual(committed, [CommittedToken(token: "a", previous: nil),
                                   CommittedToken(token: "b", previous: "a")])
        XCTAssertEqual(t.current, "c")
        XCTAssertEqual(t.previous, "b")
    }

    func testEnterCommitsAndResetsLine() {
        var t = InputTokenTracker()
        _ = t.observe(bytes("git commit"))
        let committed = t.observe([0x0d])
        XCTAssertEqual(committed, [CommittedToken(token: "commit", previous: "git")])
        XCTAssertEqual(t.current, "")
        XCTAssertNil(t.previous)            // new line: no preceding token
    }

    func testBackspacePopsCurrent() {
        var t = InputTokenTracker()
        _ = t.observe(bytes("claude"))
        _ = t.observe([0x7f])
        XCTAssertEqual(t.current, "claud")
    }

    func testTabClearsCurrentWithoutCommitting() {
        var t = InputTokenTracker()
        _ = t.observe(bytes("co"))
        let committed = t.observe([0x09])
        XCTAssertTrue(committed.isEmpty)    // remote completion, not a learned token
        XCTAssertEqual(t.current, "")
    }

    func testControlByteResetsLineContext() {
        var t = InputTokenTracker()
        _ = t.observe(bytes("git commit"))
        _ = t.observe([0x03])              // Ctrl+C
        XCTAssertEqual(t.current, "")
        XCTAssertNil(t.previous)
    }

    func testChipsDropExactCurrentAndEmpties() {
        XCTAssertEqual(predictorChips(current: "clau", suggestions: ["claude", "clang"]),
                       ["claude", "clang"])
        XCTAssertEqual(predictorChips(current: "claude", suggestions: ["claude", "clangd"]),
                       ["clangd"])          // exact current dropped
        XCTAssertEqual(predictorChips(current: "x", suggestions: []), [])
    }

    // MARK: - L3 bracketed paste

    /// Bracketed-paste enter/exit markers as raw bytes.
    private let pasteOn: [UInt8]  = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]  // ESC[200~
    private let pasteOff: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]  // ESC[201~

    /// Feed a full byte sequence and collect every committed token's `.token`.
    private func committedTokens(_ bytes: [UInt8]) -> [String] {
        var t = InputTokenTracker()
        return t.observe(bytes).map(\.token)
    }

    func testTokenTypedInsidePasteIsNotCommitted() {
        // export TOKEN=<paste>ghp_secret</paste>\n  → the pasted value must not learn.
        var input: [UInt8] = Array("export ".utf8)
        input += pasteOn
        input += Array("ghp_deadbeef".utf8)
        input += pasteOff
        input += [0x0d]
        let tokens = committedTokens(input)
        XCTAssertEqual(tokens, ["export"])            // only the pre-paste token
        XCTAssertFalse(tokens.contains("ghp_deadbeef"))
    }

    func testTokensBeforeAndAfterPasteStillCommit() {
        // a <paste>b</paste> c\n  → learn "a" and "c", never "b".
        var input: [UInt8] = Array("a ".utf8)
        input += pasteOn; input += Array("b".utf8); input += pasteOff
        input += Array(" c".utf8); input += [0x0d]
        XCTAssertEqual(committedTokens(input), ["a", "c"])
    }

    func testUnmatchedPasteOpenFailsClosed() {
        // ESC[200~ with no close: everything after stays suppressed until reset.
        var input: [UInt8] = pasteOn
        input += Array("secretvalue".utf8)
        input += [0x0d]                                // Enter commits the line…
        XCTAssertEqual(committedTokens(input), [])     // …but nothing was learnable
    }

    func testUnmatchedPasteCloseIsIgnored() {
        // A stray ESC[201~ with no open: a recognized (if redundant) exit marker is
        // consumed harmlessly — it does not reset the line.
        var input: [UInt8] = Array("ls".utf8)
        input += pasteOff
        input += Array(" -la".utf8); input += [0x0d]
        XCTAssertEqual(committedTokens(input), ["ls", "-la"])
    }
}
