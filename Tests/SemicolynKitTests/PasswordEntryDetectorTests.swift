// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Critical-tier: a false negative here is a leaked plaintext password, so the
/// suite is adversarial — every password vector is a negative that must FAIL to
/// learn, and the positive cases prove we didn't just suppress everything.
final class PasswordEntryDetectorTests: XCTestCase {
    /// Drive a full line through the detector: prime with `output`, type `input`
    /// (with its echo, if `echoed`), then commit. Returns the learn verdict.
    private func verdict(promptOutput: String, typed: String, echoed: Bool) -> Bool {
        var d = PasswordEntryDetector()
        d.noteOutput(Array(promptOutput.utf8))
        d.resetLine()                                  // classify the prompt tail
        for ch in typed {
            let b = Array(String(ch).utf8)
            d.noteInput(b)
            if echoed { d.noteOutput(b) }              // echoing shell streams it back
        }
        let learn = d.shouldLearnCommittedLine()
        d.noteInput([0x0d])                            // Enter
        return learn
    }

    // MARK: - Echo inference (the primary, prompt-independent signal)

    func testEchoedLineIsLearned() {
        // Normal shell: every typed char comes back in output → learn.
        XCTAssertTrue(verdict(promptOutput: "$ ", typed: "kubectl", echoed: true))
    }

    func testNonEchoedLineIsSuppressed() {
        // Password prompt (no prompt text, pure echo-off): chars typed, none
        // echoed → must NOT learn, even without a recognizable prompt string.
        XCTAssertFalse(verdict(promptOutput: "$ ", typed: "hunter2", echoed: false))
    }

    func testMaskedEchoStillSuppressesRealCharacters() {
        // Some prompts echo a constant mask ('*') rather than the typed char.
        // The typed chars themselves never appear, so the line is not confirmed.
        var d = PasswordEntryDetector()
        d.noteOutput(Array("Password: ".utf8))
        d.resetLine()
        for ch in "s3cret" {
            d.noteInput(Array(String(ch).utf8))
            d.noteOutput(Array("*".utf8))              // mask, not the real char
        }
        // Prompt text alone already suppresses; assert the verdict is false and
        // that it holds via the prompt path (masking is the belt, prompt the
        // suspenders — either is sufficient).
        XCTAssertFalse(d.shouldLearnCommittedLine())
    }

    // MARK: - Prompt-text suppressor (the orthogonal signal)

    func testSudoPromptSuppressesNextLine() {
        // The classic leak: `sudo` asks, user types the login password.
        XCTAssertFalse(verdict(promptOutput: "[sudo] password for alice: ",
                               typed: "hunter2", echoed: false))
    }

    func testSshPasswordPromptSuppresses() {
        XCTAssertFalse(verdict(promptOutput: "alice@build-01's password: ",
                               typed: "hunter2", echoed: false))
    }

    func testPassphrasePromptSuppresses() {
        XCTAssertFalse(verdict(promptOutput: "Enter passphrase for key '/home/a/.ssh/id_ed25519': ",
                               typed: "hunter2", echoed: false))
    }

    func testVerificationCodePromptSuppresses() {
        // 2FA/OTP is also secret-shaped.
        XCTAssertFalse(verdict(promptOutput: "Verification code: ",
                               typed: "123456", echoed: false))
    }

    func testPromptSuppressesEvenIfSomehowEchoed() {
        // Adversarial: even if a password prompt DID echo (e.g. a broken TUI),
        // the prompt-text suppressor must still fire — OR semantics.
        XCTAssertFalse(verdict(promptOutput: "Password: ", typed: "hunter2", echoed: true))
    }

    func testPromptMatchIsCaseInsensitive() {
        XCTAssertFalse(verdict(promptOutput: "PASSWORD: ", typed: "hunter2", echoed: false))
    }

    func testPromptMatchToleratesTrailingSpaces() {
        XCTAssertFalse(verdict(promptOutput: "Password:     ", typed: "hunter2", echoed: false))
    }

    // MARK: - Negatives: normal commands after non-prompt output MUST be learned

    func testWordPasswordMidOutputDoesNotSuppress() {
        // "password" appearing in normal output (not as a trailing prompt) must
        // NOT suppress the next command — the match is a suffix of the last line.
        XCTAssertTrue(verdict(promptOutput: "changing password policy\n$ ",
                              typed: "kubectl", echoed: true))
    }

    func testCommandAfterCleanPromptIsLearned() {
        XCTAssertTrue(verdict(promptOutput: "alice@host:~$ ", typed: "ls", echoed: true))
    }

    // MARK: - Boundary / fail-safe

    func testEmptyLineIsNotLearned() {
        // Nothing typed → nothing to learn (and never a spurious true).
        var d = PasswordEntryDetector()
        d.noteOutput(Array("$ ".utf8))
        d.resetLine()
        XCTAssertFalse(d.shouldLearnCommittedLine())
    }

    func testUnconfirmedLineFailsSafeToSuppress() {
        // Chars typed but output/echo lost (dropped, latency) → default suppress.
        var d = PasswordEntryDetector()
        d.noteOutput(Array("$ ".utf8))
        d.resetLine()
        d.noteInput(Array("secret".utf8))              // typed, NO noteOutput echo
        XCTAssertFalse(d.shouldLearnCommittedLine())
    }

    func testOneCharSlackToleratesTrailingByteInFlight() {
        // A single not-yet-echoed trailing char must not flip an otherwise-echoed
        // line to suppressed (the +1 slack). Type 4, echo only 3.
        var d = PasswordEntryDetector()
        d.noteOutput(Array("$ ".utf8))
        d.resetLine()
        for (i, ch) in "grep".enumerated() {
            d.noteInput(Array(String(ch).utf8))
            if i < 3 { d.noteOutput(Array(String(ch).utf8)) }   // echo 3 of 4
        }
        XCTAssertTrue(d.shouldLearnCommittedLine(), "3-of-4 echoed is within slack")
    }

    func testTwoCharsMissingExceedsSlackAndSuppresses() {
        // BVA: 2 missing echoes (echo 2 of 4) exceeds the 1-char slack → suppress.
        var d = PasswordEntryDetector()
        d.noteOutput(Array("$ ".utf8))
        d.resetLine()
        for (i, ch) in "grep".enumerated() {
            d.noteInput(Array(String(ch).utf8))
            if i < 2 { d.noteOutput(Array(String(ch).utf8)) }   // echo 2 of 4
        }
        XCTAssertFalse(d.shouldLearnCommittedLine())
    }

    func testResetClearsPromptContext() {
        // A full reset (host switch) must clear a pending prompt suppression.
        var d = PasswordEntryDetector()
        d.noteOutput(Array("Password: ".utf8))
        d.resetLine()
        XCTAssertFalse(d.shouldLearnCommittedLine())   // suppressed by prompt
        d.reset()
        d.noteOutput(Array("$ ".utf8))
        d.resetLine()
        for ch in "ls" { d.noteInput(Array(String(ch).utf8)); d.noteOutput(Array(String(ch).utf8)) }
        XCTAssertTrue(d.shouldLearnCommittedLine(), "post-reset echoed line learns again")
    }

    func testBackspaceReducesTypedCount() {
        // Type 5, backspace 2, echo the net 3 → confirmed, learned.
        var d = PasswordEntryDetector()
        d.noteOutput(Array("$ ".utf8))
        d.resetLine()
        d.noteInput(Array("abcde".utf8))
        d.noteInput([0x7f, 0x7f])                        // two backspaces → net 3 typed
        d.noteOutput(Array("abc".utf8))                  // echo the 3 survivors
        XCTAssertTrue(d.shouldLearnCommittedLine())
    }

    // MARK: - L1 buffer-anchored echo (oracle-driven)

    /// Drive one printable keystroke through the oracle path and return the
    /// classification implied by the resulting tally. Cursor pre = (0,0);
    /// after settle the oracle reports cursor advanced to (0,1) and the cell the
    /// test scripts. Uses the *internal* tallies to assert the class precisely.
    private func classifyOne(
        typed: Unicode.Scalar,
        preCursor: EchoCursor,
        postCursor: EchoCursor?,
        echoCell: EchoCell?,
        alt: Bool = false
    ) -> PasswordEntryDetector.EchoClass? {
        var d = PasswordEntryDetector()
        let oracle = ScriptedEchoOracle()
        oracle.isAlternateBuffer = alt
        oracle.nextCursor = preCursor
        d.setOracle(oracle)
        d.beginKeystroke(scalar: typed)          // snapshots preCursor
        oracle.nextCursor = postCursor
        oracle.cellAt = { r, c in
            (r == preCursor.row && c == preCursor.col) ? echoCell : EchoCell(scalar: nil)
        }
        d.settleKeystroke()                      // samples + classifies
        return d.lastClass
    }

    func testKeystrokeEchoedWhenScalarAtCellAndCursorAdvanced() {
        let cls = classifyOne(
            typed: "k",
            preCursor: EchoCursor(row: 0, col: 0),
            postCursor: EchoCursor(row: 0, col: 1),
            echoCell: EchoCell(scalar: "k"))
        XCTAssertEqual(cls, .echoed)
    }

    func testKeystrokeMaskedWhenConstantMaskCharDespiteAdvance() {
        let cls = classifyOne(
            typed: "s",
            preCursor: EchoCursor(row: 0, col: 0),
            postCursor: EchoCursor(row: 0, col: 1),
            echoCell: EchoCell(scalar: "*"))     // cursor advanced but wrong glyph
        XCTAssertEqual(cls, .masked)
    }

    func testKeystrokeHiddenWhenCursorDidNotAdvance() {
        let cls = classifyOne(
            typed: "h",
            preCursor: EchoCursor(row: 0, col: 0),
            postCursor: EchoCursor(row: 0, col: 0),   // no advance
            echoCell: EchoCell(scalar: nil))
        XCTAssertEqual(cls, .hidden)
    }

    func testKeystrokeHiddenWhenOracleCursorUnreadable() {
        // Oracle drift: post-cursor nil → cannot confirm echo → hidden (suppress).
        let cls = classifyOne(
            typed: "x",
            preCursor: EchoCursor(row: 0, col: 0),
            postCursor: nil,
            echoCell: EchoCell(scalar: "x"))
        XCTAssertEqual(cls, .hidden)
    }

    // MARK: - L1 line-level aggregation

    /// Drive a whole typed line through the oracle path. `perChar` gives, per
    /// typed scalar, the (postCursor, echoCell) the oracle should report at settle;
    /// pre-cursor advances one column per accepted char. Returns the learn verdict.
    private func oracleVerdict(
        typed: String,
        alt: Bool,
        perChar: (Int) -> (EchoCursor?, EchoCell?)
    ) -> Bool {
        var d = PasswordEntryDetector()
        let oracle = ScriptedEchoOracle()
        oracle.isAlternateBuffer = alt
        d.setOracle(oracle)
        var col = 0
        for (i, ch) in typed.unicodeScalars.enumerated() {
            let pre = EchoCursor(row: 0, col: col)
            oracle.nextCursor = pre
            d.beginKeystroke(scalar: ch)
            d.noteInput(Array(String(ch).utf8))
            d.noteOutput(Array(String(ch).utf8))
            let (post, cell) = perChar(i)
            oracle.nextCursor = post
            oracle.cellAt = { r, c in (r == 0 && c == pre.col) ? cell : EchoCell(scalar: nil) }
            d.settleKeystroke()
            col += 1
        }
        let learn = d.shouldLearnCommittedLine()
        d.noteInput([0x0d])
        return learn
    }

    func testAllEchoedLineLearnsViaOracle() {
        let s = Array("kubectl".unicodeScalars)
        let learn = oracleVerdict(typed: "kubectl", alt: false) { i in
            (EchoCursor(row: 0, col: i + 1), EchoCell(scalar: s[i]))
        }
        XCTAssertTrue(learn)
    }

    func testAllHiddenLineSuppressedViaOracle() {
        // A hidden password: cursor never advances, cell stays blank → suppress.
        let learn = oracleVerdict(typed: "hunter2", alt: false) { _ in
            (EchoCursor(row: 0, col: 0), EchoCell(scalar: nil))
        }
        XCTAssertFalse(learn)
    }

    func testMaskedLineSuppressedViaOracle() {
        // Every char masked with '*' (advance but wrong glyph) → suppress.
        let learn = oracleVerdict(typed: "s3cr3t!", alt: false) { i in
            (EchoCursor(row: 0, col: i + 1), EchoCell(scalar: "*"))
        }
        XCTAssertFalse(learn)
    }

    func testAltScreenLineSuppressedEvenIfEchoed() {
        let s = Array("dd".unicodeScalars)
        let learn = oracleVerdict(typed: "dd", alt: true) { i in
            (EchoCursor(row: 0, col: i + 1), EchoCell(scalar: s[i]))
        }
        XCTAssertFalse(learn)   // alt-screen ⇒ suppress the whole line
    }

    func testMajorityEchoedLineLearns() {
        // 6 of 7 echoed, 1 hidden (a settle miss) → majority ⇒ learn.
        let s = Array("kubectl".unicodeScalars)
        let learn = oracleVerdict(typed: "kubectl", alt: false) { i in
            i == 3
                ? (EchoCursor(row: 0, col: 3), EchoCell(scalar: nil))   // one miss, no advance
                : (EchoCursor(row: 0, col: i + 1), EchoCell(scalar: s[i]))
        }
        XCTAssertTrue(learn)
    }

    func testMinorityEchoedLineSuppressed() {
        // Only 2 of 7 echoed → below majority ⇒ suppress (bias to not-learn).
        let s = Array("secret7".unicodeScalars)
        let learn = oracleVerdict(typed: "secret7", alt: false) { i in
            i < 2
                ? (EchoCursor(row: 0, col: i + 1), EchoCell(scalar: s[i]))
                : (EchoCursor(row: 0, col: i), EchoCell(scalar: nil))
        }
        XCTAssertFalse(learn)
    }

    func testExactTieSuppressed() {
        // Exactly 50% echoed (4 of 8): a tie must SUPPRESS — exclusion wins ties.
        // Guards the strict `>` in the majority test against a `>=` regression.
        // 4*2 = 8, and 8 > 8 is false → suppress; 8 >= 8 would be true → learn.
        let s = Array("passw0rd".unicodeScalars)
        let learn = oracleVerdict(typed: "passw0rd", alt: false) { i in
            i < 4
                ? (EchoCursor(row: 0, col: i + 1), EchoCell(scalar: s[i]))   // echoed
                : (EchoCursor(row: 0, col: i), EchoCell(scalar: nil))        // hidden (no advance)
        }
        XCTAssertFalse(learn)
    }

    // MARK: - L1 output-liveness gate

    func testOracleLineWithNoOutputIsSuppressed() {
        // Cursor "advances" and cells "match" per the oracle, but NO output byte
        // ever arrived (a stall) → ambiguous → suppress. This drives the oracle
        // path directly WITHOUT calling noteOutput.
        var d = PasswordEntryDetector()
        let oracle = ScriptedEchoOracle()
        d.setOracle(oracle)
        let s = Array("kubectl".unicodeScalars)
        var col = 0
        for (i, ch) in "kubectl".unicodeScalars.enumerated() {
            let pre = EchoCursor(row: 0, col: col)
            oracle.nextCursor = pre
            d.beginKeystroke(scalar: ch)
            d.noteInput(Array(String(ch).utf8))
            oracle.nextCursor = EchoCursor(row: 0, col: col + 1)
            oracle.cellAt = { r, c in (r == 0 && c == pre.col) ? EchoCell(scalar: s[i]) : EchoCell(scalar: nil) }
            d.settleKeystroke()
            col += 1
        }
        XCTAssertFalse(d.shouldLearnCommittedLine())   // no noteOutput ⇒ not live ⇒ suppress
    }

    func testOracleLineWithOutputStaysLearnable() {
        // Same as above but a single output byte arrives → liveness satisfied,
        // majority echoed ⇒ learn. Proves the gate doesn't suppress real echoes.
        var d = PasswordEntryDetector()
        let oracle = ScriptedEchoOracle()
        d.setOracle(oracle)
        let s = Array("kubectl".unicodeScalars)
        var col = 0
        for (i, ch) in "kubectl".unicodeScalars.enumerated() {
            let pre = EchoCursor(row: 0, col: col)
            oracle.nextCursor = pre
            d.beginKeystroke(scalar: ch)
            d.noteInput(Array(String(ch).utf8))
            d.noteOutput(Array(String(ch).utf8))       // echoing shell emits output
            oracle.nextCursor = EchoCursor(row: 0, col: col + 1)
            oracle.cellAt = { r, c in (r == 0 && c == pre.col) ? EchoCell(scalar: s[i]) : EchoCell(scalar: nil) }
            d.settleKeystroke()
            col += 1
        }
        XCTAssertTrue(d.shouldLearnCommittedLine())
    }
}
