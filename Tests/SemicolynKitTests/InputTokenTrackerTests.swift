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
        // consumed harmlessly, it does not reset the line.
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
        // " secret command", first byte is a space → line opted out.
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

    // MARK: - Drop-gate tallies (privacy-safe diagnostics: counts only, never text)

    func testSecretDropIncrementsSecretTallyOnly() {
        // One dropped secret value → droppedAsSecret == 1, droppedInPaste == 0.
        var t = InputTokenTracker()
        _ = t.observe(Array("mysql -p hunter2\r".utf8))
        XCTAssertEqual(t.droppedAsSecret, 1)
        XCTAssertEqual(t.droppedInPaste, 0)
    }

    func testTwoFlaggedSecretsOnOneLineTallyTwo() {
        // Two flag→value secrets on one line → the secret gate fires twice.
        // (Matches `testTrackerReachBackOverSecretForBigram`: only the value AFTER a
        // secret-flag is dropped, so each `-p <val>` pair contributes exactly one drop.)
        var t = InputTokenTracker()
        _ = t.observe(Array("mysql -p hunter2 -p swordfish\r".utf8))
        XCTAssertEqual(t.droppedAsSecret, 2)
    }

    func testPasteDropIncrementsPasteTallyOnly() {
        // The token accumulated inside a paste is dropped by L3 → droppedInPaste == 1,
        // droppedAsSecret == 0 (the paste gate fired, the secret gate did not).
        var t = InputTokenTracker()
        var input: [UInt8] = Array("a ".utf8)
        input += pasteOn; input += Array("bee".utf8); input += pasteOff
        input += Array(" c".utf8); input += [0x0d]
        _ = t.observe(input)
        XCTAssertEqual(t.droppedInPaste, 1)
        XCTAssertEqual(t.droppedAsSecret, 0)
    }

    func testCleanLineDropsNothing() {
        // Negative case: an ordinary command drops zero tokens on either gate.
        var t = InputTokenTracker()
        _ = t.observe(Array("git status\r".utf8))
        XCTAssertEqual(t.droppedInPaste, 0)
        XCTAssertEqual(t.droppedAsSecret, 0)
    }

    func testResetClearsDropTallies() {
        var t = InputTokenTracker()
        _ = t.observe(Array("mysql -p hunter2\r".utf8))
        XCTAssertEqual(t.droppedAsSecret, 1)
        t.reset()
        XCTAssertEqual(t.droppedAsSecret, 0)
        XCTAssertEqual(t.droppedInPaste, 0)
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

    // MARK: - Full-line exposure (for line-shape context, Task 7)

    func testTrackerExposesFullLine() {
        var t = InputTokenTracker()
        _ = t.observe(bytes("git com"))
        XCTAssertEqual(t.line, "git com")
        XCTAssertEqual(t.cursorIndex, 7)
    }

    func testTrackerLineResetsOnEnter() {
        var t = InputTokenTracker()
        _ = t.observe(bytes("hello"))
        _ = t.observe([0x0d])
        XCTAssertEqual(t.line, "")
        XCTAssertEqual(t.cursorIndex, 0)
    }

    // MARK: - VT ground-state sanitizer (2026-08-22 design)

    func testDeviceAttributesResponseSwallowed() {
        // ESC[?65;4;1;2;6;21;22;17;28c then "whoami" → current is the typed word only.
        var t = InputTokenTracker()
        let da = Array("\u{1b}[?65;4;1;2;6;21;22;17;28c".utf8)
        _ = t.observe(da)
        XCTAssertEqual(t.current, "")            // the response contributed nothing
        _ = t.observe(bytes("whoami"))
        XCTAssertEqual(t.current, "whoami")
    }

    func testMouseEventSwallowed() {
        // ESC[<65;1;1M then "ls" → current == "ls".
        var t = InputTokenTracker()
        _ = t.observe(Array("\u{1b}[<65;1;1M".utf8))
        _ = t.observe(bytes("ls"))
        XCTAssertEqual(t.current, "ls")
    }

    func testSGRColorSwallowed() {
        // ESC[38;2;122;162;247m then "git" → current == "git".
        var t = InputTokenTracker()
        _ = t.observe(Array("\u{1b}[38;2;122;162;247m".utf8))
        _ = t.observe(bytes("git"))
        XCTAssertEqual(t.current, "git")
    }

    func testCursorReportSwallowedMidWord() {
        // "ab" + ESC[24;80R + "cd" → current == "abcd" (report vanishes, word intact).
        var t = InputTokenTracker()
        _ = t.observe(bytes("ab"))
        _ = t.observe(Array("\u{1b}[24;80R".utf8))
        _ = t.observe(bytes("cd"))
        XCTAssertEqual(t.current, "abcd")
    }

    func testArrowKeyResetsCurrent() {
        // "abc" + ESC[D (left arrow) → current == "" (line-context reset).
        var t = InputTokenTracker()
        _ = t.observe(bytes("abc"))
        _ = t.observe(Array("\u{1b}[D".utf8))
        XCTAssertEqual(t.current, "")
    }

    func testDeleteForwardResetsCurrent() {
        // "abc" + ESC[3~ (Delete) → current == "".
        var t = InputTokenTracker()
        _ = t.observe(bytes("abc"))
        _ = t.observe(Array("\u{1b}[3~".utf8))
        XCTAssertEqual(t.current, "")
    }

    func testCtrlWResetsCurrent() {
        var t = InputTokenTracker()
        _ = t.observe(bytes("abc"))
        _ = t.observe([0x17])
        XCTAssertEqual(t.current, "")
    }

    func testCtrlUResetsCurrent() {
        var t = InputTokenTracker()
        _ = t.observe(bytes("abc"))
        _ = t.observe([0x15])
        XCTAssertEqual(t.current, "")
    }

    func testCtrlKResetsCurrent() {
        var t = InputTokenTracker()
        _ = t.observe(bytes("abc"))
        _ = t.observe([0x0b])
        XCTAssertEqual(t.current, "")
    }

    func testBackspaceStillPopsNotReset() {
        // "abcd" + 0x7f → current == "abc" (pop, not a full reset).
        var t = InputTokenTracker()
        _ = t.observe(bytes("abcd"))
        _ = t.observe([0x7f])
        XCTAssertEqual(t.current, "abc")
    }

    func testBracketedPasteStillDropsContent() {
        // ESC[200~ + "secret" + ESC[201~ → paste content dropped, tally increments.
        var t = InputTokenTracker()
        var input: [UInt8] = pasteOn
        input += Array("secret".utf8)
        input += pasteOff
        _ = t.observe(input)
        XCTAssertEqual(t.current, "")
        XCTAssertEqual(t.droppedInPaste, 1)
    }

    func testSplitDeviceAttributesAcrossChunksSwallowed() {
        // ESC[?65c split across two observe() calls → still fully swallowed.
        var t = InputTokenTracker()
        _ = t.observe([0x1b, 0x5b, 0x3f, 0x36])
        _ = t.observe([0x35, 0x63, 0x68, 0x69])
        XCTAssertEqual(t.current, "hi")
    }

    func testNeverTerminatedSequenceIsBoundedAndResets() {
        // ESC[ + 100 param bytes, no final byte → guard aborts, back to ground, reset.
        var t = InputTokenTracker()
        _ = t.observe(bytes("abc"))
        var input: [UInt8] = [0x1b, 0x5b]
        input += Array(repeating: UInt8(ascii: "3"), count: 100)
        _ = t.observe(input)
        XCTAssertEqual(t.current, "")
        // Machine must be back in ground state: subsequent typing works normally.
        _ = t.observe(bytes("ok"))
        XCTAssertEqual(t.current, "ok")
    }

    /// Pins the 64-byte max-sequence guard itself (not just "no crash"). Feeds
    /// 70 param bytes (0x30-0x3f range, straddling the 64-byte bound) with no
    /// final byte, THEN a real CSI final byte (`~`), THEN normal typed text, in
    /// ONE `observe` call. This distinguishes guarded from unguarded:
    /// - WITH the guard: the guard fires at byte 64, entering `.abortedSequence`,
    ///   which keeps discarding 0x20-0x3f bytes (the remaining six `3`s) but is
    ///   no longer inside a real CSI parse. The subsequent `~` (0x7e, outside
    ///   0x20-0x3f) is therefore NOT consumed as a CSI final byte, it falls
    ///   through to `.ground` and is re-handled as ordinary printable text, so
    ///   `current` becomes `"~"` before `"ok"` is appended: `"~ok"`.
    /// - WITHOUT the guard: the machine stays in `.csi` for all 70 param bytes
    ///   (nothing ever aborts), so the FIRST byte in the CSI final-byte range
    ///   0x40-0x7e it sees is `~` itself, consumed as a legitimate CSI final
    ///   byte (dispatched via `csiKind`, swallowed as `.responseOrFormat`),
    ///   NOT as ground text. `current` would then be just `"ok"`, missing the
    ///   `"~"` the guard proves was released back into ground.
    /// Deleting `enforceSequenceGuard`'s 64-byte check flips this assertion
    /// from `"~ok"` to `"ok"`, so this test fails without the guard.
    func testGuardReleasesGroundParsingBeforeCSIWouldNaturallyTerminate() {
        var t = InputTokenTracker()
        var input: [UInt8] = [0x1b, 0x5b]                                  // ESC[
        input += Array(repeating: UInt8(ascii: "3"), count: 70)            // 70 param bytes, straddles 64
        input += Array("~ok".utf8)                                        // real final byte + normal text
        _ = t.observe(input)
        XCTAssertEqual(t.current, "~ok")
    }

    func testAdversarialSecretAfterSwallowedResponseStillDropped() {
        // ESC[c (swallowed response) then "--password hunter2" + Enter → hunter2
        // still gated by L4b (not learned), tally increments.
        var t = InputTokenTracker()
        var input: [UInt8] = Array("\u{1b}[c".utf8)
        input += Array("--password hunter2".utf8)
        input += [0x0d]
        let committed = t.observe(input)
        XCTAssertFalse(committed.map(\.token).contains("hunter2"))
        XCTAssertEqual(committed.map(\.token), ["--password"])
        XCTAssertEqual(t.droppedAsSecret, 1)
    }
}
