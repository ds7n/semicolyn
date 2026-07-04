// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Decides, per input line, whether the predictor may LEARN that line — the
/// write-time gate that keeps typed **passwords** out of the learned vocabulary.
///
/// ## Why this is needed
///
/// The predictor observes the *outgoing* keystroke stream, so a password typed at
/// an in-session prompt (`sudo`, nested `ssh`, a TUI password field) would be
/// learned like any other token. The token filter (`TokenFilter`) cannot catch a
/// short low-entropy human password (`hunter2` — 7 chars, no matching pattern,
/// below the entropy floor), so a second, orthogonal defense is required.
///
/// ## Why it is heuristic
///
/// Over raw SSH the terminal runs in raw mode and **echo happens on the remote**:
/// a password prompt disables `ECHO` in the *remote* PTY's termios, which is never
/// signaled back over the wire (SwiftTerm exposes no echo/SRM flag; russh surfaces
/// no termios-change event). So the only observable signals are:
///
///  1. **Echo inference** — printable characters the user types are, in a normal
///     (echoing) shell, streamed back in the output within a few milliseconds. At
///     a non-echoing password prompt they are not (or a constant mask like `*` is
///     echoed instead). If a line's typed characters are **not positively observed
///     echoed back**, the line is treated as a password and not learned.
///  2. **Prompt text** — the output immediately before the line matches a known
///     password-prompt pattern (`password:`, `passphrase`, `[sudo] password for`).
///
/// The two are OR-combined: a line is suppressed if EITHER fires. Neither alone is
/// safe, and a missed password is an irreversible plaintext leak, so the gate is
/// **biased hard toward suppression** — `shouldLearnCommittedLine` returns `true`
/// only when echo was positively confirmed AND no password prompt preceded it.
/// The cost of a false positive is a harmless, silent learning miss (a legitimate
/// fast-typed command over high latency may not be learned); the cost of a false
/// negative is a leaked secret, so we fail toward the former.
///
/// ## Usage (orchestration)
///
/// The view model feeds both streams and consults the verdict at the `record`
/// boundary (the pure `InputTokenTracker` is unchanged):
/// ```
/// detector.noteOutput(bytes)                    // from the output/harvest tap
/// let committed = tracker.observe(inputBytes)   // existing
/// detector.noteInput(inputBytes)                // classify echo for this line
/// if detector.shouldLearnCommittedLine() {      // consult once per commit
///     for c in committed { engine.record(c.token, after: c.previous) }
/// }
/// ```
public struct PasswordEntryDetector: Sendable {
    /// Printable characters typed on the current (uncommitted) line.
    private var typedThisLine = 0
    /// Printable characters of the current line observed echoed back in output.
    private var echoedThisLine = 0
    /// Set when the output just before this line looked like a password prompt.
    private var promptSuppressedThisLine = false
    /// Rolling tail of recent output (lowercased), for prompt-pattern matching.
    /// Bounded so a large or hostile output stream can't grow this unboundedly.
    private var outputTail = ""
    /// Max characters of output tail retained for prompt matching.
    private let tailCap = 256

    /// The three-way per-keystroke echo verdict (spec L1).
    public enum EchoClass: Equatable, Sendable { case echoed, masked, hidden }

    /// The injected read-only grid view. Nil ⇒ fall back to byte-count inference.
    private var oracle: EchoOracle?
    /// Cursor cell recorded just before the pending keystroke was delivered.
    private var preCursor: EchoCursor?
    /// The scalar of the pending (delivered, not-yet-settled) keystroke.
    private var pendingScalar: Unicode.Scalar?
    /// Classification of the most recently settled keystroke (test-observable).
    public private(set) var lastClass: EchoClass?
    /// Count of positively-`echoed` printables on the current line (oracle path).
    private var oracleEchoedThisLine = 0
    /// Count of printables classified via the oracle on the current line.
    private var oracleClassifiedThisLine = 0
    /// Set once the oracle path has classified at least one keystroke this line,
    /// so `shouldLearnCommittedLine` knows to trust the buffer tally over bytes.
    private var oracleActiveThisLine = false
    /// True once any output byte arrived while the current line was being typed.
    /// Gates the oracle verdict: a "clean echo" reading during a total stall is
    /// ambiguous, so an oracle line with no output is suppressed.
    private var outputSeenThisLine = false

    /// Substrings (lowercased) that, appearing at the tail end of output, mark the
    /// following typed line as a password entry. Matched as a suffix (ignoring
    /// trailing whitespace) so mid-stream occurrences of the word don't misfire.
    private static let promptPatterns = [
        "password:",
        "password for",       // "[sudo] password for alice:" (the ':' may lag)
        "passphrase:",
        "passphrase for",
        "enter passphrase",
        "'s password:",       // "alice@host's password:"
        "verification code:", // 2FA / OTP — also secret-shaped
    ]

    public init() {}

    /// Fold a chunk of REMOTE output. Updates the prompt-tail and consumes echoes
    /// of characters typed on the current line (echo inference).
    public mutating func noteOutput(_ bytes: [UInt8]) {
        if !bytes.isEmpty { outputSeenThisLine = true }
        for b in bytes {
            // Count a printable output byte as an echo of a pending typed char,
            // up to the number typed. Masked prompts echo a constant char, which
            // still increments here — but a TRUE non-echoing prompt emits none of
            // the line's characters as fresh output, so the ratio test below
            // separates the two: an echoing line matches ~1:1, a masked/silent
            // line does not reach the confirmation threshold relative to length.
            if (0x21...0x7e).contains(b) || b == 0x20 {
                if echoedThisLine < typedThisLine { echoedThisLine += 1 }
            }
            appendTail(b)
        }
    }

    /// Fold the OUTGOING keystroke chunk for the current line. Counts printable
    /// characters typed; control bytes (Enter, Ctrl-*, ESC) are handled by
    /// `commitLine`/`resetLine`, which the caller drives off the same stream.
    public mutating func noteInput(_ bytes: [UInt8]) {
        for b in bytes {
            switch b {
            case 0x21...0x7e:            // printable → a character that SHOULD echo
                typedThisLine += 1
            case 0x7f, 0x08:            // backspace → un-type one (best effort)
                if typedThisLine > 0 { typedThisLine -= 1 }
                if echoedThisLine > typedThisLine { echoedThisLine = typedThisLine }
            case 0x0d, 0x0a:            // Enter → the line commits elsewhere
                break
            default:
                break
            }
        }
    }

    /// Inject (or clear with nil) the buffer oracle. Clearing reverts to the
    /// byte-count echo inference for subsequent keystrokes.
    public mutating func setOracle(_ oracle: EchoOracle?) {
        self.oracle = oracle
    }

    /// Call BEFORE delivering a printable keystroke: snapshot the cursor cell the
    /// echo would land in. A no-op if no oracle is set or the cursor is unreadable.
    public mutating func beginKeystroke(scalar: Unicode.Scalar) {
        guard let oracle else { preCursor = nil; pendingScalar = nil; return }
        preCursor = oracle.cursor()
        pendingScalar = scalar
    }

    /// Call AFTER the settle window: sample the echo cell + new cursor, classify
    /// the pending keystroke, and fold it into the line tally. Fail-safe: any
    /// unreadable signal classifies `hidden` (suppress).
    public mutating func settleKeystroke() {
        guard let oracle, let pre = preCursor, let scalar = pendingScalar else {
            pendingScalar = nil
            return
        }
        defer { preCursor = nil; pendingScalar = nil }
        let cls = Self.classify(oracle: oracle, pre: pre, scalar: scalar)
        lastClass = cls
        oracleActiveThisLine = true
        oracleClassifiedThisLine += 1
        if cls == .echoed { oracleEchoedThisLine += 1 }
    }

    /// Pure three-way classifier: echoed (scalar at the pre-cell + cursor
    /// advanced), masked (cursor advanced but cell holds a different glyph),
    /// hidden (no advance, or any signal unreadable). Static so it is trivially
    /// unit-testable and has no hidden state.
    private static func classify(
        oracle: EchoOracle, pre: EchoCursor, scalar: Unicode.Scalar
    ) -> EchoClass {
        guard let post = oracle.cursor() else { return .hidden }
        let advanced = post.col > pre.col || post.row > pre.row
        guard advanced else { return .hidden }
        guard let cell = oracle.cell(row: pre.row, col: pre.col),
              let shown = cell.scalar else { return .hidden }
        return shown == scalar ? .echoed : .masked
    }

    /// The verdict for the line that just committed (Enter). `true` only when the
    /// line's typed characters were positively confirmed echoed AND no password
    /// prompt preceded it. Fail-safe: an empty line, an unconfirmed line, or a
    /// prompt-preceded line all return `false` (do not learn).
    ///
    /// Call once, at the moment a line commits, BEFORE `resetLine`.
    public func shouldLearnCommittedLine() -> Bool {
        if promptSuppressedThisLine { return false }
        // Oracle path: when the buffer check classified this line, trust the
        // majority-echoed statistic (the far stronger signal per spec L1).
        if oracleActiveThisLine {
            if oracle?.isAlternateBuffer == true { return false }   // alt-screen ⇒ suppress
            guard outputSeenThisLine else { return false }          // stall ⇒ ambiguous ⇒ suppress
            guard oracleClassifiedThisLine > 0 else { return false }
            // Strong majority required (> 50%). A tie or worse suppresses —
            // exclusion wins ties.
            return oracleEchoedThisLine * 2 > oracleClassifiedThisLine
        }
        // Byte-count fallback (no oracle set): unchanged positive-echo-required.
        guard typedThisLine > 0 else { return false }
        return echoedThisLine + 1 >= typedThisLine
    }

    /// Reset per-line state after a commit (Enter) or a context break (ESC /
    /// control that clears the line). Re-evaluates whether the CURRENT output tail
    /// looks like a password prompt, so the next line inherits that suppression.
    public mutating func resetLine() {
        oracleEchoedThisLine = 0
        oracleClassifiedThisLine = 0
        oracleActiveThisLine = false
        outputSeenThisLine = false
        lastClass = nil
        preCursor = nil
        pendingScalar = nil
        typedThisLine = 0
        echoedThisLine = 0
        promptSuppressedThisLine = tailLooksLikePasswordPrompt()
    }

    /// Full reset (host/session switch): clears the tail too.
    public mutating func reset() {
        oracleEchoedThisLine = 0
        oracleClassifiedThisLine = 0
        oracleActiveThisLine = false
        outputSeenThisLine = false
        lastClass = nil
        preCursor = nil
        pendingScalar = nil
        typedThisLine = 0
        echoedThisLine = 0
        promptSuppressedThisLine = false
        outputTail = ""
    }

    // MARK: - Internals

    private mutating func appendTail(_ b: UInt8) {
        // Keep newlines out of the tail so a prompt on the current line stays a
        // clean suffix; collapse them to a boundary marker instead.
        let scalar: Character
        if b == 0x0d || b == 0x0a {
            scalar = "\n"
        } else if (0x20...0x7e).contains(b) {
            scalar = Character(UnicodeScalar(b))
        } else {
            return  // drop non-printable, non-newline control bytes
        }
        outputTail.append(Character(scalar.lowercased()))
        if outputTail.count > tailCap {
            outputTail.removeFirst(outputTail.count - tailCap)
        }
    }

    /// True if the output tail ends with a password-prompt pattern (ignoring
    /// trailing spaces and any content after the last newline).
    private func tailLooksLikePasswordPrompt() -> Bool {
        // Only the last output line matters for "what am I being prompted for".
        let lastLine = outputTail.split(separator: "\n", omittingEmptySubsequences: false)
            .last.map(String.init) ?? outputTail
        let trimmed = lastLine.trimmingTrailingSpaces()
        return Self.promptPatterns.contains { trimmed.hasSuffix($0) }
    }
}

private extension String {
    /// Drop trailing ASCII spaces (a prompt's cursor often sits after `Password: `).
    func trimmingTrailingSpaces() -> String {
        var s = self
        while s.last == " " { s.removeLast() }
        return s
    }
}
