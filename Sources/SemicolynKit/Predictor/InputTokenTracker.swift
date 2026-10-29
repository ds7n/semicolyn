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
/// editing keys (arrows, Home/End, Ctrl-*) reset the prefix context, while a
/// ``LineEditBuffer`` follows the in-place edits so the final line can still be
/// learned at Enter. Tab keeps the tokens committed before it but drops the word
/// it completes, since remote-side completion (whose result arrives as output) is
/// not reflected.
public struct InputTokenTracker: Equatable, Sendable {
    /// The token currently being typed (since the last delimiter).
    public private(set) var current: String = ""
    /// The full input line since the last line reset (for line-shape context).
    /// Intentionally RETAINS paste-suppressed (L3) text, unlike `current`, which
    /// drops it: line-SHAPE detection wants what the user physically typed. A Tab
    /// restarts it (the remote's completion is not visible here). `line` is a
    /// transient shape signal only, it is never learned or logged verbatim.
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
        /// After `ESC O` (SS3): the next byte names the key. Cursor keys arrive this
        /// way in application-cursor mode (`ESC O D` is Left), F1-F4 always.
        case ss3
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
    /// Monotonic tally of words DROPPED because a Tab completed them on the remote
    /// (the whole word is never seen). Privacy-safe count only.
    public private(set) var droppedAfterCompletion = 0
    /// True once a Tab completed something on the current line; cleared at Enter and
    /// at a line reset. The App uses it to read the commit row only when the
    /// post-Tab text can be compared with it.
    public private(set) var completedThisLine = false
    /// True from a Tab until the word it completed ends (space, Enter): the bytes
    /// typed in between continue a word whose start only the remote knows.
    private var inCompletedWord = false
    /// True when the word being completed is flag-shaped (`--pass` Tab): its value
    /// may be a secret, so the token after it is dropped (L4b, conservatively).
    private var completedWordIsFlag = false
    /// True when any of the completed word was typed (before or after its Tabs).
    private var completedWordHadTypedText = false
    /// Set when a completed flag word ended: the next token is treated as its value.
    private var nextTokenMayBeSecretValue = false
    /// Monotonic count of line-context resets (ESC, Ctrl-C/U/W, cursor keys,
    /// other controls, an aborted sequence), never Enter. The App compares it across
    /// `observe` to spot a context break and reset its per-line state. Cleared by
    /// `reset()`.
    public private(set) var lineResets = 0
    /// The command line as typed, with a cursor, for learning a line edited in
    /// place (see ``LineEditBuffer``). Cleared at Enter, Ctrl-C and `reset()`.
    private var editBuffer = LineEditBuffer()

    /// The current line split at the cursor, while it has been edited in place and
    /// every edit was one the buffer follows; nil otherwise. At Enter such a line is
    /// learned from this text (re-read as typed), not from the words committed as
    /// they were typed, so the App checks both halves against the screen first.
    public var editedLine: (beforeCursor: String, afterCursor: String)? {
        guard editBuffer.edited, editBuffer.usable else { return nil }
        return (editBuffer.beforeCursor, editBuffer.afterCursor)
    }

    public init() {}

    /// Fold one chunk of outgoing bytes. Returns the tokens committed by this chunk
    /// (newest last), in order, for the caller to learn.
    ///
    /// Only tokens committed after the chunk's last line reset are returned: the App
    /// drops its buffered words at a reset it sees between chunks, and a reset inside
    /// one chunk must drop the words before it the same way (an edited line is then
    /// re-emitted whole at Enter, so they are never learned twice).
    public mutating func observe(_ bytes: [UInt8]) -> [CommittedToken] {
        var committed: [CommittedToken] = []
        for b in bytes {
            let resets = lineResets
            handleByte(b, into: &committed)
            if lineResets != resets { committed.removeAll() }
        }
        return committed
    }

    /// C0 control bytes that represent a user editing gesture we cannot faithfully
    /// replay (no cursor model): treated as a line-context reset in `.ground`.
    private static let editingC0: Set<UInt8> = [0x17, 0x15, 0x0b, 0x01, 0x03, 0x05]  // Ctrl-W/U/K/A/C/E

    /// The tmux prefix byte (`Ctrl-A`, the app's default). Under tmux the prefix
    /// flips tmux into its prefix key-table and the NEXT byte dispatches a
    /// binding (`prefix c` -> new-window): that following key is a tmux COMMAND, not
    /// typed text, so it must be swallowed rather than extend `current`. Device log
    /// (build 146) showed `Ctrl-A c whoami` leaking the binding `c` as `cwhoami`.
    /// (Only 0x01 arms this: the other `editingC0` keys are ordinary line edits whose
    /// following byte IS normal text.)
    private static let tmuxPrefix: UInt8 = 0x01

    /// One-shot: set when the tmux prefix was just seen; the next `.ground` byte is the
    /// binding key (a command) and is swallowed, then this clears. Persists across
    /// `observe(_:)` chunks (the binding key may arrive in a later chunk).
    private var expectingPrefixCommand = false

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
        case .ss3:
            handleSS3Byte(b, into: &committed)
        case .abortedSequence:
            handleAbortedSequenceByte(b, into: &committed)
        }
    }

    /// `.ground`: printable bytes extend `current`/`line`; C0 controls dispatch as
    /// today (enter/backspace/tab/editing-reset); ESC/C1-CSI/C1-OSC transition out.
    private mutating func handleGroundByte(_ b: UInt8, into committed: inout [CommittedToken]) {
        // Escape-sequence introducers ALWAYS start their state machine, even while a
        // prefix swallow is armed: a terminal auto-response (e.g. a DA `ESC[...c`) can
        // race in right after the user's prefix byte, before their binding key. If the
        // swallow ate the leading ESC, the sequence body would fall through as garbage
        // text (the exact poisoning the sanitizer prevents). So transition FIRST; the
        // arm still catches the next real ground byte (the actual binding key).
        if b == 0x1b { enterState(.escape); return }
        if b == 0x9b { enterState(.csi(hadPrivateMarker: false, paramBytes: [])); return }
        if b == 0x9d { enterState(.osc); return }
        // One-shot: the byte right after the tmux prefix is a binding key (a command),
        // not typed text. Swallow it, clear the arm, and do nothing else.
        if expectingPrefixCommand {
            expectingPrefixCommand = false
            return
        }

        if !sawLineStart {
            sawLineStart = true
            if b == 0x20 { lineOptedOut = true }
        }
        switch b {
        case 0x21...0x7e:               // printable, non-space → extend the token
            current.unicodeScalars.append(UnicodeScalar(b))
            line.unicodeScalars.append(UnicodeScalar(b))
            editBuffer.insert(UnicodeScalar(b))
        case 0x20:                      // space → commit (unless within paste)
            commitCurrent(into: &committed)
            line.unicodeScalars.append(UnicodeScalar(b))
            editBuffer.insert(UnicodeScalar(b))
        case 0x0d, 0x0a:                // enter → commit, latch the line's opt-out
            commitCurrent(into: &committed)
            lastCommittedLineOptedOut = lineOptedOut   // latch BEFORE the reset below
            if editBuffer.edited && editBuffer.usable {
                commitEditedLine(into: &committed)
            }
            clearEditBuffer()
            current = ""
            line = ""
            previous = nil
            secretCheckPrev = nil
            lineOptedOut = false
            sawLineStart = false
            clearCompletionState()
        case 0x7f, 0x08:                // backspace → pop one char
            if !current.isEmpty { current.removeLast() }
            if !line.isEmpty { line.removeLast() }
            editBuffer.deleteBackward()
        case 0x09 where withinPaste:    // pasted tab → inserted text, splits words like a space
            commitCurrent(into: &committed)
            line.unicodeScalars.append(" ")
        case 0x09:                      // tab → remote completion of the current word
            beginCompletion()
            editBuffer.markUnusable()
        case let c where Self.editingC0.contains(c):   // Ctrl-W/U/K/A/C/E → reset
            applyEditingC0(c)
            resetLineContext()
            // The tmux prefix additionally arms a one-shot swallow of the binding key
            // that follows (the other editing keys take normal text after them).
            if c == Self.tmuxPrefix { expectingPrefixCommand = true }
        default:                        // other control → reset line context
            editBuffer.markUnusable()
            resetLineContext()
        }
    }

    /// The line edit an editing control key makes. Ctrl-A is also the tmux prefix,
    /// so whether it moved the cursor is unknown: the buffer stops following.
    private mutating func applyEditingC0(_ c: UInt8) {
        switch c {
        case 0x17: editBuffer.killWordBackward()   // Ctrl-W
        case 0x15: editBuffer.killToStart()        // Ctrl-U
        case 0x0b: editBuffer.killToEnd()          // Ctrl-K
        case 0x05: editBuffer.moveToEnd()          // Ctrl-E
        case 0x03:                                 // Ctrl-C: the line is abandoned
            clearEditBuffer()
            secretCheckPrev = nil
        default: editBuffer.markUnusable()         // Ctrl-A (tmux prefix)
        }
    }

    /// Learn an edited line from the buffer: re-read its final text as if typed in
    /// one go, so the paste-free secret gates (L4a leading space, L4b secret values)
    /// apply to it exactly as to a typed line. The line is opted out if it begins
    /// with a space now or did when typed (a space inserted after an edit is not a
    /// line start).
    private mutating func commitEditedLine(into committed: inout [CommittedToken]) {
        var retyped = InputTokenTracker()
        committed += retyped.observe(Array(editBuffer.text.utf8) + [0x0d])
        droppedAsSecret += retyped.droppedAsSecret
        lastCommittedLineOptedOut = editBuffer.typedWithLeadingSpace || retyped.lastCommittedLineOptedOut
    }

    /// Start a new edit buffer. Inside a paste it stays unusable: a pasted Enter or
    /// Ctrl-C must not let the rest of the paste pass as typed text.
    private mutating func clearEditBuffer() {
        editBuffer.clear()
        if withinPaste { editBuffer.markUnusable() }
    }

    /// The line edit a cursor key makes: Left, Right, Home, End and Delete move or
    /// delete within the buffer; Up/Down (history), Page keys and modified keys
    /// (Ctrl-Left moves by word) stop the buffer following the line.
    private mutating func applyCursorKey(final: UInt8, param0: Int?, modified: Bool) {
        guard !modified else { editBuffer.markUnusable(); return }
        switch (final, param0) {
        case (UInt8(ascii: "D"), _): editBuffer.moveLeft()
        case (UInt8(ascii: "C"), _): editBuffer.moveRight()
        case (UInt8(ascii: "H"), _), (UInt8(ascii: "~"), 1), (UInt8(ascii: "~"), 7): editBuffer.moveToStart()
        case (UInt8(ascii: "F"), _), (UInt8(ascii: "~"), 4), (UInt8(ascii: "~"), 8): editBuffer.moveToEnd()
        case (UInt8(ascii: "~"), 3): editBuffer.deleteForward()
        default: editBuffer.markUnusable()
        }
    }

    /// `.escape`: the byte right after a bare ESC selects the sequence kind.
    /// Deliberately does NOT call `enforceSequenceGuard`: `.escape` is a single-byte
    /// transition state (exactly one byte is ever consumed here before moving to
    /// `.csi`/`.osc`/`.stringSequence`/back to `.ground`), so it is bounded by
    /// construction and cannot accumulate length like the other 5 handlers do.
    private mutating func handleEscapeByte(_ b: UInt8, into committed: inout [CommittedToken]) {
        switch b {
        case UInt8(ascii: "["):
            enterState(.csi(hadPrivateMarker: false, paramBytes: []))
        case UInt8(ascii: "]"):
            enterState(.osc)
        case UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"):
            enterState(.stringSequence)
        case UInt8(ascii: "O"):
            enterState(.ss3)
        case 0x30...0x7e:
            // Two-byte ESC-final sequence (e.g. ESC c, ESC =, ESC >): discard, back to
            // ground. From a keyboard this is a Meta key (ESC b moves back a word),
            // which the edit buffer does not follow.
            backToGround()
            editBuffer.markUnusable()
        default:
            // A bare ESC followed by a deviating byte (not a recognized sequence
            // starter): the ESC itself is a line reset (preserve existing "ESC ⇒
            // reset" behavior); the deviating byte is re-handled in ground.
            backToGround()
            editBuffer.markUnusable()
            resetLineContext()
            handleByte(b, into: &committed)
        }
    }

    /// `.ss3`: the key after `ESC O`. A cursor key is a line edit, as its CSI form
    /// is; F1-F4 and keypad keys are swallowed. A byte that cannot end the sequence
    /// resets the line and is re-handled in ground.
    private mutating func handleSS3Byte(_ b: UInt8, into committed: inout [CommittedToken]) {
        backToGround()
        switch b {
        case UInt8(ascii: "A"), UInt8(ascii: "B"), UInt8(ascii: "C"), UInt8(ascii: "D"),
             UInt8(ascii: "H"), UInt8(ascii: "F"):
            applyCursorKey(final: b, param0: nil, modified: false)
            resetLineContext()
        case 0x40...0x7e:
            editBuffer.markUnusable()
        default:
            editBuffer.markUnusable()
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
            editBuffer.markUnusable()
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
        let modified = paramBytes.contains(UInt8(ascii: ";"))
        switch csiKind(finalByte: finalByte, hadPrivateMarker: hadPrivateMarker, param0: param0) {
        case .editing:
            applyCursorKey(final: finalByte, param0: param0, modified: modified)
            resetLineContext()
        case .responseOrFormat where !hadPrivateMarker && finalByte == UInt8(ascii: "~")
                && [4, 7, 8].contains(param0):
            // The other Home/End encodings (`ESC[7~`, `ESC[4~`, `ESC[8~`) edit the
            // line like `ESC[1~` and `ESC[F` do.
            applyCursorKey(final: finalByte, param0: param0, modified: modified)
            resetLineContext()
        case .responseOrFormat where !hadPrivateMarker
                && (finalByte == UInt8(ascii: "~") || finalByte == UInt8(ascii: "Z")):
            // Other keys (Insert, F5 and up, Shift-Tab, the app's private tmux gesture
            // keys): swallowed as before, but the edit buffer stops following, since
            // the remote may have acted on the line (or switched tmux window).
            editBuffer.markUnusable()
        case .responseOrFormat:
            break   // swallow, `current` untouched
        case .pasteEnter:
            withinPaste = true
            editBuffer.markUnusable()
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
    /// ordinary text) returns to `.ground` and is re-handled there. Deliberately
    /// does NOT call `enforceSequenceGuard`: this state IS the guard's already-
    /// aborted swallow, re-running the length check here would be a no-op
    /// (`sequenceLength` was already reset on entry) and re-triggering the abort
    /// path from within itself would be redundant, not a second bound.
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
        editBuffer.markUnusable()
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
        // An edited line is learned whole from the edit buffer at Enter; a word
        // committed now may still be edited, so nothing is emitted for it.
        if editBuffer.edited && editBuffer.usable {
            current = ""
            return
        }
        if inCompletedWord {
            endCompletedWord()
            return
        }
        guard !current.isEmpty else { return }
        // L4b after a Tab-completed flag (`--pass` Tab): the flag's full text was
        // never seen, so its value is dropped without the denylist check.
        if nextTokenMayBeSecretValue {
            nextTokenMayBeSecretValue = false
            secretCheckPrev = nil
            current = ""
            droppedAsSecret += 1
            return
        }
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

    /// Tab: the remote completes the current word, so the typed text no longer
    /// matches the screen. `line` restarts at what is typed next (acceptance edits
    /// only that), but the line has not ended: tokens already committed stay, as do
    /// the leading-space opt-out (L4a) and the secret-flag predecessor (L4b), so
    /// `mysql -p <Tab>hunter2` still drops the value. The bytes typed until the
    /// word ends continue a word only the remote knows; `endCompletedWord` drops it.
    private mutating func beginCompletion() {
        if !inCompletedWord { completedWordIsFlag = current.hasPrefix("-") }
        if !current.isEmpty { completedWordHadTypedText = true }
        inCompletedWord = true
        completedThisLine = true
        current = ""
        line = ""
        previous = nil
    }

    /// The Tab-completed word ended (space or Enter). It is never learned, nor used
    /// as a bigram predecessor, since its full text was never seen. Its own bytes
    /// still meet the L4b check first, so a secret value typed straight after a Tab
    /// is tallied as one.
    ///
    /// When nothing was typed into the word (`mysql -p <Tab> hunter2`), the secret
    /// predecessor is kept, so the next token is still checked against `-p`: the
    /// Tab inserted nothing, or a word that may itself be the flag's value.
    private mutating func endCompletedWord() {
        let hadTypedText = completedWordHadTypedText || !current.isEmpty
        if !current.isEmpty, isSecretValueToken(current, precededBy: secretCheckPrev) {
            droppedAsSecret += 1
        } else if hadTypedText {
            droppedAfterCompletion += 1
        }
        nextTokenMayBeSecretValue = completedWordIsFlag
        inCompletedWord = false
        completedWordIsFlag = false
        completedWordHadTypedText = false
        current = ""
        previous = nil
        if hadTypedText { secretCheckPrev = nil }
    }

    private mutating func clearCompletionState() {
        completedThisLine = false
        inCompletedWord = false
        completedWordIsFlag = false
        completedWordHadTypedText = false
        nextTokenMayBeSecretValue = false
    }

    /// ESC / unknown-control line reset (matches the pre-Phase-2 `default` case).
    ///
    /// The secret-flag predecessor (L4b) survives: the line has not ended, so a value
    /// typed after the break (`mysql -p`, an edit key, ` hunter2`) is still checked
    /// against the flag. At worst one harmless word after a flag is over-dropped.
    private mutating func resetLineContext() {
        lineResets += 1
        current = ""
        line = ""
        previous = nil
        lineOptedOut = false
        sawLineStart = false
        clearCompletionState()
    }

    /// Clear all context (e.g. a context/host switch).
    public mutating func reset() {
        current = ""; line = ""; previous = nil; secretCheckPrev = nil
        withinPaste = false
        parseState = .ground
        sequenceLength = 0
        expectingPrefixCommand = false
        lineOptedOut = false
        lastCommittedLineOptedOut = false
        sawLineStart = false
        droppedInPaste = 0
        droppedAsSecret = 0
        droppedAfterCompletion = 0
        lineResets = 0
        editBuffer.clear()
        clearCompletionState()
    }
}
