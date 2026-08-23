// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// A token committed (completed) on the input line, with the token before it,
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
/// is not reflected, both are acceptable v1 limitations.
public struct InputTokenTracker: Equatable, Sendable {
    /// The token currently being typed (since the last delimiter).
    public private(set) var current: String = ""
    /// The full input line since the last line reset (for line-shape context).
    /// Intentionally RETAINS paste-suppressed (L3) and tab-dropped text, unlike
    /// `current`, which drops it: line-SHAPE detection wants what the user
    /// physically typed. `line` is a transient shape signal only, it is never
    /// learned or logged verbatim.
    public private(set) var line: String = ""
    /// Cursor position within `line` (cursor is assumed at the end today).
    public var cursorIndex: Int { line.count }
    /// The last committed (non-dropped) token on this line, the bigram predecessor
    /// recorded in `CommittedToken.previous` and surfaced for prefix-suggestion.
    public private(set) var previous: String?
    /// The most-recently-seen token (including dropped secrets) used only for the
    /// `isSecretValueToken` predicate. Advancing this past a dropped secret prevents
    /// the token AFTER the secret from being cascadingly dropped. NOT advanced on
    /// L3-paste drops (paste content is wholesale suppressed, reaching back over
    /// the preceding real token is the desired behaviour there).
    private var secretCheckPrev: String?
    /// True while inside a bracketed paste (`ESC[200~`…`ESC[201~`): tokens are
    /// tracked for prefix context but never emitted/learned (L3).
    public private(set) var withinPaste = false
    /// VT ground-state parser state, persists across `observe(_:)` calls so a
    /// sequence split across chunks (e.g. a DA response arriving in two reads)
    /// resumes correctly. See `docs/superpowers/specs/2026-08-22-predictor-input-sanitizer-design.md`.
    private enum ParseState: Equatable {
        case ground
        /// After a bare ESC (0x1b), awaiting the byte that selects the sequence kind.
        case escape
        /// Inside a CSI sequence (`ESC[` or C1 0x9b): accumulating params/intermediates
        /// until a final byte (0x40-0x7e). `hadPrivateMarker` tracks whether a private
        /// marker (0x3c-0x3f) appeared in the param region; `paramBytes` accumulates the
        /// raw param bytes (for parsing `param0`).
        case csi(hadPrivateMarker: Bool, paramBytes: [UInt8])
        /// Inside an OSC sequence (`ESC]` or C1 0x9d): consume until BEL or ST.
        case osc
        /// Inside `.osc`, just saw an ESC: if the next byte is `\` this completes
        /// the ST terminator (discard, back to ground); any other byte is still
        /// part of the swallowed OSC body (stay swallowing, do NOT reset/re-handle
        /// like a ground-level bare ESC would).
        case oscEscape
        /// Inside a DCS/SOS/PM/APC string sequence (`ESC P/X/^/_`): consume until ST.
        case stringSequence
        /// Inside `.stringSequence`, just saw an ESC: mirrors `.oscEscape`.
        case stringSequenceEscape
        /// A sequence exceeded the max-length guard with no final/terminator byte
        /// seen. Keep discarding CSI-shaped bytes (0x20-0x3f, the param/intermediate
        /// range) so trailing garbage from the SAME malformed sequence never leaks
        /// into `current`; any other byte (a plausible final byte, a fresh ESC, or
        /// ordinary ground text) returns to `.ground` and is re-handled there.
        case abortedSequence
    }
    /// Current VT parser state. Also tracks the total byte length of the sequence
    /// in progress (for the 64-byte max-sequence guard); reset to 0 on every
    /// transition back to `.ground`.
    private var parseState: ParseState = .ground
    private var sequenceLength: Int = 0
    /// Maximum bytes an escape/CSI/OSC/string sequence may run without a final
    /// byte before we give up and treat it as malformed (never hang swallowing).
    private static let maxSequenceLength = 64
    /// True when the current line began with a space (`HISTCONTROL=ignorespace`
    /// gesture): the WHOLE line is suppressed from learning (L4a). Reset each line.
    public private(set) var lineOptedOut = false
    /// The opt-out verdict of the MOST-RECENTLY-COMMITTED line (latched at its
    /// Enter, before the per-line flags reset). The App reads this AFTER `observe`
    /// so a leading-space line + its Enter arriving in ONE chunk (paste) is still
    /// correctly suppressed, reading the live `lineOptedOut` before `observe`
    /// misses that case. Overwritten at each Enter; cleared by `reset()`.
    public private(set) var lastCommittedLineOptedOut = false
    /// Whether the first byte of the current line has been seen yet (to detect a
    /// leading space exactly at line start).
    private var sawLineStart = false

    /// Monotonic tally of tokens DROPPED by the L3 paste gate. PRIVACY-SAFE: a count
    /// only, never the dropped text. The App reads the delta after `observe` and logs
    /// `predictor:drop-gate paste=N secret=M` so a device trace proves the
    /// secret-exclusion gates are actually firing (previously invisible: audit
    /// 2026-07-19). Never reset except by `reset()` so deltas across chunks are stable.
    public private(set) var droppedInPaste = 0
    /// Monotonic tally of tokens DROPPED by the L4b secret-value gate. Privacy-safe
    /// count only (see `droppedInPaste`).
    public private(set) var droppedAsSecret = 0

    public init() {}

    /// Fold one chunk of outgoing bytes. Returns the tokens committed by this chunk
    /// (newest last), in order, for the caller to learn.
    public mutating func observe(_ bytes: [UInt8]) -> [CommittedToken] {
        var committed: [CommittedToken] = []
        for b in bytes { handleByte(b, into: &committed) }
        return committed
    }

    /// C0 control bytes that represent a user editing gesture we cannot faithfully
    /// replay (no cursor model): treated as a line-context reset in `.ground`.
    private static let editingC0: Set<UInt8> = [0x17, 0x15, 0x0b, 0x01, 0x03, 0x05]  // Ctrl-W/U/K/A/C/E

    /// Route one byte through the VT ground-state machine. Only `.ground`-state
    /// printable bytes ever reach `classify`/extend `current`; every other state
    /// swallows bytes until its terminator, then dispatches (discard, or for CSI,
    /// classify via `csiKind` to decide swallow-vs-reset).
    private mutating func handleByte(_ b: UInt8, into committed: inout [CommittedToken]) {
        switch parseState {
        case .ground:
            handleGroundByte(b, into: &committed)
        case .escape:
            handleEscapeByte(b, into: &committed)
        case .csi(let hadPrivateMarker, let paramBytes):
            handleCSIByte(b, hadPrivateMarker: hadPrivateMarker, paramBytes: paramBytes, into: &committed)
        case .osc:
            handleOSCByte(b, into: &committed)
        case .oscEscape:
            handleOSCEscapeByte(b, into: &committed)
        case .stringSequence:
            handleStringSequenceByte(b, into: &committed)
        case .stringSequenceEscape:
            handleStringSequenceEscapeByte(b, into: &committed)
        case .abortedSequence:
            handleAbortedSequenceByte(b, into: &committed)
        }
    }

    /// `.ground`: printable bytes extend `current`/`line`; C0 controls dispatch as
    /// today (enter/backspace/tab/editing-reset); ESC/C1-CSI/C1-OSC transition out.
    private mutating func handleGroundByte(_ b: UInt8, into committed: inout [CommittedToken]) {
        if b == 0x1b { enterState(.escape); return }
        if b == 0x9b { enterState(.csi(hadPrivateMarker: false, paramBytes: [])); return }
        if b == 0x9d { enterState(.osc); return }

        if !sawLineStart {
            sawLineStart = true
            if b == 0x20 { lineOptedOut = true }
        }
        switch b {
        case 0x21...0x7e:               // printable, non-space → extend the token
            current.unicodeScalars.append(UnicodeScalar(b))
            line.unicodeScalars.append(UnicodeScalar(b))
        case 0x20:                      // space → commit (unless within paste)
            commitCurrent(into: &committed)
            line.unicodeScalars.append(UnicodeScalar(b))
        case 0x0d, 0x0a:                // enter → commit, latch the line's opt-out
            commitCurrent(into: &committed)
            lastCommittedLineOptedOut = lineOptedOut   // latch BEFORE the reset below
            current = ""
            line = ""
            previous = nil
            secretCheckPrev = nil
            lineOptedOut = false
            sawLineStart = false
        case 0x7f, 0x08:                // backspace → pop one char
            if !current.isEmpty { current.removeLast() }
            if !line.isEmpty { line.removeLast() }
        case 0x09:                      // tab → remote completion: drop the partial
            current = ""
        case let c where Self.editingC0.contains(c):   // Ctrl-W/U/K/A/C/E → reset
            resetLineContext()
        default:                        // other control → reset line context
            resetLineContext()
        }
    }

    /// `.escape`: the byte right after a bare ESC selects the sequence kind.
    private mutating func handleEscapeByte(_ b: UInt8, into committed: inout [CommittedToken]) {
        switch b {
        case UInt8(ascii: "["):
            enterState(.csi(hadPrivateMarker: false, paramBytes: []))
        case UInt8(ascii: "]"):
            enterState(.osc)
        case UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"):
            enterState(.stringSequence)
        case 0x30...0x7e:
            // Two-byte ESC-final sequence (e.g. ESC c, ESC =, ESC >): discard, back to ground.
            backToGround()
        default:
            // A bare ESC followed by a deviating byte (not a recognized sequence
            // starter): the ESC itself is a line reset (preserve existing "ESC ⇒
            // reset" behavior); the deviating byte is re-handled in ground.
            backToGround()
            resetLineContext()
            handleByte(b, into: &committed)
        }
    }

    /// `.csi`: accumulate params (0x30-0x3f) + intermediates (0x20-0x2f); a final
    /// byte (0x40-0x7e) ends the sequence and dispatches via `csiKind`.
    private mutating func handleCSIByte(
        _ b: UInt8, hadPrivateMarker: Bool, paramBytes: [UInt8], into committed: inout [CommittedToken]
    ) {
        if enforceSequenceGuard(into: &committed) { return }
        switch b {
        case 0x30...0x3f:
            // Private markers live in this range too (0x3c-0x3f: '<','=','>','?').
            let isPrivateMarker = (0x3c...0x3f).contains(b)
            parseState = .csi(hadPrivateMarker: hadPrivateMarker || isPrivateMarker, paramBytes: paramBytes + [b])
            sequenceLength += 1
        case 0x20...0x2f:
            // Intermediate bytes: accumulate but do not affect the private-marker flag.
            parseState = .csi(hadPrivateMarker: hadPrivateMarker, paramBytes: paramBytes + [b])
            sequenceLength += 1
        case 0x40...0x7e:
            dispatchCSI(finalByte: b, hadPrivateMarker: hadPrivateMarker, paramBytes: paramBytes, into: &committed)
        default:
            // Unexpected byte inside a CSI sequence: abort defensively.
            backToGround()
            resetLineContext()
        }
    }

    /// Parse `param0` (the integer before the first `;`, if any) from the
    /// accumulated CSI param bytes, then classify and dispatch.
    private mutating func dispatchCSI(
        finalByte: UInt8, hadPrivateMarker: Bool, paramBytes: [UInt8], into committed: inout [CommittedToken]
    ) {
        backToGround()
        let param0 = Self.parseParam0(paramBytes)
        switch csiKind(finalByte: finalByte, hadPrivateMarker: hadPrivateMarker, param0: param0) {
        case .editing:
            resetLineContext()
        case .responseOrFormat:
            break   // swallow, `current` untouched
        case .pasteEnter:
            withinPaste = true
        case .pasteExit:
            if withinPaste {
                if !current.isEmpty { droppedInPaste += 1 }
                current = ""
            }
            withinPaste = false
        }
    }

    /// Extract the first `;`-delimited integer parameter from raw CSI param
    /// bytes (which may include a leading private marker like `?` or `<`,
    /// skipped: it is not part of the numeric param).
    private static func parseParam0(_ paramBytes: [UInt8]) -> Int? {
        var digits: [UInt8] = []
        for b in paramBytes {
            if b == UInt8(ascii: ";") { break }
            if (0x30...0x39).contains(b) { digits.append(b) }
            // Non-digit, non-semicolon bytes before any digit (e.g. a leading '?'
            // private marker) are skipped; a non-digit AFTER digits have started
            // would be malformed input, treated the same as "stop collecting".
            else if !digits.isEmpty { break }
        }
        guard !digits.isEmpty, let s = String(bytes: digits, encoding: .ascii) else { return nil }
        return Int(s)
    }

    /// `.osc`: consume until BEL (0x07) or ST (`ESC \`) → discard.
    private mutating func handleOSCByte(_ b: UInt8, into committed: inout [CommittedToken]) {
        if enforceSequenceGuard(into: &committed) { return }
        if b == 0x07 || b == 0x9c { backToGround(); return }
        if b == 0x1b { enterState(.oscEscape); return }
        sequenceLength += 1
    }

    /// `.oscEscape`: saw ESC while inside an OSC body. `\` completes the ST
    /// terminator; anything else is still swallowed OSC content (stay in `.osc`,
    /// do NOT treat it as a ground-level line reset).
    private mutating func handleOSCEscapeByte(_ b: UInt8, into committed: inout [CommittedToken]) {
        if enforceSequenceGuard(into: &committed) { return }
        if b == UInt8(ascii: "\\") { backToGround(); return }
        parseState = .osc
        sequenceLength += 1
    }

    /// `.stringSequence` (DCS/SOS/PM/APC): consume until ST (`ESC \` / 0x9c) → discard.
    private mutating func handleStringSequenceByte(_ b: UInt8, into committed: inout [CommittedToken]) {
        if enforceSequenceGuard(into: &committed) { return }
        if b == 0x9c { backToGround(); return }
        if b == 0x1b { enterState(.stringSequenceEscape); return }
        sequenceLength += 1
    }

    /// `.stringSequenceEscape`: mirrors `.oscEscape` for DCS/SOS/PM/APC bodies.
    private mutating func handleStringSequenceEscapeByte(_ b: UInt8, into committed: inout [CommittedToken]) {
        if enforceSequenceGuard(into: &committed) { return }
        if b == UInt8(ascii: "\\") { backToGround(); return }
        parseState = .stringSequence
        sequenceLength += 1
    }

    /// `.abortedSequence`: still discarding the tail of a malformed sequence that
    /// tripped the max-length guard. CSI-shaped bytes (params/intermediates) keep
    /// being swallowed; anything else (a plausible final byte, a fresh ESC, or
    /// ordinary text) returns to `.ground` and is re-handled there.
    private mutating func handleAbortedSequenceByte(_ b: UInt8, into committed: inout [CommittedToken]) {
        if (0x20...0x3f).contains(b) { return }
        backToGround()
        handleByte(b, into: &committed)
    }

    /// Move to a new non-ground state, resetting the length counter.
    private mutating func enterState(_ state: ParseState) {
        parseState = state
        sequenceLength = 0
    }

    /// Return to `.ground`, clearing the length counter.
    private mutating func backToGround() {
        parseState = .ground
        sequenceLength = 0
    }

    /// 64-byte max-sequence guard: if a sequence exceeds the bound with no
    /// final/terminator byte, abort defensively (never hang swallowing forever).
    /// Transitions to `.abortedSequence` (not straight to `.ground`) so trailing
    /// bytes shaped like more of the SAME malformed sequence are still discarded.
    /// Returns true if the guard fired (caller must return without further work).
    private mutating func enforceSequenceGuard(into committed: inout [CommittedToken]) -> Bool {
        guard sequenceLength >= Self.maxSequenceLength else { return false }
        parseState = .abortedSequence
        resetLineContext()
        return true
    }

    /// Commit `current` as a token, UNLESS we're inside a paste (L3) or the token
    /// is a denylisted secret value (L4b), in which case the token is dropped and
    /// does NOT advance `previous` (reach-back-over: the dropped token is invisible
    /// to the learned stream and bigram chain). L4b additionally advances
    /// `secretCheckPrev` to the dropped secret so the token AFTER it is not
    /// cascadingly dropped by the flag→value rule.
    private mutating func commitCurrent(into committed: inout [CommittedToken]) {
        guard !current.isEmpty else { return }
        // L3: inside a paste, drop; do NOT touch `previous` or `secretCheckPrev`.
        if withinPaste {
            current = ""
            droppedInPaste += 1   // privacy-safe tally (count, not text) for the App drop-gate log
            return
        }
        // L4b: a denylisted secret value, drop, no `previous` advance (the next
        // real token reaches back over the secret to `previous` for bigrams). Clear
        // `secretCheckPrev`, a dropped secret is never a flag/header, so nil
        // prevents the cascade without retaining the secret string in memory.
        if isSecretValueToken(current, precededBy: secretCheckPrev) {
            secretCheckPrev = nil
            current = ""
            droppedAsSecret += 1   // privacy-safe tally (count, not text) for the App drop-gate log
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
        line = ""
        previous = nil
        secretCheckPrev = nil
        lineOptedOut = false
        sawLineStart = false
    }

    /// Clear all context (e.g. a context/host switch).
    public mutating func reset() {
        current = ""; line = ""; previous = nil; secretCheckPrev = nil
        withinPaste = false
        parseState = .ground
        sequenceLength = 0
        lineOptedOut = false
        lastCommittedLineOptedOut = false
        sawLineStart = false
        droppedInPaste = 0
        droppedAsSecret = 0
    }
}

/// The chips to show for `current` given the engine's ranked `suggestions`: the
/// engine already prefix-matches, applies the confidence floor, and caps at top-K;
/// the strip only drops the exact token already typed (and any empties).
public func predictorChips(current: String, suggestions: [String]) -> [String] {
    suggestions.filter { $0 != current && !$0.isEmpty }
}
