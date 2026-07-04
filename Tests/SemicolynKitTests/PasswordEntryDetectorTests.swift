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

    /// Drive one printable keystroke through the oracle path (batch contract) and
    /// return the classification. Snapshots `startCursor`, then after settle sets
    /// `postCursor` and the cell callback.
    private func classifyOneBatch(
        typed: Unicode.Scalar,
        startCursor: EchoCursor,
        postCursor: EchoCursor?,
        echoCell: EchoCell?
    ) -> PasswordEntryDetector.EchoClass? {
        var d = PasswordEntryDetector()
        let oracle = ScriptedEchoOracle()
        oracle.nextCursor = startCursor
        d.setOracle(oracle)
        d.beginBatch()                    // snapshots startCursor
        oracle.nextCursor = postCursor    // cursor after echo
        oracle.cellAt = { r, c in
            (r == startCursor.row && c == startCursor.col) ? echoCell : EchoCell(scalar: nil)
        }
        d.settleLine(scalars: [typed])
        return d.lastClass
    }

    func testKeystrokeEchoedWhenScalarAtCellAndCursorAdvanced() {
        let cls = classifyOneBatch(
            typed: "k",
            startCursor: EchoCursor(row: 0, col: 0),
            postCursor: EchoCursor(row: 0, col: 1),
            echoCell: EchoCell(scalar: "k"))
        XCTAssertEqual(cls, .echoed)
    }

    func testKeystrokeMaskedWhenConstantMaskCharDespiteAdvance() {
        let cls = classifyOneBatch(
            typed: "s",
            startCursor: EchoCursor(row: 0, col: 0),
            postCursor: EchoCursor(row: 0, col: 1),
            echoCell: EchoCell(scalar: "*"))     // cursor advanced but wrong glyph
        XCTAssertEqual(cls, .masked)
    }

    func testKeystrokeHiddenWhenCursorDidNotAdvance() {
        let cls = classifyOneBatch(
            typed: "h",
            startCursor: EchoCursor(row: 0, col: 0),
            postCursor: EchoCursor(row: 0, col: 0),   // no advance
            echoCell: EchoCell(scalar: nil))
        XCTAssertEqual(cls, .hidden)
    }

    func testKeystrokeHiddenWhenOracleCursorUnreadable() {
        // Oracle drift: post-cursor nil → cannot confirm echo → hidden (suppress).
        let cls = classifyOneBatch(
            typed: "x",
            startCursor: EchoCursor(row: 0, col: 0),
            postCursor: nil,
            echoCell: EchoCell(scalar: "x"))
        XCTAssertEqual(cls, .hidden)
    }

    // MARK: - L1 line-level aggregation

    /// Drive a whole typed string as ONE batch through the oracle path. The entire
    /// typed string is one batch: `beginBatch` once at start, `settleLine` once at
    /// end. `cellFor(index, scalar)` returns the rendered cell for each keystroke's
    /// expected echo column. `finalCursor` is the post-echo cursor. `live` controls
    /// whether `noteOutput` is called (liveness gate). Returns the learn verdict.
    private func oracleVerdict(
        typed: String,
        alt: Bool,
        cellFor: @escaping (Int, Unicode.Scalar) -> EchoCell?,
        finalCursor: EchoCursor?,
        live: Bool = true
    ) -> Bool {
        var d = PasswordEntryDetector()
        let oracle = ScriptedEchoOracle()
        oracle.isAlternateBuffer = alt
        oracle.nextCursor = EchoCursor(row: 0, col: 0)   // batch start
        d.setOracle(oracle)
        d.beginBatch()
        let scalars = Array(typed.unicodeScalars)
        for ch in scalars {
            d.noteInput(Array(String(ch).utf8))
            if live { d.noteOutput(Array(String(ch).utf8)) }
        }
        oracle.cellAt = { r, c in
            guard r == 0, c >= 0, c < scalars.count else { return EchoCell(scalar: nil) }
            return cellFor(c, scalars[c])
        }
        oracle.nextCursor = finalCursor
        d.settleLine(scalars: scalars)
        return d.shouldLearnCommittedLine()
    }

    func testAllEchoedLineLearnsViaOracle() {
        let s = Array("kubectl".unicodeScalars)
        let learn = oracleVerdict(
            typed: "kubectl", alt: false,
            cellFor: { i, scalar in EchoCell(scalar: scalar) },
            finalCursor: EchoCursor(row: 0, col: s.count))
        XCTAssertTrue(learn)
    }

    func testAllHiddenLineSuppressedViaOracle() {
        // A hidden password: cursor never advances, cell stays blank → suppress.
        let learn = oracleVerdict(
            typed: "hunter2", alt: false,
            cellFor: { _, _ in EchoCell(scalar: nil) },
            finalCursor: EchoCursor(row: 0, col: 0))   // no advance
        XCTAssertFalse(learn)
    }

    func testMaskedLineSuppressedViaOracle() {
        // Every char masked with '*' (advance but wrong glyph) → suppress.
        let s = Array("s3cr3t!".unicodeScalars)
        let learn = oracleVerdict(
            typed: "s3cr3t!", alt: false,
            cellFor: { _, _ in EchoCell(scalar: "*") },
            finalCursor: EchoCursor(row: 0, col: s.count))
        XCTAssertFalse(learn)
    }

    func testAltScreenLineSuppressedEvenIfEchoed() {
        let s = Array("dd".unicodeScalars)
        let learn = oracleVerdict(
            typed: "dd", alt: true,
            cellFor: { i, scalar in EchoCell(scalar: scalar) },
            finalCursor: EchoCursor(row: 0, col: s.count))
        XCTAssertFalse(learn)   // alt-screen ⇒ suppress the whole line
    }

    func testMajorityEchoedLineLearns() {
        // 6 of 7 echoed, 1 hidden (a settle miss at index 3) → majority ⇒ learn.
        let s = Array("kubectl".unicodeScalars)
        let learn = oracleVerdict(
            typed: "kubectl", alt: false,
            cellFor: { i, scalar in
                i == 3 ? EchoCell(scalar: nil) : EchoCell(scalar: scalar)
            },
            finalCursor: EchoCursor(row: 0, col: s.count))
        XCTAssertTrue(learn)
    }

    func testMinorityEchoedLineSuppressed() {
        // Only 2 of 7 echoed → below majority ⇒ suppress (bias to not-learn).
        let s = Array("secret7".unicodeScalars)
        let learn = oracleVerdict(
            typed: "secret7", alt: false,
            cellFor: { i, scalar in
                i < 2 ? EchoCell(scalar: scalar) : EchoCell(scalar: nil)
            },
            finalCursor: EchoCursor(row: 0, col: s.count))
        XCTAssertFalse(learn)
    }

    func testExactTieSuppressed() {
        // Exactly 50% echoed (4 of 8): a tie must SUPPRESS — exclusion wins ties.
        // Guards the strict `>` in the majority test against a `>=` regression.
        // 4*2 = 8, and 8 > 8 is false → suppress; 8 >= 8 would be true → learn.
        let s = Array("passw0rd".unicodeScalars)
        let learn = oracleVerdict(
            typed: "passw0rd", alt: false,
            cellFor: { i, scalar in
                i < 4 ? EchoCell(scalar: scalar) : EchoCell(scalar: nil)
            },
            finalCursor: EchoCursor(row: 0, col: s.count))
        XCTAssertFalse(learn)
    }

    // MARK: - L1 output-liveness gate

    func testOracleLineWithNoOutputIsSuppressed() {
        // Cursor "advances" and cells "match" per the oracle, but NO output byte
        // ever arrived (a stall) → ambiguous → suppress.
        let s = Array("kubectl".unicodeScalars)
        let learn = oracleVerdict(
            typed: "kubectl", alt: false,
            cellFor: { i, scalar in EchoCell(scalar: scalar) },
            finalCursor: EchoCursor(row: 0, col: s.count),
            live: false)   // no noteOutput ⇒ not live ⇒ suppress
        XCTAssertFalse(learn)
    }

    func testOracleLineWithOutputStaysLearnable() {
        // Same as above but liveness satisfied → majority echoed ⇒ learn.
        let s = Array("kubectl".unicodeScalars)
        let learn = oracleVerdict(
            typed: "kubectl", alt: false,
            cellFor: { i, scalar in EchoCell(scalar: scalar) },
            finalCursor: EchoCursor(row: 0, col: s.count),
            live: true)
        XCTAssertTrue(learn)
    }

    // MARK: - L1 prompt-text corroboration

    func testPromptPrecededLineSuppressedEvenIfOracleSaysEchoed() {
        // Adversarial: a prompt that ECHOES the literal password (e.g. `read`
        // without -s after a "Password:" prompt). The oracle sees clean echo, but
        // the prompt tail forces non-echoed. Must NOT learn.
        var d = PasswordEntryDetector()
        d.noteOutput(Array("Password: ".utf8))
        d.resetLine()                                  // classify the prompt tail
        let oracle = ScriptedEchoOracle()
        d.setOracle(oracle)
        oracle.nextCursor = EchoCursor(row: 0, col: 0)
        d.beginBatch()
        let s = Array("hunter2".unicodeScalars)
        for ch in s {
            d.noteInput(Array(String(ch).utf8))
            d.noteOutput(Array(String(ch).utf8))       // literal echoed back
        }
        oracle.cellAt = { r, c in
            guard r == 0, c >= 0, c < s.count else { return EchoCell(scalar: nil) }
            return EchoCell(scalar: s[c])
        }
        oracle.nextCursor = EchoCursor(row: 0, col: s.count)
        d.settleLine(scalars: s)
        XCTAssertFalse(d.shouldLearnCommittedLine())   // prompt corroboration wins
    }

    // MARK: - L1 multi-keystroke batch regression guard

    func testMultiKeystrokeBatchClassifiesEveryKeystroke() {
        // A 5-char burst delivered as ONE batch where only the LAST char echoes and
        // the first four are blank (hidden). Under the OLD 1-settle-per-batch bug this
        // classified only the last char → 1-of-1 echoed → LEARN. With per-cell settle
        // it is 1-of-5 echoed → minority → SUPPRESS.
        var d = PasswordEntryDetector()
        let oracle = ScriptedEchoOracle()
        oracle.nextCursor = EchoCursor(row: 0, col: 0)
        d.setOracle(oracle)
        d.beginBatch()
        let scalars = Array("s3cr7".unicodeScalars)   // 5 chars
        for ch in scalars {
            d.noteInput(Array(String(ch).utf8))
            d.noteOutput(Array(String(ch).utf8))
        }
        oracle.cellAt = { r, c in
            (r == 0 && c == 4) ? EchoCell(scalar: scalars[4]) : EchoCell(scalar: nil)
        }
        oracle.nextCursor = EchoCursor(row: 0, col: 5)   // cursor advanced
        d.settleLine(scalars: scalars)
        XCTAssertFalse(d.shouldLearnCommittedLine())   // 1 echoed of 5 → minority → suppress
        XCTAssertEqual(d.lastClass, .echoed)           // the LAST keystroke was echoed…
        // …but the tally saw all 5, so the majority correctly suppresses.
    }
}
