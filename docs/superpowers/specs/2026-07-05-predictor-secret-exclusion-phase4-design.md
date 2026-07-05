<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Predictor secret-exclusion — Phase 4 design (L7 storage + forget-last-line + panic-purge)

**Date:** 2026-07-05
**Parent spec:** [`2026-07-04-predictor-secret-exclusion-design.md`](2026-07-04-predictor-secret-exclusion-design.md) — the 8-layer defense-in-depth design. This document is the Phase 4 slice (L7 + the two forget tools).
**Predecessors shipped:** Phase 1 (L1 echo + `EchoOracle`, PR #43), Phase 2 (L3 paste + L4 context, PR #44), Phase 3 (L5 patterns + L6 graduation, PR #45). Full Kit suite 1008/0 at Phase 3 merge.

## Governing reframe (unchanged)

Predictor, not scanner. A false positive is one skipped word; a false negative is a leaked credential. Exclusion wins ties; filter aggressively. L7 is the *structural* backstop: it assumes L1–L6 detection **failed** on some token and constrains what persistence can even hold, so a missed secret degrades from "recoverable plaintext" to "an anonymous increment in a probabilistic counter."

## Scope

**In scope:**
1. **L7 confidence tiering** — a graduating token (L6) carries a `high`/`low` confidence; low-confidence tokens store only the lossy CMS count, never the literal in the `PrefixIndex`, so they can never be reconstructed or offered as a literal completion.
2. **Forget-last-line** — a lightweight in-the-moment action that drops the most-recent line's still-pending (un-graduated) tokens from the ephemeral L6 tier.
3. **Panic-purge** — a nuclear reset in a new Privacy Settings screen that wipes all user-derived learned state, keeping the bundled seed.

**Out of scope (YAGNI, deferred):** L2 (mosh prediction-engine echo state), L8 (sync-boundary firewall), confidence *decay* over time, surgically forgetting an already-graduated token.

## Decisions locked (from the 2026-07-05 brainstorm)

| Decision | Choice |
|---|---|
| Where confidence is computed | `CommittedToken` carries the tracker-known verdict (`optedOut`); the App folds in the late-arriving L1 echo verdict at Enter; the engine folds in L5. Engine derives the final `LearnConfidence`. |
| Verdict assembly timing | Tracker stamps `optedOut` at commit; App passes `echoConfirmed` (per-line, ~50 ms post-`observe`) to `record`; engine reads L5 via `TokenFilter` inside `record`. |
| Low-confidence storage split | `storeLiteral: Bool` flag on `RollingVocabulary.record` (and the bigram mirror). `false` skips `PrefixIndex.insert` but still does `CountMinSketch.add`. |
| Forget-last-line tracking | `GraduationTier` records a per-line token list (`beginLine()` boundary marker + `lastLineTokens`); `forgetLastLine()` reverses that line's still-pending increments. |
| Panic-purge home | New second top-level Settings row → `PrivacySettingsView` → Predictor section (there is **no** pre-existing predictor Settings screen; incognito is a per-host Host-Editor toggle). |
| Forget-last-line surface | Contextual eraser affordance on `PredictorStripView`, visible while the strip is showing; tap → forget + brief toast. |

## Current state (grounding — verified against the code, 2026-07-05)

- **`PredictorEngine.record(_:count:after:)`** guards on `filter.excludes`, then `graduation.admit(...)` → for each returned `GraduatedOccurrence` writes `learned.unigram.record` + (if `previous` not excluded) `learned.bigram.record`. `record` today has no confidence signal.
- **`GraduationTier.admit(token:previous:count:) -> [GraduatedOccurrence]`** — ephemeral, never persisted. Graduates iff `distinctContexts >= threshold || (contexts[nil] ?? 0) >= threshold`. `GraduatedOccurrence` carries `(token, previous, count)` — **no confidence field**.
- **`RollingVocabulary.record(_:count:)`** does `index.insert(token)` + `today.add(token, count:)` together. `IndexedSketch.candidates(forPrefix:)` reads `index.matching(prefix:)` first, then estimates counts — **a token absent from `index` can never be returned**. `index` and the sketches serialize as independent length-prefixed sub-blobs.
- **`LearnedState`** = `unigram: RollingVocabulary` + `bigram: RollingBigramVocabulary`. **`LearnedStore`** persists both to one atomic `learned.sketch` under `.completeFileProtection` on iOS; `load()` is fail-soft to `.empty`. No `delete()` method today.
- **`CommittedToken`** = `(token, previous)`. `InputTokenTracker` latches `lastCommittedLineOptedOut` (L4a) at Enter.
- **App capture site** `ConnectionViewModel.observePredictorInput` computes the per-line echo verdict `shouldLearnCommittedLine()` ~50 ms after `observe` (grid-settle window) and reads the opt-out latch; at Enter it loops `engine?.record(c.token, after: c.previous)`.
- **`SettingsView`** has exactly one row (Appearance → `ThemePickerView`). The seed (`SeedStore`) is bundled app content, loaded read-only.

---

## L7 — Confidence hand-off (L6 → L7)

### Types

```swift
/// The privacy confidence a token graduates with — decides whether its literal is
/// persisted (high) or only its lossy frequency count (low).
public enum LearnConfidence: Sendable, Equatable { case high, low }

/// A token committed on the input line, plus the tracker-local verdict known at
/// commit time. The App folds in the late-arriving echo verdict when it records.
public struct CommittedToken: Equatable, Sendable {
    public let token: String
    public let previous: String?
    public let optedOut: Bool   // L4a: the line began with a leading space
}

/// One occurrence to persist on graduation, now carrying the confidence that
/// graduated it so backfilled occurrences persist at the correct tier.
public struct GraduatedOccurrence: Equatable, Hashable, Sendable {
    public let token: String
    public let previous: String?
    public let count: UInt32
    public let confidence: LearnConfidence
}
```

### `record` signature (backward-compatible)

```swift
public mutating func record(_ token: String, count: UInt32 = 1,
                            after previous: String? = nil,
                            echoConfirmed: Bool = true,   // App passes the per-line L1 verdict
                            optedOut: Bool = false)        // carried on CommittedToken
```

Defaults preserve today's behavior, so existing engine tests and callers keep compiling; only the App capture site and new confidence tests set the params.

### Confidence derivation (in the engine, inside `record`)

The engine combines the three signals it can now see:

- **`.high`** ⟺ `echoConfirmed && !optedOut && !filter.isPatternAdjacent(token)`
- **`.low`** ⟺ the token graduates on count but *any* of those signals is unsure/flagged (`!echoConfirmed`, `optedOut`, or pattern-adjacent).

`filter.isPatternAdjacent(_:)` is a **new read-only** predicate on `TokenFilter` for the *soft* L5 signal — the credential-format/JWT/PEM/entropy hits that a token can pass through `filter.excludes` (the hard drop at the top of `record`) yet still not deserve a persisted literal. `excludes` continues to hard-drop the worst hits before any of this runs; `isPatternAdjacent` is strictly the softer tier.

The derived `LearnConfidence` rides through `admit` onto `GraduatedOccurrence.confidence`, so the graduation backfill persists every accumulated occurrence at the tier that graduated the token. `GraduationTier.admit` gains a `confidence:` parameter and stamps it onto the occurrences it returns (both the deferred backfill and the post-graduation passthrough).

---

## L7 — Low-confidence storage split (structural core)

### `RollingVocabulary.record` gains `storeLiteral`

```swift
public mutating func record(_ token: String, count: UInt32 = 1, storeLiteral: Bool = true) {
    guard !token.isEmpty, count > 0 else { return }
    if storeLiteral { index.insert(token) }
    today.add(token, count: count)
}
```

`RollingBigramVocabulary.record` gets the mirror flag (same `storeLiteral` semantics — skip its literal index, still increment its sketch).

### Engine wiring

```swift
for occ in graduation.admit(..., confidence: derivedConfidence) {
    let storeLiteral = (occ.confidence == .high)
    learned.unigram.record(occ.token, count: occ.count, storeLiteral: storeLiteral)
    if let prev = occ.previous, !filter.excludes(prev) {
        learned.bigram.record(previous: prev, next: occ.token,
                              count: occ.count, storeLiteral: storeLiteral)
    }
}
```

### Properties (verified against the code)

- A low-confidence token is **never in `index`** → `IndexedSketch.candidates(forPrefix:)` can never return it → it is never offered as a literal completion, on either axis. This is the L7 guarantee.
- Its CMS count still contributes to frequency and may inflate a hash-colliding token's estimate — the pre-existing CMS lossy-aggregate property, not a new leak.
- Serialization is untouched: `index` and the sketches serialize as independent sub-blobs; a low-confidence token is simply absent from the serialized `index`, so it cannot be reconstructed from disk.
- The bigram axis is treated **symmetrically**: low-confidence → count-only, no literal. The adjacency count survives (frequency signal) but the pair cannot be completed. (Chosen over "skip bigram entirely" to preserve ranking signal without reconstructability.)

---

## Forget-last-line

### Kit primitive — `GraduationTier` per-line grouping

```swift
// tokens admitted since the last beginLine(), newest line only (bounded by maxTracked)
private var lastLineTokens: [(token: String, previous: String?, count: UInt32)] = []

/// Mark a line boundary — the App calls this at each Enter, before recording the
/// line's tokens, so lastLineTokens captures exactly this line's admits.
public mutating func beginLine() { lastLineTokens.removeAll(keepingCapacity: true) }

// admit(...) additionally appends its (token, previous, count) to lastLineTokens
// for still-pending tokens, so a subsequent forgetLastLine can reverse it.

/// Reverse the current line's still-pending increments. Graduated tokens are
/// untouched by design — a graduated token is already in the persistent store and
/// not surgically reachable; L7 confidence tiering means a low-confidence one has
/// no literal to leak anyway. Panic-purge is the fallback for graduated state.
public mutating func forgetLastLine() {
    for entry in lastLineTokens {
        guard var contexts = pending[entry.token] else { continue }  // graduated → skip
        let cur = contexts[entry.previous] ?? 0
        let newVal = cur - min(cur, entry.count)
        if newVal == 0 { contexts[entry.previous] = nil } else { contexts[entry.previous] = newVal }
        if contexts.isEmpty {
            pending[entry.token] = nil
            pendingOrder.removeAll { $0 == entry.token }
        } else {
            pending[entry.token] = contexts
        }
    }
    lastLineTokens.removeAll(keepingCapacity: true)
}
```

`PredictorEngine` exposes passthroughs `beginLine()` and `forgetLastLine()`.

### App wiring

- At Enter, `ConnectionViewModel` calls `engine.beginLine()` immediately before the `record` loop, so `lastLineTokens` captures this line's admits precisely.
- A `forgetLastLine()` method on the view-model → `engine.forgetLastLine()` + a brief toast.

### UI surface

An eraser affordance (e.g. `Image(systemName: "eraser")`/`"delete.left"`) on `PredictorStripView`, visible while the strip is showing (i.e. just after typing a line). Tap → `vm.forgetLastLine()` → transient toast "Last line forgotten."

### Correctness bound (documented)

Forget only reaches **still-pending** tokens. A freshly-typed password is pending by construction (it hasn't recurred across N distinct contexts), so this is exactly the "oops, I just typed a secret" case and the delete is clean — no CMS decrement, no `PrefixIndex` surgery. A token that *graduated on this very line* (its Nth distinct context happened to land here) is already flushed to the persistent store and is out of reach of the surgical tool; that required N legitimate distinct contexts, which a one-off secret won't have, and panic-purge remains the fallback.

---

## Panic-purge

### Kit

```swift
// PredictorEngine
public mutating func purgeLearned() {
    learned = .empty          // fresh unigram + bigram (index + all sketches gone)
    output.clear()            // ephemeral harvested output tokens
    graduation.reset()        // ephemeral L6 tier
    // seed is a `let` — untouched by construction
}
```

### App / store

```swift
// LearnedStore — delete the on-disk sketch (tolerate "no such file")
public func delete() throws { /* FileManager.removeItem(fileURL), ignore fileNoSuchFile */ }

// ConnectionViewModel.panicPurge()
engine?.purgeLearned()                                     // running session, immediate
try? AppStores.shared.predictorLearnedStore().delete()     // on disk
// next flushPredictor() writes a fresh-empty file; a mid-session purge is complete now
```

### UI surface

A new second top-level `SettingsView` row → `PrivacySettingsView`:

```
Settings
  Appearance
  Privacy                       ← new NavigationLink
    ┌ Predictor ──────────────────────────────┐
    │ [ Forget everything the predictor learned ]│  ← destructive-role button
    │ Keeps the built-in suggestions.            │  ← footer
    └────────────────────────────────────────────┘
        tap → confirmationDialog("This can't be undone") → purge
             → "Predictor memory cleared" confirmation
```

Destructive-role button + `confirmationDialog`; footer clarifies the bundled seed suggestions remain. Establishes the Privacy screen the settings-tree spec anticipates.

### Wipe completeness

On device the file lives under `.completeFileProtection`, so `removeItem` is a true delete. `purgeLearned()` covers the running session, so the purge is effective immediately, not merely on next launch.

---

## Task decomposition (one writing-plans slice, phased)

| # | Task | Tier | Verified by |
|---|------|------|-------------|
| 1 | `LearnConfidence` enum + `CommittedToken.optedOut` + `record` `echoConfirmed`/`optedOut` params + `GraduatedOccurrence.confidence` + `GraduationTier.admit` confidence param | Kit | `swift test` |
| 2 | `RollingVocabulary` + `RollingBigramVocabulary` `storeLiteral` split | Kit | `swift test` |
| 3 | Engine confidence derivation + `storeLiteral` wiring + `TokenFilter.isPatternAdjacent` | Kit | `swift test` |
| 4 | `GraduationTier` per-line grouping (`beginLine`/`lastLineTokens`) + `forgetLastLine()` + engine passthroughs | Kit | `swift test` |
| 5 | `PredictorEngine.purgeLearned()` + `LearnedStore.delete()` | Kit | `swift test` |
| 6 | App: capture-site plumbing (`echoConfirmed`/`optedOut`/`beginLine` at the Enter path) | App | **macOS CI** |
| 7 | App: forget-strip eraser UI + toast | App | **macOS CI** |
| 8 | App: `PrivacySettingsView` + panic-purge wiring + confirm dialog | App | **macOS CI** |

Kit tasks (1–5) are the fast loop; App tasks (6–8) are gated by the macOS CI job (real SwiftUI + `ConnectionViewModel`/`AppStores` wiring the per-task reviewers can't build locally).

## Testing (per the repo's testing standards — real tests, EP + BVA, observable assertions, specific negatives)

Security-critical:

- **Low-confidence never completes (load-bearing L7 test):** record a token `.low`, then assert `suggestions(forPrefix:)` never returns it **while its CMS count is non-zero** — proves the `index`-skip, not mere absence.
- **High-confidence still completes** — the positive partner (proves the split didn't break the feature).
- **Confidence mapping (BVA over the boolean combination):** `echoConfirmed=false` → `.low`; `optedOut=true` → `.low`; pattern-adjacent → `.low`; all-clear → `.high`. Assert the specific tier, not "it recorded."
- **`forgetLastLine` removes a pending contribution:** after forgetting, the token no longer graduates on what would have been its Nth context. Specific negative: a token that **graduated this line is NOT altered** by `forgetLastLine`.
- **`purgeLearned`:** learned suggestions vanish, but a **seed-backed prefix still suggests** — proves the seed survives the wipe.
- **`LearnedStore.delete`:** deleting then `load()` returns `.empty` (not a throw); deleting a non-existent file does not throw (idempotent).

Boundary/negative for the storage split:

- `storeLiteral: false` with a non-empty token increments the sketch (estimate rises) but leaves `index.matching(prefix:)` unable to surface it.
- Empty token / zero count is still a no-op under either flag.

## Process notes (carried from the Phase 3 controller)

- The **Docker socket is sandbox-blocked for subagents** — implementers must flag tooling errors rather than misdiagnose them as code bugs. The **controller** runs `swift test` via `dangerouslyDisableSandbox: true` and commits on an agent's behalf if it stalls uncommitted (a Phase-3 failure mode: correct files written, commit stuck retrying the blocked Docker run — check `git log` + file mtimes).
- Engine suggestion tests must respect `confidenceFloor = 2` (a count-1 backfilled entry won't surface). `Set(x)` in example/test code needs `Hashable` elements.
- **macOS CI gates this phase again** (Phase 3 was pure Kit and did not need it). Expect the App tasks (6–8) to be validated only by the macOS job.

## Relationships

- Parent: [`2026-07-04-predictor-secret-exclusion-design.md`](2026-07-04-predictor-secret-exclusion-design.md) (the 8-layer design; L7 is the structural backstop, L8 the future sync firewall).
- Forget-last-line is cheap **precisely because L6 defers learning** — a regretted line's tokens are still ungraduated in the ephemeral tier, so forgetting is a clean ephemeral delete (no lossy CMS decrement).
- Panic-purge keeps `SeedStore` (bundled, no secret) and wipes only user-derived state — the honest complete answer to "did it learn my password?"
