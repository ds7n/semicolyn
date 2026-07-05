<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Predictor Secret-Exclusion — Phase 2: L3 Paste Exclusion + L4 Context/Leading-Space (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two deterministic write-time exclusion gates to the keystroke predictor — L3 (never learn tokens typed inside a bracketed paste) and L4 (leading-space line opt-out + an argument-position secret denylist) — closing the pasted-secret and flagged-secret gaps the L1 echo layer structurally cannot see.

**Architecture:** All logic is **pure Kit (Linux-tested)** in the existing `InputTokenTracker` plus one new pure denylist unit — no App-tier work, no `EchoOracle`. The tracker gains a bracketed-paste state machine (L3), a per-line leading-space opt-out (L4a), and a per-token argument-position denylist (L4b). A suppressed token is **dropped entirely** from the committed-token stream AND does **not** advance the bigram `previous` — so a secret value is invisible to learning while the next real token still chains to the token *before* the secret (reach-back-over semantics). The App's existing per-line learn flow is unchanged except to honor the tracker's new line-level opt-out.

**Tech Stack:** Swift 6.1, SemicolynKit (XCTest, Linux via Docker `semicolyn-dev`). No new dependencies.

## Global Constraints

- **Pure Kit, Linux-tested:** all Phase 2 logic lives in `Sources/SemicolynKit/Predictor/` — no `import UIKit`/`SwiftUI`/`SwiftTerm`/`CryptoKit`. `InputTokenTracker` stays `Equatable, Sendable`.
- **Reframe governs:** predictor, not scanner — a false positive costs one skipped word, a false negative leaks a credential. **Exclusion wins ties; every failure mode suppresses.**
- **Fail closed on malformed input** (L3): an unmatched paste-close is ignored; an unmatched paste-open keeps `withinPaste` set until the next close or a line-context reset (ESC/Ctrl-C) — suppressing *more*, never less.
- **A suppressed (dropped) token never becomes `previous`** — it must not appear in the bigram chain. The next token chains to the token that preceded the secret (reach-back-over, user-chosen).
- **L4b denylist: conservative defaults only, no user-editable rules in v1** (locked spec decision, YAGNI).
- **Every source file carries the SPDX header** (`// SPDX-FileCopyrightText: 2026 True Positive LLC` / `// SPDX-License-Identifier: GPL-3.0-only`). REUSE-compliant.
- **Tests must be real** (testing-standards spec): equivalence-partitioning + boundary values, assert the *specific* observable outcome, never "it returned". L3/L4b are **Critical-tier** (a miss leaks a credential) — adversarial negatives mandatory; L4a is **Core**.
- **Conventional commits**; feature branch `feat/predictor-secret-exclusion-phase2` off `main`; squash-merge.
- **Build/test command (no host Swift toolchain):**
  `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <TestClass>`

## Spec & Source References

- Spec: `docs/superpowers/specs/2026-07-04-predictor-secret-exclusion-design.md` — sections **L3**, **L4**, "Data flow & layer ordering", "Testing".
- The tracker being extended: `Sources/SemicolynKit/Predictor/InputTokenTracker.swift` (`CommittedToken` + `InputTokenTracker.observe`).
- Pattern-table style to mirror for L4b: `Sources/SemicolynKit/Predictor/TokenFilter.swift` (`ExcludePattern`/`defaultPatterns`).
- App consumer (context only — Phase 2 touches it minimally): `App/ConnectionViewModel.swift:755` `observePredictorInput` (buffers `tracker.observe(bytes)` into `pendingLineTokens`, learns them if `shouldLearnCommittedLine()`).

## Current behavior (what the tracker does today)

`InputTokenTracker.observe(_ bytes:) -> [CommittedToken]` scans outgoing bytes: printable non-space extends `current`; space commits `current` (sets `previous = current`, clears `current`); Enter commits `current` then clears both `current` and `previous`; backspace pops; tab clears the partial; any other control byte resets `current` + `previous`. `CommittedToken` is `{ token, previous }`. The App buffers all committed tokens for a line and learns them as a unit iff the L1 line verdict passes.

## File Structure

- **Modify** `Sources/SemicolynKit/Predictor/InputTokenTracker.swift` — the home for L3 (paste state machine), L4a (leading-space line opt-out), and L4b (denylist application). One responsibility stays: reconstruct + emit the line's *learnable* tokens.
- **Create** `Sources/SemicolynKit/Predictor/SecretArgDenylist.swift` — the pure L4b typed table + the per-line "which token indexes are secret values" logic. One responsibility: given a reconstructed token list, decide which tokens are secret-bearing values. Kept separate from the tracker so it is independently unit-testable (mirrors `TokenFilter` living apart from the store).
- **Modify** `Tests/SemicolynKitTests/InputTokenTrackerTests.swift` (create if absent) — L3 + L4a + integration tests through the tracker's public `observe`.
- **Create** `Tests/SemicolynKitTests/SecretArgDenylistTests.swift` — L4b unit tests (each flag form, case-insensitivity, header, `user:pass@host`).
- **Modify** `App/ConnectionViewModel.swift` — honor the tracker's new line-level opt-out (L4a) when flushing `pendingLineTokens`; no other change (L3/L4b are already applied inside the tracker, so dropped tokens simply never reach `pendingLineTokens`). App-tier — macOS-CI-verified.

---

## Task 1: L3 — bracketed-paste state machine (drop tokens typed within a paste)

Add a `withinPaste` state machine to the tracker. Bracketed-paste markers are `ESC[200~` (enter) and `ESC[201~` (exit) — the multi-byte sequences `1B 5B 32 30 30 7E` and `1B 5B 32 30 31 7E`. While `withinPaste`, tokens are still tracked for prefix context but **never emitted as committed** (and never advance `previous` — reach-back-over). Malformed markers fail closed.

**Files:**
- Modify: `Sources/SemicolynKit/Predictor/InputTokenTracker.swift`
- Test: `Tests/SemicolynKitTests/InputTokenTrackerTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces (relied on by Task 3 integration + the App): `InputTokenTracker.observe(_:)` unchanged signature (`[CommittedToken]`), now dropping within-paste tokens. New internal state `withinPaste`. `reset()` clears it.

**Design note — the ESC problem.** Today the tracker's `default` case (any control byte, including `0x1B` ESC) resets `current`+`previous`. A bracketed-paste sequence *starts* with ESC, so the state machine must recognize the full `ESC [ 2 0 0 ~` / `ESC [ 2 0 1 ~` sequences BEFORE the generic ESC-reset fires. Implement a small pending-escape buffer: when `0x1B` arrives, start capturing; match against the two known 6-byte sequences; a completed match toggles `withinPaste` and consumes the sequence; any deviation flushes the captured bytes back through the normal reset behavior (ESC → reset line context, exactly as today).

- [ ] **Step 1: Write the failing test**

Create `Tests/SemicolynKitTests/InputTokenTrackerTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// L3 (paste) + L4a (leading space) live in the tracker. Critical-tier for the
/// paste path: a pasted secret that leaks into the learned stream is a credential
/// leak, so the negative cases assert the specific token is ABSENT from the
/// committed output.
final class InputTokenTrackerTests: XCTestCase {
    /// Bracketed-paste enter/exit markers as raw bytes.
    private let pasteOn: [UInt8]  = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]  // ESC[200~
    private let pasteOff: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]  // ESC[201~

    /// Feed a full byte sequence and collect every committed token's `.token`.
    private func committedTokens(_ bytes: [UInt8]) -> [String] {
        var t = InputTokenTracker()
        return t.observe(bytes).map(\.token)
    }

    // MARK: - L3 bracketed paste

    func testTokenTypedInsidePasteIsNotCommitted() {
        // export TOKEN=<paste>ghp_secret</paste>\n  → the pasted value must not learn.
        var bytes: [UInt8] = Array("export ".utf8)
        bytes += pasteOn
        bytes += Array("ghp_deadbeef".utf8)
        bytes += pasteOff
        bytes += [0x0d]
        let tokens = committedTokens(bytes)
        XCTAssertEqual(tokens, ["export"])            // only the pre-paste token
        XCTAssertFalse(tokens.contains("ghp_deadbeef"))
    }

    func testTokensBeforeAndAfterPasteStillCommit() {
        // a <paste>b</paste> c\n  → learn "a" and "c", never "b".
        var bytes: [UInt8] = Array("a ".utf8)
        bytes += pasteOn; bytes += Array("b".utf8); bytes += pasteOff
        bytes += Array(" c".utf8); bytes += [0x0d]
        XCTAssertEqual(committedTokens(bytes), ["a", "c"])
    }

    func testUnmatchedPasteOpenFailsClosed() {
        // ESC[200~ with no close: everything after stays suppressed until reset.
        var bytes: [UInt8] = pasteOn
        bytes += Array("secretvalue".utf8)
        bytes += [0x0d]                                // Enter commits the line…
        XCTAssertEqual(committedTokens(bytes), [])     // …but nothing was learnable
    }

    func testUnmatchedPasteCloseIsIgnored() {
        // A stray ESC[201~ with no open must not corrupt normal tracking.
        var bytes: [UInt8] = Array("ls".utf8)
        bytes += pasteOff
        bytes += Array(" -la".utf8); bytes += [0x0d]
        // ESC[201~ (unmatched close) is a line-context reset (ESC behavior), so
        // "ls" is dropped by the reset and "-la" is the surviving token.
        XCTAssertEqual(committedTokens(bytes), ["-la"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter InputTokenTrackerTests`
Expected: FAIL — `testTokenTypedInsidePasteIsNotCommitted` etc. fail (the pasted token IS currently committed; markers are treated as ESC-resets mid-sequence).

- [ ] **Step 3: Implement the paste state machine**

In `Sources/SemicolynKit/Predictor/InputTokenTracker.swift`, add state + rewrite `observe`. Add these stored properties after `previous`:

```swift
    /// True while inside a bracketed paste (`ESC[200~`…`ESC[201~`): tokens are
    /// tracked for prefix context but never emitted/learned (L3).
    public private(set) var withinPaste = false
    /// Bytes captured after a bare `ESC`, pending a bracketed-paste match. Empty
    /// when not mid-escape. Flushed back to normal handling on any deviation.
    private var escapeBuffer: [UInt8] = []
```

Add these two constants at file scope (below the imports/`CommittedToken`, above the struct is fine, or as `static` inside):

```swift
    private static let pasteEnter: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]  // ESC[200~
    private static let pasteExit: [UInt8]  = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]  // ESC[201~
```

Rewrite `observe(_:)`. The new loop routes each byte through `handleByte`, which first services any pending escape capture:

```swift
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
                else if escapeBuffer == Self.pasteExit { withinPaste = false; escapeBuffer = [] }
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
        switch b {
        case 0x21...0x7e:               // printable, non-space → extend the token
            current.unicodeScalars.append(UnicodeScalar(b))
        case 0x20:                      // space → commit (unless within paste)
            commitCurrent(into: &committed)
        case 0x0d, 0x0a:                // enter → commit, then new line
            commitCurrent(into: &committed)
            current = ""
            previous = nil
        case 0x7f, 0x08:                // backspace → pop one char
            if !current.isEmpty { current.removeLast() }
        case 0x09:                      // tab → remote completion: drop the partial
            current = ""
        default:                        // other control → reset line context
            resetLineContext()
        }
    }

    /// Commit `current` as a token — UNLESS we're inside a paste, in which case the
    /// token is dropped and does NOT advance `previous` (reach-back-over: a pasted
    /// secret is invisible to both the learned stream and the bigram chain).
    private mutating func commitCurrent(into committed: inout [CommittedToken]) {
        guard !current.isEmpty else { return }
        if withinPaste {
            current = ""                // drop; do NOT touch `previous`
            return
        }
        committed.append(CommittedToken(token: current, previous: previous))
        previous = current
        current = ""
    }

    /// ESC / unknown-control line reset (matches the pre-Phase-2 `default` case).
    private mutating func resetLineContext() {
        current = ""
        previous = nil
    }
```

Update `reset()` to clear the new state:

```swift
    public mutating func reset() {
        current = ""; previous = nil
        withinPaste = false
        escapeBuffer = []
    }
```

> Note on `testUnmatchedPasteCloseIsIgnored`: `ESC[201~` when NOT already `withinPaste` completes the `pasteExit` marker and sets `withinPaste = false` (a no-op) — it does NOT reset the line. Re-check the expected token list: with this implementation, `ls` then `ESC[201~` (a recognized exit marker, no reset) then ` -la` commits BOTH `ls` and `-la`. **Update the test's expectation to `["ls", "-la"]`** and its comment to "a recognized (if redundant) exit marker is consumed harmlessly — it does not reset the line." (An unmatched *open* is the fail-closed case; an unmatched *close* is simply a redundant already-outside signal.) Fix the test in this step before re-running.

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter InputTokenTrackerTests`
Expected: PASS — all four L3 tests (with the corrected `testUnmatchedPasteCloseIsIgnored` expectation).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Predictor/InputTokenTracker.swift Tests/SemicolynKitTests/InputTokenTrackerTests.swift
git commit -m "feat(predictor): L3 bracketed-paste exclusion in InputTokenTracker"
```

---

## Task 2: L4a — leading-space line opt-out

If the current input line's **first byte is a space**, the whole line is never learned (the `HISTCONTROL=ignorespace` gesture). The space is still sent to the remote; only *learning* is suppressed. Expose a per-line `lineOptedOut` flag the App consults at line commit. This is a line-level verdict (like L1's), NOT a per-token drop.

**Files:**
- Modify: `Sources/SemicolynKit/Predictor/InputTokenTracker.swift`
- Test: `Tests/SemicolynKitTests/InputTokenTrackerTests.swift`

**Interfaces:**
- Consumes: the Task 1 tracker.
- Produces (relied on by Task 4 App wiring): `public private(set) var lineOptedOut: Bool` — true when the current line began with a space; reset to false when a new line begins (Enter). `reset()` clears it.

**Design note.** "First byte of the line is a space" means: at the moment the first byte of a fresh line arrives, is it `0x20`? Track a per-line `sawLineStart` boolean: false at the start of each line; the first non-reset byte of the line sets it true and, if that byte is a space, sets `lineOptedOut = true`. Enter/line-reset clears both `lineOptedOut` and `sawLineStart` (next line re-evaluates). A leading space still tokenizes normally (it commits an empty `current` → no-op), so token emission is unaffected; only the flag matters.

- [ ] **Step 1: Write the failing test**

Append to `Tests/SemicolynKitTests/InputTokenTrackerTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter InputTokenTrackerTests`
Expected: FAIL — `value of type 'InputTokenTracker' has no member 'lineOptedOut'`.

- [ ] **Step 3: Implement the leading-space flag**

In `InputTokenTracker.swift`, add stored properties:

```swift
    /// True when the current line began with a space (`HISTCONTROL=ignorespace`
    /// gesture): the WHOLE line is suppressed from learning (L4a). Reset each line.
    public private(set) var lineOptedOut = false
    /// Whether the first byte of the current line has been seen yet (to detect a
    /// leading space exactly at line start).
    private var sawLineStart = false
```

In `classify(_:into:)`, record the line-start check at the very top of the method (before the `switch`), so it sees the first byte of the line:

```swift
        if !sawLineStart {
            sawLineStart = true
            if b == 0x20 { lineOptedOut = true }
        }
```

In `classify`, the Enter case (`0x0d, 0x0a`) must reset the per-line flags after committing — change that case to:

```swift
        case 0x0d, 0x0a:                // enter → commit, then new line
            commitCurrent(into: &committed)
            current = ""
            previous = nil
            lineOptedOut = false
            sawLineStart = false
```

And `resetLineContext()` should also clear them (ESC/Ctrl-C starts a fresh line context):

```swift
    private mutating func resetLineContext() {
        current = ""
        previous = nil
        lineOptedOut = false
        sawLineStart = false
    }
```

Update `reset()`:

```swift
    public mutating func reset() {
        current = ""; previous = nil
        withinPaste = false
        escapeBuffer = []
        lineOptedOut = false
        sawLineStart = false
    }
```

> Ordering caveat for the implementer: the `if !sawLineStart` block at the top of `classify` runs for the Enter byte too, but that's harmless — an Enter as the very first byte of a line sets `sawLineStart` then immediately the Enter case resets it. A leading space is `0x20`, handled by the `0x20` case (commit no-op) AFTER the line-start check already set `lineOptedOut`. Verify `testMidLineSpaceDoesNotOptOut` passes: the space in `git commit` is not the first byte (`sawLineStart` already true when it arrives), so `lineOptedOut` stays false.

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter InputTokenTrackerTests`
Expected: PASS — all L3 + L4a tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Predictor/InputTokenTracker.swift Tests/SemicolynKitTests/InputTokenTrackerTests.swift
git commit -m "feat(predictor): L4a leading-space line opt-out"
```

---

## Task 3: L4b — argument-position secret denylist (pure unit)

A pure table + function that, given a reconstructed line's tokens, returns which token **indexes** are secret values to drop. Kept separate from the tracker (mirrors `TokenFilter`). Rules (conservative defaults, case-insensitive):
- **flag → value:** the token after `-p` / `--password` / `-P` / `--pass` / `--token` / `--api-key` / `--secret` / `--passphrase`. Both `--token X` (value is the next token) and `--token=X` (value is the `=`-suffix of the same token — in that case the FLAG token itself is the secret carrier and must be dropped whole).
- **header:** the value token following an `Authorization:` or `X-Api-Key:` token (`Authorization: Bearer xyz` → drop `Bearer` and `xyz`? — NO: drop only the credential token; see design note).
- **connection string:** a token matching `user:pass@host` → drop the whole token (it embeds the password).

**Files:**
- Create: `Sources/SemicolynKit/Predictor/SecretArgDenylist.swift`
- Test: `Tests/SemicolynKitTests/SecretArgDenylistTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces (relied on by Task 4 tracker integration wiring, if you choose to apply it in the tracker, or by the App): the pure function below.

**Design note — what exactly is a "value token".** Keep it deterministic and conservative:
- For a bare flag (`--token`, `-p`, …) the value is the **immediately following token**, whatever it is. Drop that token. The flag token itself stays (it's not a secret).
- For a `=`-joined flag (`--token=SECRET`), the flag+value are ONE token; drop the **whole token** (it contains the secret). Do not try to keep the `--token=` prefix.
- For headers, `Authorization:` / `X-Api-Key:` are followed by the credential. Conservatively drop **every token after the header token until end-of-line** is over-broad; instead drop the **single token immediately following** the header token (covers `X-Api-Key: KEY`; for `Authorization: Bearer TOKEN` this drops `Bearer` — acceptable over-suppression per the reframe, and `TOKEN` also fails L5/L6 later). Keep it simple: one following token.
- For `user:pass@host`, match a token containing `:` before `@` with non-empty user/pass/host; drop the whole token.

Return a `Set<Int>` of indexes to drop.

- [ ] **Step 1: Write the failing test**

Create `Tests/SemicolynKitTests/SecretArgDenylistTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Critical-tier: a missed secret value here is a leaked credential, so every
/// flag form is an adversarial negative asserting the SPECIFIC dropped index.
final class SecretArgDenylistTests: XCTestCase {
    /// Convenience: which tokens survive after dropping the denylisted indexes.
    private func surviving(_ tokens: [String]) -> [String] {
        let drop = secretValueIndexes(in: tokens)
        return tokens.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }

    func testSpaceSeparatedPasswordFlagDropsValue() {
        XCTAssertEqual(surviving(["mysql", "-p", "hunter2"]), ["mysql", "-p"])
    }

    func testEqualsJoinedTokenFlagDropsWholeToken() {
        XCTAssertEqual(surviving(["curl", "--token=ghp_x"]), ["curl"])
    }

    func testLongPasswordFlagDropsValue() {
        XCTAssertEqual(surviving(["app", "--password", "s3cret"]), ["app", "--password"])
    }

    func testFlagMatchIsCaseInsensitive() {
        XCTAssertEqual(surviving(["app", "--Token", "abc"]), ["app", "--Token"])
        XCTAssertEqual(surviving(["app", "--TOKEN=abc"]), ["app"])
    }

    func testAuthorizationHeaderDropsFollowingToken() {
        // Conservative: drop the single token after the header token.
        XCTAssertEqual(surviving(["curl", "Authorization:", "sekret"]), ["curl", "Authorization:"])
    }

    func testUserPassAtHostDropsWholeToken() {
        XCTAssertEqual(surviving(["ssh", "alice:pw@host"]), ["ssh"])
    }

    func testPlainCommandDropsNothing() {
        XCTAssertEqual(surviving(["git", "commit", "-m", "msg"]), ["git", "commit", "-m", "msg"])
    }

    func testFlagAtEndOfLineWithNoValueDropsNothingExtra() {
        // "--token" with no following token: nothing to drop (no crash / no over-reach).
        XCTAssertEqual(surviving(["curl", "--token"]), ["curl", "--token"])
    }

    func testShortDashPUpperAndLower() {
        XCTAssertEqual(surviving(["x", "-p", "a"]), ["x", "-p"])
        XCTAssertEqual(surviving(["x", "-P", "a"]), ["x", "-P"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter SecretArgDenylistTests`
Expected: FAIL — `cannot find 'secretValueIndexes' in scope`.

- [ ] **Step 3: Implement the denylist**

Create `Sources/SemicolynKit/Predictor/SecretArgDenylist.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// L4b argument-position denylist. Given a reconstructed line's tokens, returns
/// the indexes whose token is a secret-bearing VALUE (or a `flag=value` token that
/// embeds one) and must never be learned. Conservative, deterministic, typed table
/// — no regex over the whole line, no user-editable rules in v1.
///
/// Reframe: over-suppression is cheap (one skipped word); a missed value leaks a
/// credential — so ambiguous forms drop the value.

/// Flags whose FOLLOWING token (space-separated) or `=`-suffix (joined) is secret.
/// Compared case-insensitively.
private let secretFlags: Set<String> = [
    "-p", "--password", "-P", "--pass", "--token", "--api-key", "--secret", "--passphrase",
]

/// Header tokens whose following token is a credential.
private let secretHeaders: Set<String> = [
    "authorization:", "x-api-key:",
]

/// Indexes of tokens to drop as secret values.
public func secretValueIndexes(in tokens: [String]) -> Set<Int> {
    var drop: Set<Int> = []
    for (i, token) in tokens.enumerated() {
        let lower = token.lowercased()
        // `--flag=value` — the whole token embeds the secret.
        if let eq = token.firstIndex(of: "=") {
            let flagPart = String(token[token.startIndex..<eq]).lowercased()
            if secretFlags.contains(flagPart) { drop.insert(i); continue }
        }
        // bare `--flag` / `-p` → drop the NEXT token (the value), if any.
        if secretFlags.contains(lower), i + 1 < tokens.count {
            drop.insert(i + 1)
            continue
        }
        // header token → drop the single following token.
        if secretHeaders.contains(lower), i + 1 < tokens.count {
            drop.insert(i + 1)
            continue
        }
        // `user:pass@host` connection string → drop the whole token.
        if isUserPassAtHost(token) { drop.insert(i) }
    }
    return drop
}

/// True if `token` is a `user:pass@host` credential form (non-empty user, pass,
/// host; the `:` precedes the `@`).
private func isUserPassAtHost(_ token: String) -> Bool {
    guard let at = token.firstIndex(of: "@") else { return false }
    let creds = token[token.startIndex..<at]
    let host = token[token.index(after: at)...]
    guard !host.isEmpty, let colon = creds.firstIndex(of: ":") else { return false }
    let user = creds[creds.startIndex..<colon]
    let pass = creds[creds.index(after: colon)...]
    return !user.isEmpty && !pass.isEmpty
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter SecretArgDenylistTests`
Expected: PASS — all 9 denylist tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Predictor/SecretArgDenylist.swift Tests/SemicolynKitTests/SecretArgDenylistTests.swift
git commit -m "feat(predictor): L4b argument-position secret denylist (pure unit)"
```

---

## Task 4: Apply L4b inside the tracker (drop denylisted value tokens from the committed stream)

Wire `secretValueIndexes` into the tracker so a denylisted value token is **dropped and does not advance `previous`** (reach-back-over), exactly like L3. The tracker reconstructs the line token-by-token, so it must decide, at each space/Enter commit, whether the token *just completed* is a denylisted value — which depends on the token BEFORE it (the flag) or the token's own `=`/`user:pass@host` shape. Apply the single-token rules incrementally at commit time; the flag→value rule uses the already-tracked `previous`.

**Files:**
- Modify: `Sources/SemicolynKit/Predictor/InputTokenTracker.swift`
- Test: `Tests/SemicolynKitTests/InputTokenTrackerTests.swift`

**Interfaces:**
- Consumes: `secretValueIndexes` is index-based, but the tracker commits incrementally — so use the single-token predicates directly. Add a pure helper `isSecretValueToken(_ token: String, precededBy previous: String?) -> Bool` to `SecretArgDenylist.swift` that encodes the incremental view (its logic is the per-token slice of `secretValueIndexes`), and unit-test it, so the tracker and the index function share one source of truth.
- Produces: `commitCurrent` additionally drops denylisted tokens.

**Design note — index function vs. incremental.** Task 3's `secretValueIndexes` is the batch view (good for unit tests + any future whole-line use). The tracker needs the *incremental* view: "is the token I'm about to commit a secret value, given the previous token?". Add `isSecretValueToken(_:precededBy:)` covering: (a) `previous` is a bare secret flag → this token is its value; (b) this token is `--flag=value` for a secret flag → drop it; (c) this token is `user:pass@host`; (d) `previous` is a secret header → this token is the credential. This is the same rule set, sliced per-token.

- [ ] **Step 1: Write the failing test**

Append to `Tests/SemicolynKitTests/InputTokenTrackerTests.swift`:

```swift
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
```

Also append an `isSecretValueToken` unit test to `SecretArgDenylistTests.swift`:

```swift
    func testIncrementalSecretValuePredicate() {
        XCTAssertTrue(isSecretValueToken("hunter2", precededBy: "-p"))
        XCTAssertTrue(isSecretValueToken("--token=x", precededBy: "curl"))
        XCTAssertTrue(isSecretValueToken("alice:pw@host", precededBy: "ssh"))
        XCTAssertTrue(isSecretValueToken("sekret", precededBy: "Authorization:"))
        XCTAssertFalse(isSecretValueToken("commit", precededBy: "git"))
        XCTAssertFalse(isSecretValueToken("--token", precededBy: "curl"))   // the flag itself is not a value
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter "InputTokenTrackerTests|SecretArgDenylistTests"`
Expected: FAIL — `cannot find 'isSecretValueToken'`; the tracker tests fail (secret values are still committed).

- [ ] **Step 3: Implement the incremental predicate + tracker application**

Add to `SecretArgDenylist.swift`:

```swift
/// Incremental (per-token) view of the denylist, for the streaming tracker: is
/// `token` a secret VALUE given the token immediately before it? Same rule set as
/// `secretValueIndexes`, sliced to one token + its predecessor.
public func isSecretValueToken(_ token: String, precededBy previous: String?) -> Bool {
    // (b) `--flag=value` token embeds a secret.
    if let eq = token.firstIndex(of: "=") {
        let flagPart = String(token[token.startIndex..<eq]).lowercased()
        if secretFlags.contains(flagPart) { return true }
    }
    // (c) `user:pass@host` connection string.
    if isUserPassAtHost(token) { return true }
    // (a)/(d) previous token is a secret flag or header → this token is the value.
    if let prev = previous?.lowercased(),
       secretFlags.contains(prev) || secretHeaders.contains(prev) {
        return true
    }
    return false
}
```

In `InputTokenTracker.swift`, update `commitCurrent` to also drop denylisted tokens (reach-back-over: do NOT advance `previous`):

```swift
    private mutating func commitCurrent(into committed: inout [CommittedToken]) {
        guard !current.isEmpty else { return }
        // L3: inside a paste — drop, no `previous` advance.
        if withinPaste {
            current = ""
            return
        }
        // L4b: a denylisted secret value — drop, no `previous` advance (the next
        // real token reaches back over the secret to `previous`).
        if isSecretValueToken(current, precededBy: previous) {
            current = ""
            return
        }
        committed.append(CommittedToken(token: current, previous: previous))
        previous = current
        current = ""
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter "InputTokenTrackerTests|SecretArgDenylistTests"`
Expected: PASS — the tracker drops secret values, reach-back-over `previous` is correct, and the incremental predicate matches the batch rules.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Predictor/InputTokenTracker.swift Sources/SemicolynKit/Predictor/SecretArgDenylist.swift Tests/SemicolynKitTests/InputTokenTrackerTests.swift Tests/SemicolynKitTests/SecretArgDenylistTests.swift
git commit -m "feat(predictor): apply L4b denylist in tracker (drop secret values, reach-back-over bigram)"
```

---

## Task 5: Honor L4a line opt-out in the App learn flow (macOS-CI-only)

L3 and L4b already suppress *inside* the tracker (dropped tokens never reach `pendingLineTokens`). L4a is a line-level verdict the App must consult when it flushes the line — alongside the existing L1 `shouldLearnCommittedLine()`. Wire it in.

**Files:**
- Modify: `App/ConnectionViewModel.swift` (`observePredictorInput`, `:755`).

**Interfaces:**
- Consumes: `tracker.lineOptedOut` (Task 2).
- Produces: none (behavior change only).

**Design note — reading `lineOptedOut` at the right time.** The App's line-commit flush runs in a deferred closure at line commit. But `tracker.observe` for the CR byte already runs `resetLineContext`/Enter handling, which CLEARS `lineOptedOut` before the deferred closure fires. So capture `lineOptedOut` **synchronously**, at the moment the CR byte is observed, and close over it — the same pattern as the L1 `anchor`. Read it BEFORE `tracker.observe(bytes)` processes the line-ending Enter.

- [ ] **Step 1: Capture the opt-out before the tracker consumes the Enter, and gate learning on it**

In `App/ConnectionViewModel.swift`, in `observePredictorInput(_:)`, capture the flag before `tracker.observe`, and add it to the learn gate. Replace the body from the `passwordDetector.noteInput(bytes)` line through the line-commit loop with:

```swift
        passwordDetector.noteInput(bytes)
        // L4a: snapshot the line opt-out BEFORE the tracker processes a line-ending
        // Enter (which clears it), so the deferred flush sees the right value.
        let optedOut = tracker.lineOptedOut
        for committed in tracker.observe(bytes) {
            pendingLineTokens.append(committed)
        }
        let deadline = DispatchTime.now() + .milliseconds(40)
        if !scalars.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
                self?.passwordDetector.settleLine(scalars: scalars, from: anchor)
                self?.refreshPredictorSuggestions()
            }
        }
        for b in bytes where b == 0x0d || b == 0x0a {
            DispatchQueue.main.asyncAfter(deadline: deadline + .milliseconds(10)) { [weak self] in
                guard let self else { return }
                // Learn only if L1 confirms echo AND the line was not opted out (L4a).
                if !optedOut, self.passwordDetector.shouldLearnCommittedLine() {
                    for c in self.pendingLineTokens { self.engine?.record(c.token, after: c.previous) }
                }
                self.pendingLineTokens.removeAll(keepingCapacity: true)
                self.passwordDetector.resetLine()
            }
        }
        refreshPredictorSuggestions()
```

> Caveat: `optedOut` is captured once per `observePredictorInput` call. A line typed across multiple calls (the norm — one call per keystroke) sets `lineOptedOut` on the FIRST call (when the leading space arrives) and it persists in the tracker until the line's Enter. The Enter arrives in some later call; at that call's top, `tracker.lineOptedOut` is still true (not cleared until `tracker.observe` processes the Enter within that same call). So capturing it before `tracker.observe` in the Enter-bearing call reads the correct value. Confirm by reasoning: leading-space call sets it true; subsequent keystroke calls re-read true; the Enter call reads true before observing, then `observe` clears it. Correct.

- [ ] **Step 2: Verify via macOS CI (no local App build)**

The App tier does not build on Linux. Commit, push, and rely on the macOS CI job:

```bash
git add App/ConnectionViewModel.swift
git commit -m "feat(app): honor L4a leading-space line opt-out in predictor learn gate"
git push github feat/predictor-secret-exclusion-phase2
```

Then open a PR (CI triggers on PR here, not on branch push) or, if a PR is already open, `gh run watch --exit-status` the run. Expected: `linux-swift` stays green (no Kit change in this task), `macos` compiles the one-line gate change.

- [ ] **Step 3: Commit** (done in Step 2)

No extra commit unless CI required a fix.

---

## Task 6: Full-suite regression + spec bookkeeping

Run the whole Kit suite and record Phase 2 completion in the spec's cold-resume section.

**Files:**
- Modify: `docs/superpowers/specs/2026-07-04-predictor-secret-exclusion-design.md` (Phasing / Current-state note).

- [ ] **Step 1: Run the full Kit suite**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS — entire SemicolynKit + SeedKit suite green (the prior 35 predictor tests + the new L3/L4a/L4b tests).

- [ ] **Step 2: Record Phase 2 completion in the spec**

In `docs/superpowers/specs/2026-07-04-predictor-secret-exclusion-design.md`, under `## Phasing (implementation order — build-value first)`, mark phase 2 done by appending to its bullet:

```
2. **L3 paste + L4 context/leading-space** — cheap deterministic gates; close the
   pasted-secret gap the echo layers can't see. **IMPLEMENTED (Phase 2, plan
   `docs/superpowers/plans/2026-07-05-predictor-secret-exclusion-phase2-paste-context.md`):**
   L3 in `InputTokenTracker` (bracketed-paste state machine, fail-closed), L4a
   leading-space line opt-out, L4b `SecretArgDenylist` (drop secret values,
   reach-back-over bigram). Next: Phase 3 (L5 pattern extension + L6 graduation).
```

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-07-04-predictor-secret-exclusion-design.md
git commit -m "docs(spec): mark predictor secret-exclusion Phase 2 (L3+L4) implemented"
```

---

## Self-Review

**Spec coverage (L3 + L4 sections):**

| Spec requirement | Task |
|---|---|
| L3 `withinPaste` state machine on `ESC[200~`…`ESC[201~` | Task 1 |
| L3: token committed while `withinPaste` never learned | Task 1 |
| L3: unmatched open fails closed (suppress until close/reset); unmatched close ignored | Task 1 |
| L3 lives in `InputTokenTracker` | Task 1 |
| L4a leading-space ⇒ whole line never learned | Tasks 2 (flag) + 5 (App gate) |
| L4a space still sent to remote (only learning suppressed) | Task 2 (flag only; bytes pass through unchanged) |
| L4b flag→value: `-p`/`--password`/`-P`/`--pass`/`--token`/`--api-key`/`--secret`/`--passphrase`, case-insensitive, `=`-joined and space-separated | Task 3 |
| L4b `Authorization:` / `X-Api-Key:` header value | Task 3 |
| L4b `user:pass@host` whole-token drop | Task 3 |
| L4b suppresses only the value token, not the command | Tasks 3 + 4 |
| L4b conservative defaults, no user-editable rules v1 | Task 3 (typed table, no config) |
| Suppressed token dropped + reach-back-over bigram (`previous` not advanced) | Tasks 1 + 4 |
| Layers compose (L3/L4b per-token, L4a/L1 per-line) | Task 5 (App gate ANDs L4a with L1) |

**Placeholder scan:** no TBD/TODO/"handle edge cases"; every code step shows complete code; the App-tier step is explicitly CI-verified.

**Type consistency:** `withinPaste`, `lineOptedOut`, `escapeBuffer`, `sawLineStart`, `commitCurrent`, `resetLineContext`, `classify(_:into:)`, `handleByte(_:into:)`, `secretValueIndexes(in:)`, `isSecretValueToken(_:precededBy:)`, `secretFlags`, `secretHeaders`, `isUserPassAtHost` are used identically across Tasks 1–5. `CommittedToken` is unchanged (drop-entirely approach — no new field), so no App churn beyond the L4a gate.

**Fresh-eyes note:** Task 1's `testUnmatchedPasteCloseIsIgnored` has a corrected expectation baked into Step 3's note (a recognized exit marker is consumed, not a reset) — flagged inline so the implementer fixes the test before running, rather than discovering the mismatch.
