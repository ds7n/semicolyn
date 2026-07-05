// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// A token committed (completed) on the input line, with the token before it —
/// the unit the predictor learns (`record(token, after: previous)`).
public struct CommittedToken: Equatable, Sendable {
    public let token: String
    public let previous: String?
    public init(token: String, previous: String?) { self.token = token; self.previous = previous }
}

/// Reconstructs the current partial token + the previous token from the raw bytes
/// the user sends to the remote. A terminal has no text field, so the predictor's
/// prefix is derived here by watching the outgoing stream. Pure and best-effort:
/// control sequences (arrows, Ctrl-*) reset the line context rather than tracking
/// cursor motion, and remote-side tab completion (whose result arrives as output)
/// is not reflected — both are acceptable v1 limitations.
public struct InputTokenTracker: Equatable, Sendable {
    /// The token currently being typed (since the last delimiter).
    public private(set) var current: String = ""
    /// The last committed (non-dropped) token on this line — the bigram predecessor
    /// recorded in `CommittedToken.previous` and surfaced for prefix-suggestion.
    public private(set) var previous: String?
    /// The most-recently-seen token (including dropped secrets) used only for the
    /// `isSecretValueToken` predicate. Advancing this past a dropped secret prevents
    /// the token AFTER the secret from being cascadingly dropped. NOT advanced on
    /// L3-paste drops (paste content is wholesale suppressed — reaching back over
    /// the preceding real token is the desired behaviour there).
    private var secretCheckPrev: String?
    /// True while inside a bracketed paste (`ESC[200~`…`ESC[201~`): tokens are
    /// tracked for prefix context but never emitted/learned (L3).
    public private(set) var withinPaste = false
    /// Bytes captured after a bare `ESC`, pending a bracketed-paste match. Empty
    /// when not mid-escape. Flushed back to normal handling on any deviation.
    private var escapeBuffer: [UInt8] = []
    /// True when the current line began with a space (`HISTCONTROL=ignorespace`
    /// gesture): the WHOLE line is suppressed from learning (L4a). Reset each line.
    public private(set) var lineOptedOut = false
    /// The opt-out verdict of the MOST-RECENTLY-COMMITTED line (latched at its
    /// Enter, before the per-line flags reset). The App reads this AFTER `observe`
    /// so a leading-space line + its Enter arriving in ONE chunk (paste) is still
    /// correctly suppressed — reading the live `lineOptedOut` before `observe`
    /// misses that case. Overwritten at each Enter; cleared by `reset()`.
    public private(set) var lastCommittedLineOptedOut = false
    /// Whether the first byte of the current line has been seen yet (to detect a
    /// leading space exactly at line start).
    private var sawLineStart = false

    private static let pasteEnter: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]  // ESC[200~
    private static let pasteExit: [UInt8]  = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]  // ESC[201~

    public init() {}

    /// Fold one chunk of outgoing bytes. Returns the tokens committed by this chunk
    /// (newest last), in order, for the caller to learn.
    public mutating func observe(_ bytes: [UInt8]) -> [CommittedToken] {
        var committed: [CommittedToken] = []
        for b in bytes { handleByte(b, into: &committed) }
        return committed
    }

    /// Route one byte. When mid-escape (after a bare ESC) we buffer until the byte
    /// stream either completes a paste marker (toggle `withinPaste`, consume it) or
    /// deviates (flush: the ESC becomes a line-context reset, the deviating byte is
    /// re-handled normally).
    private mutating func handleByte(_ b: UInt8, into committed: inout [CommittedToken]) {
        if !escapeBuffer.isEmpty {
            escapeBuffer.append(b)
            // Still a viable prefix of either marker? keep buffering.
            if Self.pasteEnter.starts(with: escapeBuffer) || Self.pasteExit.starts(with: escapeBuffer) {
                if escapeBuffer == Self.pasteEnter { withinPaste = true; escapeBuffer = [] }
                else if escapeBuffer == Self.pasteExit {
                    if withinPaste { current = "" }   // drop whatever accumulated inside the paste
                    withinPaste = false
                    escapeBuffer = []
                }
                return
            }
            // Deviation: this ESC sequence is not a paste marker. Treat the ESC as
            // a normal line-context reset, then re-handle the buffered tail bytes
            // (everything after the ESC) as ordinary input.
            let tail = Array(escapeBuffer.dropFirst())   // drop the ESC itself
            escapeBuffer = []
            resetLineContext()                            // ESC ⇒ reset (as today)
            for t in tail { handleByte(t, into: &committed) }
            return
        }
        if b == 0x1B {                                    // ESC → start capturing
            escapeBuffer = [b]
            return
        }
        classify(b, into: &committed)
    }

    /// The original per-byte tokenizer, minus the ESC case (ESC is handled above).
    private mutating func classify(_ b: UInt8, into committed: inout [CommittedToken]) {
        if !sawLineStart {
            sawLineStart = true
            if b == 0x20 { lineOptedOut = true }
        }
        switch b {
        case 0x21...0x7e:               // printable, non-space → extend the token
            current.unicodeScalars.append(UnicodeScalar(b))
        case 0x20:                      // space → commit (unless within paste)
            commitCurrent(into: &committed)
        case 0x0d, 0x0a:                // enter → commit, latch the line's opt-out
            commitCurrent(into: &committed)
            lastCommittedLineOptedOut = lineOptedOut   // latch BEFORE the reset below
            current = ""
            previous = nil
            secretCheckPrev = nil
            lineOptedOut = false
            sawLineStart = false
        case 0x7f, 0x08:                // backspace → pop one char
            if !current.isEmpty { current.removeLast() }
        case 0x09:                      // tab → remote completion: drop the partial
            current = ""
        default:                        // other control → reset line context
            resetLineContext()
        }
    }

    /// Commit `current` as a token — UNLESS we're inside a paste (L3) or the token
    /// is a denylisted secret value (L4b), in which case the token is dropped and
    /// does NOT advance `previous` (reach-back-over: the dropped token is invisible
    /// to the learned stream and bigram chain). L4b additionally advances
    /// `secretCheckPrev` to the dropped secret so the token AFTER it is not
    /// cascadingly dropped by the flag→value rule.
    private mutating func commitCurrent(into committed: inout [CommittedToken]) {
        guard !current.isEmpty else { return }
        // L3: inside a paste — drop; do NOT touch `previous` or `secretCheckPrev`.
        if withinPaste {
            current = ""
            return
        }
        // L4b: a denylisted secret value — drop, no `previous` advance (the next
        // real token reaches back over the secret to `previous` for bigrams). Clear
        // `secretCheckPrev` — a dropped secret is never a flag/header, so nil
        // prevents the cascade without retaining the secret string in memory.
        if isSecretValueToken(current, precededBy: secretCheckPrev) {
            secretCheckPrev = nil
            current = ""
            return
        }
        committed.append(CommittedToken(token: current, previous: previous))
        previous = current
        secretCheckPrev = current
        current = ""
    }

    /// ESC / unknown-control line reset (matches the pre-Phase-2 `default` case).
    private mutating func resetLineContext() {
        current = ""
        previous = nil
        secretCheckPrev = nil
        lineOptedOut = false
        sawLineStart = false
    }

    /// Clear all context (e.g. a context/host switch).
    public mutating func reset() {
        current = ""; previous = nil; secretCheckPrev = nil
        withinPaste = false
        escapeBuffer = []
        lineOptedOut = false
        lastCommittedLineOptedOut = false
        sawLineStart = false
    }
}

/// The chips to show for `current` given the engine's ranked `suggestions`: the
/// engine already prefix-matches, applies the confidence floor, and caps at top-K;
/// the strip only drops the exact token already typed (and any empties).
public func predictorChips(current: String, suggestions: [String]) -> [String] {
    suggestions.filter { $0 != current && !$0.isEmpty }
}
