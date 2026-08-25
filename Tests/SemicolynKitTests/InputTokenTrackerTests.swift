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

    // MARK: tmux prefix command-key swallow

    // The tmux prefix (Ctrl-A, 0x01) flips the client into the prefix key-table;
    // the NEXT byte dispatches a binding (`prefix c` -> new-window) and is a tmux
    // COMMAND, not typed text. Device log (build 146) showed `Ctrl-A c whoami`
    // leaking the binding `c` into `current` as `cwhoami` (count=0). The byte after
    // the prefix must be swallowed, not extend `current`.

    func testPrefixCommandKeySwallowedNotTypedAsText() {
        var t = InputTokenTracker()
        // Ctrl-A (prefix) then 'c' (new-window binding) then the user types `whoami`.
        _ = t.observe([0x01])            // prefix: arms the one-shot command-key swallow
        _ = t.observe(bytes("c"))        // tmux binding key: swallowed, NOT text
        _ = t.observe(bytes("whoami"))
        XCTAssertEqual(t.current, "whoami")   // NOT "cwhoami"
    }

    func testPrefixCommandKeySwallowedInOneChunk() {
        var t = InputTokenTracker()
        // The whole gesture + typing can arrive in a single observe() chunk.
        _ = t.observe([0x01] + bytes("cwhoami"))
        XCTAssertEqual(t.current, "whoami")   // prefix 'c' swallowed, then real text
    }

    func testOnlyOneKeyAfterPrefixIsSwallowed() {
        var t = InputTokenTracker()
        // Exactly ONE key is consumed by the prefix table; the second key is normal.
        _ = t.observe([0x01])            // prefix
        _ = t.observe(bytes("xy"))       // 'x' = binding (swallowed), 'y' = typed text
        XCTAssertEqual(t.current, "y")
    }

    func testPrefixArmSurvivesChunkBoundary() {
        var t = InputTokenTracker()
        // The prefix and its binding key can land in SEPARATE observe() chunks; the
        // arm must persist across the boundary so the binding key is still swallowed.
        // (Without the fix the binding 'c' leaks: current would be "cwhoami".)
        _ = t.observe([0x01])            // chunk 1: prefix only
        _ = t.observe(bytes("cwhoami"))  // chunk 2: binding 'c' swallowed, "whoami" typed
        XCTAssertEqual(t.current, "whoami")
    }

    func testEscapeSequenceAfterPrefixIsNotSwallowedAsBindingKey() {
        var t = InputTokenTracker()
        // A terminal auto-response can race in AFTER the prefix, before the binding key.
        // The escape sequence must still be swallowed AS A SEQUENCE (not have its lead
        // ESC eaten by the prefix arm, which would leak the CSI body into `current`).
        // The arm then swallows the real binding key that follows.
        _ = t.observe([0x01])                       // prefix: arm
        // DA response ESC[?65;1c races in:
        _ = t.observe([0x1b, 0x5b, 0x3f, 0x36, 0x35, 0x3b, 0x31, 0x63])
        _ = t.observe(bytes("c"))                   // the real binding key: swallowed
        _ = t.observe(bytes("whoami"))
        XCTAssertEqual(t.current, "whoami")         // NOT "?65;1cwhoami" or "cwhoami"
    }

    func testEditingKeysOtherThanPrefixDoNotSwallowNextKey() {
        var t = InputTokenTracker()
        // Ctrl-C (0x03) is a plain line-edit reset, NOT the tmux prefix: the key after
        // it is ordinary typed text and must extend `current` (no one-shot swallow).
        _ = t.observe([0x03])            // Ctrl-C: reset only, no arm
        _ = t.observe(bytes("ls"))
        XCTAssertEqual(t.current, "ls")  // NOT "s" (the 'l' must NOT be swallowed)
    }

    func testPrefixArmDoesNotSurviveReset() {
        var t = InputTokenTracker()
        _ = t.observe([0x01])            // arm
        t.reset()                        // context/host switch clears everything
        _ = t.observe(bytes("cwhoami"))  // 'c' is now ordinary text again
        XCTAssertEqual(t.current, "cwhoami")
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

    // MARK: - OSC / DCS-string swallow paths (2026-08-23 review follow-up)

    func testOSCTerminatedByBELSwallowsClipboardPayload() {
        // OSC 52 (clipboard set): ESC ] 5 2 ; c ; Q Q = = BEL, then "ls".
        // The base64-ish payload ("52;c;QQ==") must not leak into `current`.
        var t = InputTokenTracker()
        var input: [UInt8] = [0x1b, 0x5d]                        // ESC ]
        input += Array("52;c;QQ==".utf8)
        input += [0x07]                                          // BEL terminator
        input += Array("ls".utf8)
        _ = t.observe(input)
        XCTAssertEqual(t.current, "ls")
    }

    func testOSCTerminatedBySTSwallowsTitlePayload() {
        // OSC 0 (set title): ESC ] 0 ; t i t l e ESC \, then "x".
        var t = InputTokenTracker()
        var input: [UInt8] = [0x1b, 0x5d]                        // ESC ]
        input += Array("0;title".utf8)
        input += [0x1b, 0x5c]                                    // ST = ESC \
        input += Array("x".utf8)
        _ = t.observe(input)
        XCTAssertEqual(t.current, "x")
    }

    func testOSCEmbeddedNonSTEscapeStaysSwallowed() {
        // ESC ] 0 ; a b <ESC> Z c d <BEL>, then "y". The ESC mid-body is
        // followed by 'Z' (not '\'), so it is NOT a real ST: `.oscEscape` must
        // fall back into `.osc` and keep swallowing ("Zcd" must not leak). If
        // `.oscEscape` wrongly treated the body ESC as a ground-level line
        // reset, 'Z' would be re-handled in `.ground` as printable text and
        // "cd" (plus the still-open OSC's later bytes) would leak into
        // `current` well before the eventual BEL/`y`.
        var t = InputTokenTracker()
        var input: [UInt8] = [0x1b, 0x5d]                        // ESC ]
        input += Array("0;ab".utf8)
        input += [0x1b]                                          // ESC (not a real ST: next byte isn't '\')
        input += Array("Zcd".utf8)
        input += [0x07]                                          // BEL terminator (finally ends the OSC)
        input += Array("y".utf8)
        _ = t.observe(input)
        XCTAssertEqual(t.current, "y")
    }

    func testDCSStringSequenceTerminatedBySTSwallowed() {
        // DCS: ESC P <payload> ESC \, then "y".
        var t = InputTokenTracker()
        var input: [UInt8] = [0x1b, 0x50]                        // ESC P
        input += Array("1$rpayload".utf8)
        input += [0x1b, 0x5c]                                    // ST = ESC \
        input += Array("y".utf8)
        _ = t.observe(input)
        XCTAssertEqual(t.current, "y")
    }

    func testDCSEmbeddedNonSTEscapeStaysSwallowed() {
        // Mirrors testOSCEmbeddedNonSTEscapeStaysSwallowed for `.stringSequenceEscape`:
        // ESC P a b <ESC> Z c d ESC \, then "y".
        var t = InputTokenTracker()
        var input: [UInt8] = [0x1b, 0x50]                        // ESC P
        input += Array("ab".utf8)
        input += [0x1b]                                          // ESC (not a real ST: next byte isn't '\')
        input += Array("Zcd".utf8)
        input += [0x1b, 0x5c]                                    // ST = ESC \ (finally ends the sequence)
        input += Array("y".utf8)
        _ = t.observe(input)
        XCTAssertEqual(t.current, "y")
    }

    func testOSCSplitAcrossChunksFullySwallowed() {
        // ESC ] 0 ; t i split into two observe() calls, then BEL, then "hi".
        var t = InputTokenTracker()
        _ = t.observe([0x1b, 0x5d] + Array("0;ti".utf8))
        _ = t.observe(Array("tle".utf8) + [0x07] + Array("hi".utf8))
        XCTAssertEqual(t.current, "hi")
    }
}
