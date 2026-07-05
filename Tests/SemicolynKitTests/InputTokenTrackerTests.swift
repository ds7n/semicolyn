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

    // MARK: - L4a leading-space opt-out

    /// Feed bytes and return the tracker's `lineOptedOut` after the feed.
    private func optedOutAfter(_ bytes: [UInt8]) -> Bool {
        var t = InputTokenTracker()
        _ = t.observe(bytes)
        return t.lineOptedOut
    }

    func testLeadingSpaceOptsLineOut() {
        // " secret command" — first byte is a space → line opted out.
        XCTAssertTrue(optedOutAfter(Array(" secret cmd".utf8)))
    }

    func testNoLeadingSpaceDoesNotOptOut() {
        XCTAssertFalse(optedOutAfter(Array("secret cmd".utf8)))
    }

    func testOptOutResetsOnNextLine() {
        // Line 1 opts out (leading space); after Enter, line 2 has no leading space.
        var t = InputTokenTracker()
        _ = t.observe(Array(" hidden".utf8))
        XCTAssertTrue(t.lineOptedOut)
        _ = t.observe([0x0d])                     // Enter → new line
        _ = t.observe(Array("visible".utf8))       // no leading space
        XCTAssertFalse(t.lineOptedOut)
    }

    func testMidLineSpaceDoesNotOptOut() {
        // A space that is NOT the first byte must not opt the line out.
        XCTAssertFalse(optedOutAfter(Array("git commit".utf8)))
    }

    // MARK: - L4b denylist applied through the tracker

    func testTrackerDropsSpaceSeparatedSecretValue() {
        // "mysql -p hunter2\n" → learn mysql, -p ; never hunter2.
        XCTAssertEqual(committedTokens(Array("mysql -p hunter2\r".utf8)), ["mysql", "-p"])
    }

    func testTrackerDropsEqualsJoinedSecretToken() {
        XCTAssertEqual(committedTokens(Array("curl --token=ghp_x\r".utf8)), ["curl"])
    }

    func testTrackerReachBackOverSecretForBigram() {
        // "curl --token SECRET --header\n": the token AFTER the dropped secret
        // (--header) must chain to --token, NOT to SECRET.
        var t = InputTokenTracker()
        let committed = t.observe(Array("curl --token SECRET --header\r".utf8))
        // SECRET is absent…
        XCTAssertEqual(committed.map(\.token), ["curl", "--token", "--header"])
        // …and --header's `previous` reaches back over SECRET to --token.
        let header = committed.first { $0.token == "--header" }
        XCTAssertEqual(header?.previous, "--token")
    }

    func testTrackerDropsUserPassAtHost() {
        XCTAssertEqual(committedTokens(Array("ssh alice:pw@host\r".utf8)), ["ssh"])
    }

    // MARK: - L4a latched commit verdict (the paste / single-chunk case)

    /// Feed bytes and return the latched last-committed-line opt-out.
    private func latchedOptOutAfter(_ bytes: [UInt8]) -> Bool {
        var t = InputTokenTracker()
        _ = t.observe(bytes)
        return t.lastCommittedLineOptedOut
    }

    func testSingleChunkLeadingSpaceLineLatchesOptedOut() {
        // " secret\r" as ONE chunk (the paste path the old App snapshot missed):
        // the latched verdict after observe must be TRUE.
        XCTAssertTrue(latchedOptOutAfter(Array(" secret\r".utf8)))
    }

    func testSingleChunkNormalLineLatchesNotOptedOut() {
        XCTAssertFalse(latchedOptOutAfter(Array("ls -la\r".utf8)))
    }

    func testLatchReflectsLastLineInChunk() {
        // Two lines in one chunk: line1 opted out, line2 not → latch holds line2's
        // verdict (false). (Documents the v1 per-chunk coarseness.)
        XCTAssertFalse(latchedOptOutAfter(Array(" a\rb\r".utf8)))
        // And the reverse: last line opted out → latch true.
        XCTAssertTrue(latchedOptOutAfter(Array("a\r b\r".utf8)))
    }

    func testLatchClearedByReset() {
        var t = InputTokenTracker()
        _ = t.observe(Array(" x\r".utf8))
        XCTAssertTrue(t.lastCommittedLineOptedOut)
        t.reset()
        XCTAssertFalse(t.lastCommittedLineOptedOut)
    }
}
