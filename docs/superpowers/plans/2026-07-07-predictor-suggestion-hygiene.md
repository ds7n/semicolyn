# Predictor Suggestion Hygiene Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the predictor from suggesting the shell prompt, suggesting on empty/short input, and suggesting after Enter; clear stale chips; and de-fragilize the input dispatch cascade.

**Architecture:** Two Linux-tested Kit changes (a `minPrefix` gate in `PredictorEngine.suggestions`; a `SuggestionConfig.minPrefix` knob) plus App-tier wiring in `ConnectionViewModel` (stop harvesting free output, guard refresh on printable input, clear chips on reset/accept, sequence the dispatch cascade). The App tier compiles only on macOS CI.

**Tech Stack:** Swift 6 SemicolynKit (strict-concurrency, `Sendable`), XCTest on Linux via the `semicolyn-dev` Docker image; SwiftUI App tier.

## Global Constraints

- SPDX header on every source file: `// SPDX-FileCopyrightText: 2026 True Positive LLC` + `// SPDX-License-Identifier: GPL-3.0-only`.
- Kit code: no `import UIKit`/`SwiftUI`; public types `Sendable`; typed args/returns.
- `minPrefix` default = **2**, applied ONLY on the no-preceding-token (from-scratch) path; the bigram next-token path (`after:` non-empty) is EXEMPT — `suggestions(forPrefix: "", after: "git")` must keep working (existing tests depend on it).
- Harvest source after Fix 1 = **typed-command echo only**; the App must not call `predictor.harvest(output:)` for free terminal output.
- App tier (`ConnectionViewModel.swift`) does NOT build on Linux — macOS CI is its only compile signal. Do NOT run `swift test` for App-only changes.
- Kit tests: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <Name>` (docker socket is sandbox-blocked → set `dangerouslyDisableSandbox: true` on those Bash calls).
- Conventional commits; branch `fix/predictor-suggestion-hygiene` (already created, spec already committed); squash-merge to `main`.

---

### Task 1: `minPrefix` gate in the engine (bugs 3 & 4)

**Files:**
- Modify: `Sources/SemicolynKit/Predictor/SeededSuggester.swift` (the `SuggestionConfig` struct, ~lines 8–21)
- Modify: `Sources/SemicolynKit/Predictor/PredictorEngine.swift` (`suggestions(forPrefix:after:)`, ~line 120)
- Test: `Tests/SemicolynKitTests/PredictorEngineTests.swift` (add cases)

**Interfaces:**
- Consumes: nothing new.
- Produces: `SuggestionConfig(topK:confidenceFloor:seedWeight:minPrefix:)` gains a `minPrefix: Int = 2` field; `PredictorEngine.suggestions(forPrefix:after:)` returns `[]` when there is NO usable `previous` AND `prefix.count < config.minPrefix`. The bigram (`after:` non-empty) path is exempt.

**CRITICAL — the gate is CONDITIONAL, not blanket.** The engine already supports empty-prefix next-token suggestions (`suggestions(forPrefix: "", after: "git")` → `["status", …]`) — a real feature with existing tests (`PredictorEngineTests` lines ~68–90). A blanket `guard prefix.count >= minPrefix` would BREAK those tests. Gate only the no-preceding-token path. Also: the engine's `record` takes a **String** (`e.record("git")`, `e.record("commit", after: "git")`), NOT a `[CommittedToken]` — match the existing tests in this file exactly.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/SemicolynKitTests/PredictorEngineTests.swift` (inside the existing `final class PredictorEngineTests`). Use the SAME `engine(config:)` helper and String-based `record` as the existing tests:

```swift
    // Min-prefix gate (bugs 3/4): no suggestions below the threshold on the FROM-SCRATCH
    // (no preceding token) path, even when the vocabulary would match. Default minPrefix 2.
    func testEmptyPrefixNoPreviousReturnsNoSuggestions() {
        var e = engine(config: SuggestionConfig(topK: 3))
        for _ in 0..<3 { e.record("git") }   // graduate via 3 nil occurrences
        XCTAssertEqual(e.suggestions(forPrefix: ""), [])
    }
    func testOneCharPrefixReturnsNoSuggestionsAtDefaultMinPrefix() {
        var e = engine(config: SuggestionConfig(topK: 3))
        for _ in 0..<3 { e.record("git") }
        XCTAssertEqual(e.suggestions(forPrefix: "g"), [])
    }
    func testTwoCharPrefixReturnsSuggestions() {
        var e = engine(config: SuggestionConfig(topK: 3))
        for _ in 0..<3 { e.record("git") }
        XCTAssertEqual(e.suggestions(forPrefix: "gi"), ["git"])
    }
    func testMinPrefixIsConfigurable() {
        var e = engine(config: SuggestionConfig(topK: 3, minPrefix: 1))
        for _ in 0..<3 { e.record("git") }
        XCTAssertEqual(e.suggestions(forPrefix: "g"), ["git"])   // 1-char allowed when minPrefix=1
    }
    // REGRESSION GUARD: the bigram (next-token) path must STILL work with an empty
    // prefix + a preceding token — the gate must not touch it.
    func testEmptyPrefixWithPreviousStillSuggests() {
        var e = engine(config: SuggestionConfig(topK: 3))
        for _ in 0..<3 { e.record("status") }
        for _ in 0..<3 { e.record("status", after: "git") }
        XCTAssertEqual(e.suggestions(forPrefix: "", after: "git"), ["status"])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PredictorEngineTests` (set `dangerouslyDisableSandbox: true`)
Expected: the 4 new tests FAIL — `testEmptyPrefixReturnsNoSuggestions` etc. return non-empty (currently no gate); `SuggestionConfig(... minPrefix:)` may not compile yet (`extra argument 'minPrefix'`).

- [ ] **Step 3: Add `minPrefix` to `SuggestionConfig`**

In `Sources/SemicolynKit/Predictor/SeededSuggester.swift`, change the struct + init:

```swift
public struct SuggestionConfig: Equatable, Sendable {
    /// Suggestion-row slot count.
    public var topK: Int
    /// Minimum learned occurrences for a token to count as a confident candidate.
    public var confidenceFloor: UInt32
    /// Thumb-on-the-scale multiplier applied to seed counts when blending.
    public var seedWeight: Double
    /// Minimum input-prefix length before any suggestion is offered. Below this,
    /// `PredictorEngine.suggestions` returns `[]` (no suggestions on empty/1-char
    /// input; also suppresses the post-Enter empty-prefix refresh).
    public var minPrefix: Int

    public init(topK: Int = 3, confidenceFloor: UInt32 = 2, seedWeight: Double = 0.5,
                minPrefix: Int = 2) {
        self.topK = topK
        self.confidenceFloor = confidenceFloor
        self.seedWeight = seedWeight
        self.minPrefix = minPrefix
    }
}
```

- [ ] **Step 4: Add the CONDITIONAL gate to `suggestions`**

In `Sources/SemicolynKit/Predictor/PredictorEngine.swift`, at the top of `suggestions(forPrefix:after:)`, add the gate BEFORE the existing `topK` guard. The gate applies ONLY when there is no usable preceding token — the bigram next-token path (non-empty `previous`) is exempt so `suggestions(forPrefix: "", after: "git")` keeps working:

```swift
    public func suggestions(forPrefix prefix: String, after previous: String? = nil) -> [String] {
        // Min-prefix floor on the FROM-SCRATCH path only. A usable `previous` means the
        // caller wants next-token (bigram) suggestions, which are valid with an empty
        // word-prefix; only the no-preceding-token case needs typed input (bugs 3/4).
        let hasUsablePrevious = (previous?.isEmpty == false)
        guard hasUsablePrevious || prefix.count >= config.minPrefix else { return [] }
        guard config.topK > 0 else { return [] }   // harvest path isn't otherwise capped
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PredictorEngineTests` (set `dangerouslyDisableSandbox: true`)
Expected: PASS — the 4 new tests plus all pre-existing `PredictorEngineTests` green.

- [ ] **Step 6: Run the full Kit suite (config change touches many call sites)**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test` (set `dangerouslyDisableSandbox: true`)
Expected: PASS — all tests green. (The defaulted `minPrefix` param keeps every existing `SuggestionConfig(...)` call site compiling.)

- [ ] **Step 7: Commit**

```bash
git add Sources/SemicolynKit/Predictor/SeededSuggester.swift Sources/SemicolynKit/Predictor/PredictorEngine.swift Tests/SemicolynKitTests/PredictorEngineTests.swift
git commit -m "feat(predictor): min-prefix gate on suggestions (fixes empty/1-char + post-Enter)

SuggestionConfig gains minPrefix (default 2); PredictorEngine.suggestions
returns [] below it. Kills suggestions on empty input (bug 3) and, since Enter
resets the prefix to empty, the post-Enter suggestion pop (bug 4)."
```

---

### Task 2: Harvest only typed-command echo — stop harvesting free output (bug 2)

**Files:**
- Modify: `App/ConnectionViewModel.swift` (raw-shell `output.onHarvestBytes` block ~lines 505–511; tmux pane harvest ~line 756; the `onHarvestBytes` teardown nil ~line 374 if it becomes dead)
- Test: `Tests/SemicolynKitTests/PredictorEngineTests.swift` (a Kit test pinning that un-typed "output" tokens are never suggested)

**Interfaces:**
- Consumes: nothing new.
- Produces: no new symbols. Behavioral: the App no longer calls `predictor?.harvest(output:)`.

**Note:** The App edits are macOS-CI-only (do NOT `swift test` them). The one Kit test proves the *engine* no longer surfaces a token that was never learned/typed — i.e. the harvest axis is the only thing that could have surfaced free output, and with the App no longer feeding it, an un-recorded token must not appear.

- [ ] **Step 1: Write the failing/guarding Kit test**

Add to `Tests/SemicolynKitTests/PredictorEngineTests.swift`:

```swift
    // Bug 2 (leak guard): a token that was neither typed/learned nor seeded must never
    // be suggested. After Fix 1 the App stops feeding output to `harvest`, so the only
    // way a token reaches suggestions is via `record` (typed) or the seed. This pins
    // that a never-recorded token is absent — a regression here would mean output is
    // leaking back into candidates.
    func testUnrecordedTokenIsNotSuggested() {
        var e = engine(config: SuggestionConfig(topK: 3))
        for _ in 0..<3 { e.record("git") }   // graduate the only recorded token (String API)
        // "gitprompt" was never recorded; a 2-char prefix that would match it must only
        // surface the recorded "git", never an un-recorded token.
        XCTAssertEqual(e.suggestions(forPrefix: "gi"), ["git"])
    }
```

(If a harvested-output test already exists in this file that feeds `harvest(...)`, leave it — it exercises the still-present `harvest` API for seed/other paths; this new test guards the App-path behavior.)

- [ ] **Step 2: Run to verify it passes already OR fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PredictorEngineTests` (set `dangerouslyDisableSandbox: true`)
Expected: PASS (this is a guard test — `git` is the only candidate; it documents the invariant). If it FAILS because `harvest` was implicitly seeding, that itself is informative — investigate before proceeding.

- [ ] **Step 3: Remove the raw-shell output-harvest call**

In `App/ConnectionViewModel.swift`, find the `output.onHarvestBytes` block (~lines 505–511) that currently reads (approximately):

```swift
        output.onHarvestBytes = { [weak self] bytes in
            guard let self else { return }
            self.passwordDetector.noteOutput(bytes)
            let harvestText = String(decoding: bytes, as: UTF8.self)
            Task { [predictor = self.predictor] in await predictor?.harvest(output: harvestText) }
        }
```

Change it to keep the password-prompt gate but DROP the harvest:

```swift
        output.onHarvestBytes = { [weak self] bytes in
            guard let self else { return }
            // Feed output to the password-prompt gate only. We deliberately no longer
            // harvest free terminal output as suggestion candidates — that pulled the
            // shell prompt (Starship) into suggestions. Suggestions now source from
            // typed-command echo (record) + seed only. (predictor-suggestion-hygiene spec, Fix 1.)
            self.passwordDetector.noteOutput(bytes)
        }
```

- [ ] **Step 4: Remove the tmux-pane output-harvest call**

In `App/ConnectionViewModel.swift`, find the tmux pane harvest (~line 756) that reads (approximately):

```swift
            let harvestText = String(decoding: bytes, as: UTF8.self)
            Task { [predictor = self.predictor] in await predictor?.harvest(output: harvestText) }
```

within the pane-bytes handler. Delete those two lines (the `harvestText` decode and the harvesting `Task`). Keep any `passwordDetector.noteOutput(bytes)` call in the same block if present. Read the surrounding block first to remove exactly the harvest lines and nothing else.

- [ ] **Step 5: Confirm no remaining `predictor?.harvest(` call sites in the App**

Run: `grep -rn "predictor?.harvest\|\.harvest(output" App/`
Expected: NO matches. If any remain, remove them the same way (harvest of free output is gone entirely).

- [ ] **Step 6: Commit**

```bash
git add App/ConnectionViewModel.swift Tests/SemicolynKitTests/PredictorEngineTests.swift
git commit -m "fix(predictor): harvest only typed echo, not free output (fixes prompt leak)

The output->harvest->suggest path pulled the Starship prompt (terminal output
redrawn each line) into suggestions. Drop it: keep passwordDetector.noteOutput
for the prompt gate, but no longer feed free output to predictor.harvest.
Suggestions now source from typed-command echo (record) + seed only."
```

---

### Task 3: Don't schedule a refresh for input-less chunks + clear chips on line reset (bug 4, finding A)

**Files:**
- Modify: `App/ConnectionViewModel.swift` (`observePredictorInput`, the Enter branch ~lines 968–984 and the coalesced-refresh block ~lines 989–995; `refreshPredictorSuggestions` ~line 998)

**Interfaces:**
- Consumes: `predictorVM.setSuggestions(_:)` (exists), `PredictorEngine.suggestions` min-prefix gate (Task 1).
- Produces: no new symbols.

**Note:** App-tier — macOS-CI-only. Read the current `observePredictorInput` (~lines 942–996) in full before editing so the guards land in the right blocks.

- [ ] **Step 1: Clear chips when a line commits (Enter)**

In `App/ConnectionViewModel.swift`, inside `observePredictorInput`, the Enter loop (`for b in bytes where b == 0x0d || b == 0x0a { ... }`) schedules the learn-commit. Add an immediate chip-clear at the top of that block, before the async learn hop, so chips vanish with the committed line:

```swift
        for b in bytes where b == 0x0d || b == 0x0a {
            predictorVM.setSuggestions([])   // line committed → clear stale chips immediately
            DispatchQueue.main.asyncAfter(deadline: deadline + .milliseconds(10)) { [weak self] in
                // ... existing learn-commit body unchanged ...
```

(Keep the existing learn-commit closure body exactly as-is.)

- [ ] **Step 2: Guard the coalesced refresh on printable input**

Still in `observePredictorInput`, wrap the coalesced-refresh scheduling block (the `refreshCoalescer.requestRefresh(...)` + the `asyncAfter` that calls `refreshPredictorSuggestions()`, ~lines 989–995) so it only runs when this chunk carried printable input:

```swift
        // Only recompute suggestions for chunks that carried printable input. An
        // Enter/control-only chunk (empty scalars) must not trigger a refresh — the
        // prefix just reset to empty and a refresh would surface stale/empty results.
        if !scalars.isEmpty {
            refreshCoalescer.requestRefresh(at: Date().timeIntervalSinceReferenceDate)
            DispatchQueue.main.asyncAfter(deadline: deadline + .milliseconds(5)) { [weak self] in
                guard let self else { return }
                if self.refreshCoalescer.isDue(at: Date().timeIntervalSinceReferenceDate) {
                    self.refreshPredictorSuggestions()
                }
            }
        }
```

- [ ] **Step 3: Make `refreshPredictorSuggestions` clear on a short prefix**

In `refreshPredictorSuggestions` (~line 998), short-circuit an empty/short prefix so it actively clears rather than querying:

```swift
    private func refreshPredictorSuggestions() {
        guard let predictor else { predictorVM.setSuggestions([]); return }
        let prefix = tracker.current, prev = tracker.previous
        // Mirror the engine's conditional min-prefix floor so a short from-scratch prefix
        // clears chips instead of leaving stale ones up. The bigram path (a usable
        // `prev`) is exempt — next-token suggestions are valid with an empty prefix.
        let hasUsablePrevious = (prev?.isEmpty == false)
        if !hasUsablePrevious, prefix.count < 2 { predictorVM.setSuggestions([]); return }
        Task { [weak self] in
            let raw = await predictor.suggestions(forPrefix: prefix, after: prev)
            let chips = predictorChips(current: prefix, suggestions: raw)
            await MainActor.run { self?.predictorVM.setSuggestions(chips) }
        }
    }
```

- [ ] **Step 4: Self-review**

Confirm: (a) Enter clears chips synchronously; (b) an Enter-only chunk does not schedule a refresh; (c) a short prefix clears chips. The literal `2` in Step 3 matches `SuggestionConfig.minPrefix`'s default — leave a comment noting they must stay in sync (a future config plumb-through is out of scope here).

- [ ] **Step 5: Commit**

```bash
git add App/ConnectionViewModel.swift
git commit -m "fix(predictor): no refresh on Enter/control chunks; clear chips on line reset

Guard the coalesced refresh on !scalars.isEmpty so an Enter/control-only chunk
never recomputes against the just-reset empty prefix (bug 4). Clear chips
synchronously on line commit and on a short prefix so stale chips don't linger
(finding A)."
```

---

### Task 4: Clear chips on accept; sequence the dispatch cascade (findings A/B/E, C/D)

**Files:**
- Modify: `App/ConnectionViewModel.swift` (`acceptSuggestion` ~line 1011; the dispatch cascade in `observePredictorInput` ~lines 960–995)

**Interfaces:**
- Consumes: `predictorVM.setSuggestions(_:)`, `passwordDetector.settleLine(...)`, `refreshPredictorSuggestions()`.
- Produces: no new symbols.

**Note:** App-tier — macOS-CI-only. This touches the SACRED keystroke path (`sendTerminalInput`→`observePredictorInput`). Preserve the 40ms echo-settle window and the coalescer's trailing-debounce semantics EXACTLY — only the ordering mechanism changes. Read lines 942–1016 in full first.

- [ ] **Step 1: Clear chips synchronously on accept**

In `acceptSuggestion(_:)` (~line 1011), add a synchronous clear right after the guard, before/after sending the suffix, so the accepted chip (and its stale siblings) vanish immediately instead of lingering until the async round-trip (findings B/E):

```swift
    func acceptSuggestion(_ s: String) {
        guard s.hasPrefix(tracker.current) else { return }
        let suffix = String(s.dropFirst(tracker.current.count))
        guard !suffix.isEmpty else { return }
        predictorVM.setSuggestions([])   // clear immediately; the echo round-trip repopulates from the new prefix
        sendTerminalInput(Array(suffix.utf8))
    }
```

(Match the existing body's exact send mechanism — read the current `acceptSuggestion` and keep whatever it uses to emit the suffix; only ADD the `setSuggestions([])` line. Do not change how bytes are sent.)

- [ ] **Step 2: Sequence the echo-settle → refresh ordering (findings C/D)**

Currently three hops fire off one `deadline`: echo-settle at +40ms, learn-commit at +50ms, refresh at +45ms. Fold the refresh INTO the echo-settle hop so refresh always observes post-settle state, in program order on the main actor. Replace the two separate `asyncAfter` blocks (the `!scalars.isEmpty` echo-settle at ~961–967 and the coalesced-refresh block from Task 3 Step 2) with a single ordered hop:

```swift
        if !scalars.isEmpty {
            refreshCoalescer.requestRefresh(at: Date().timeIntervalSinceReferenceDate)
            DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
                guard let self else { return }
                // 1) settle echo against the grid (L1), THEN
                self.passwordDetector.settleLine(scalars: scalars, from: anchor)
                // 2) recompute suggestions in the same main-actor hop, in program order,
                //    so the refresh always reflects post-settle state (findings C/D — no
                //    fragile inter-hop wall-clock offsets). Trailing-debounce preserved:
                //    only recompute if no newer keystroke arrived.
                if self.refreshCoalescer.isDue(at: Date().timeIntervalSinceReferenceDate) {
                    self.refreshPredictorSuggestions()
                }
            }
        }
```

Remove the now-obsolete standalone refresh `asyncAfter` (the `deadline + .milliseconds(5)` block) and the standalone echo-settle `asyncAfter` (the `deadline` block that only called `settleLine`) — they are replaced by the single hop above. Leave the learn-commit hop (the Enter branch's `deadline + .milliseconds(10)`) untouched; it remains a separate ordered step keyed after settle, which is correct.

- [ ] **Step 3: Self-review the sacred-path invariants**

Confirm: (a) the 40ms echo-settle window is unchanged (`deadline` = `now + 40ms`); (b) `settleLine` still runs with the same `scalars`/`anchor` captured per-call; (c) the coalescer trailing-debounce is preserved (`requestRefresh` on each printable chunk, `isDue` checked in the hop); (d) no refresh runs for empty-`scalars` chunks; (e) chips clear on Enter (Task 3) and accept (Step 1). Note in a comment that `observePredictorInput` + the coalescer are `@MainActor` (the VM is `@MainActor`; only caller is `sendTerminalInput`), so no lock is needed (finding D).

- [ ] **Step 4: Commit**

```bash
git add App/ConnectionViewModel.swift
git commit -m "fix(predictor): clear chips on accept; sequence echo-settle->refresh in one hop

Accept clears chips synchronously (findings B/E: no stale-until-roundtrip, no
tap-a-stale-chip no-op). Fold the suggestion refresh into the 40ms echo-settle
main-actor hop so it runs in program order after settle, removing the fragile
+5/+10ms wall-clock offsets (findings C/D). @MainActor throughout, no lock
needed. Echo-settle window + coalescer debounce semantics unchanged."
```

---

### Task 5: Amend the predictor spec index / cross-refs (docs)

**Files:**
- Modify: `docs/ARCHITECTURE.md` (predictor spec index) — add the new spec if the index lists predictor specs; otherwise skip.

**Interfaces:** none.

- [ ] **Step 1: Check whether the architecture doc indexes predictor specs**

Run: `grep -n "predictor" docs/ARCHITECTURE.md | head`
If there is a predictor spec list, add a line referencing `2026-07-07-predictor-suggestion-hygiene-design.md`. If not, SKIP this task entirely (no doc to update) — do not invent an index.

- [ ] **Step 2: Commit (only if a change was made)**

```bash
git add docs/ARCHITECTURE.md
git commit -m "docs: index predictor suggestion-hygiene spec"
```

---

## Self-Review

**Spec coverage:**
- Fix 1 (harvest typed echo only, bug 2) → Task 2. ✅
- Fix 2 (minPrefix gate, bugs 3/4) → Task 1. ✅
- Fix 3 (no refresh on input-less chunks, bug 4) → Task 3 Step 2. ✅
- Fix 4 (clear chips on reset/accept, finding A/B/E) → Task 3 Steps 1&3 + Task 4 Step 1. ✅
- Fix 5 (sequence dispatch cascade, findings C/D) → Task 4 Step 2. ✅
- Testing (engine gate + harvest-source Kit tests) → Task 1 Step 1, Task 2 Step 1. ✅

**Placeholder scan:** No TBD/TODO. Task 5 has a legitimate conditional ("skip if no index") — that's a real branch, not a placeholder. Every code step shows full code. App-tier steps note they are macOS-CI-verified (no local run), which is the repo convention, not a missing test.

**Type consistency:** `SuggestionConfig(... minPrefix:)` default 2 (Task 1) matches the literal `2` guard in `refreshPredictorSuggestions` (Task 3 Step 3, with a sync-note). `predictorVM.setSuggestions([])`, `refreshPredictorSuggestions()`, `passwordDetector.settleLine(scalars:from:)`, `refreshCoalescer.requestRefresh(at:)`/`isDue(at:)` used consistently with the existing code read from the file.

**Note on `record`/`CommittedToken`/`engine(...)` helpers:** Task 1 & 2 tests use the SAME `engine(config:)` helper, `CommittedToken(text:)`, and `record(_:echoConfirmed:optedOut:)` shapes as the existing tests at `PredictorEngineTests.swift:151–191`. The implementer must match the existing usage verbatim; if any signature differs, follow the existing tests, not this plan's approximation.
