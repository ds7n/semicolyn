<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Predictor Secret-Exclusion Phase 4 (L7 + forget tools) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add L7 confidence-tiered non-recoverable storage plus the two forget tools (surgical forget-last-line + nuclear panic-purge) so a secret that slips past L1–L6 leaves at most a lossy count on disk, never a recoverable literal.

**Architecture:** A graduating token (L6) now carries a `LearnConfidence` derived from the echo verdict (App), the leading-space opt-out (App latch), and a soft L5 pattern-adjacency signal (`TokenFilter`). Low-confidence tokens increment the CountMinSketch but are withheld from the `PrefixIndex` (a `storeLiteral: Bool` flag on `RollingVocabulary.record`), so they contribute to frequency yet can never be completed or reconstructed. Forget-last-line reverses the current line's still-pending increments in the ephemeral `GraduationTier`; panic-purge resets the engine's user-derived state and deletes `learned.sketch`, keeping the bundled seed.

**Tech Stack:** Swift 6 (SemicolynKit, Linux-tested via `swift test`), SwiftUI (App tier, macOS-CI-gated), XCTest.

## Global Constraints

- **Two tiers:** `Sources/SemicolynKit/` = pure logic, Swift 6 strict-concurrency, `Sendable`, NO `import UIKit`/`SwiftUI`/`CryptoKit`, Linux-tested with `swift test`. `App/` = SwiftUI, macOS-CI-only (invisible to `swift test`).
- **Every source file carries an SPDX header:** `// SPDX-FileCopyrightText: 2026 True Positive LLC` + `// SPDX-License-Identifier: GPL-3.0-only`.
- **Conventional commits** (`feat:`/`test:`/`refactor:`/…); this is a feature branch (`feat/predictor-secret-exclusion-phase4`); squash-merge to `main`.
- **Tests must be real** (repo testing standards): equivalence-partitioning + boundary values, assert observable values (no tautologies), a negative test asserts the *specific* failure. Match rigor to risk — L7 storage is security-critical (adversarial + BVA).
- **Kit test command (controller runs it; Docker socket is sandbox-blocked for subagents):**
  `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <Suite>`
  Full suite: drop `--filter`. Implementer subagents must FLAG a Docker/tooling error rather than misdiagnose it as a code bug; the controller runs `swift test` via `dangerouslyDisableSandbox: true` and commits on the agent's behalf if it stalls uncommitted.
- **`confidenceFloor = 2`** in `SuggestionConfig`: a count-1 backfilled entry will NOT surface in suggestions — engine suggestion tests must record enough to clear the floor (record count ≥ 2, or the same token twice).
- **App tasks (7–9) are macOS-CI-gated** — they do NOT compile under `swift test`. Verify via the macOS CI job (`gh run …`), not locally.

## Design deviation from the spec (resolved during planning — flag on review)

The spec put `optedOut` on `CommittedToken`. Grounding the code showed `InputTokenTracker.commitCurrent` fires *mid-line* (space-committed tokens) **before** the leading-space opt-out is known — opt-out latches only at Enter (`lastCommittedLineOptedOut`). So a per-token `CommittedToken.optedOut` can't be populated correctly at commit time. **Resolution:** `CommittedToken` is left unchanged; the App passes `optedOut` to `record(...)` directly from the `tracker.lastCommittedLineOptedOut` latch it already reads at Enter (line 774 of `ConnectionViewModel.swift`). This matches the spec's *intent* (tracker-known verdict → App folds in echo → engine folds in L5) while being faithful to where the signal actually becomes available. The `LearnConfidence` derivation is unchanged.

## File structure

**Kit (Linux-tested):**
- `Sources/SemicolynKit/Predictor/GraduationTier.swift` — MODIFY: `LearnConfidence` enum; `GraduatedOccurrence.confidence`; `admit(...confidence:)`; `beginLine()`/`lastLineTokens`/`forgetLastLine()`.
- `Sources/SemicolynKit/Predictor/RollingVocabulary.swift` — MODIFY: `record(_:count:storeLiteral:)`.
- `Sources/SemicolynKit/Predictor/RollingBigramVocabulary.swift` — MODIFY: `record(previous:next:count:storeLiteral:)`.
- `Sources/SemicolynKit/Predictor/TokenFilter.swift` — MODIFY: `isPatternAdjacent(_:)`.
- `Sources/SemicolynKit/Predictor/PredictorEngine.swift` — MODIFY: confidence derivation + `storeLiteral` wiring in `record`; `beginLine()`/`forgetLastLine()`/`purgeLearned()` passthroughs.
- `Sources/SemicolynKit/Predictor/LearnedStore.swift` — MODIFY: `LearnedStore.delete()`.

**Tests (Linux-tested):**
- `Tests/SemicolynKitTests/Predictor/GraduationTierTests.swift` — extend (confidence, forget-last-line).
- `Tests/SemicolynKitTests/Predictor/RollingVocabularyTests.swift` — extend (`storeLiteral`).
- `Tests/SemicolynKitTests/Predictor/TokenFilterTests.swift` — extend (`isPatternAdjacent`).
- `Tests/SemicolynKitTests/Predictor/PredictorEngineTests.swift` — extend (low/high completion, purge).
- `Tests/SemicolynKitTests/Predictor/LearnedStoreTests.swift` — extend (`delete`).

**App (macOS-CI-gated):**
- `App/ConnectionViewModel.swift` — MODIFY: capture-site plumbing (`echoConfirmed`/`optedOut`/`beginLine`); `forgetLastLine()`/`panicPurge()` VM methods.
- `App/Keybar/PredictorStripView.swift` — MODIFY: eraser affordance.
- `App/SettingsView.swift` — MODIFY: Privacy row.
- `App/PrivacySettingsView.swift` — CREATE: predictor panic-purge screen.

> **Task order note:** the exact filenames/line numbers cited (e.g. `PredictorEngineTests.swift`) are the existing test files; if a referenced test suite lives in a differently-named file, add to the file that already tests that type — do not create a duplicate suite.

---

### Task 1: `LearnConfidence` + confidence on `GraduatedOccurrence`/`admit`

**Files:**
- Modify: `Sources/SemicolynKit/Predictor/GraduationTier.swift`
- Test: `Tests/SemicolynKitTests/Predictor/GraduationTierTests.swift`

**Interfaces:**
- Produces:
  - `public enum LearnConfidence: Sendable, Equatable { case high, low }`
  - `GraduatedOccurrence` gains `public let confidence: LearnConfidence` (init adds `confidence:`).
  - `admit(token:previous:count:confidence:) -> [GraduatedOccurrence]` — the passed `confidence` is stamped onto every returned occurrence (backfill and passthrough alike).

- [ ] **Step 1: Write the failing test**

Add to `GraduationTierTests.swift`:

```swift
func testAdmitStampsConfidenceOnGraduation() {
    var tier = GraduationTier(threshold: 3)
    // Three distinct contexts → graduates; every backfilled occurrence carries .low.
    _ = tier.admit(token: "deploy", previous: "run", count: 1, confidence: .low)
    _ = tier.admit(token: "deploy", previous: "make", count: 1, confidence: .low)
    let flushed = tier.admit(token: "deploy", previous: "just", count: 1, confidence: .low)
    XCTAssertEqual(flushed.count, 3)
    XCTAssertTrue(flushed.allSatisfy { $0.confidence == .low })
    XCTAssertEqual(Set(flushed.map(\.previous)), ["run", "make", "just"])
}

func testAdmitPostGraduationPassesThroughConfidence() {
    var tier = GraduationTier(threshold: 1)
    _ = tier.admit(token: "ls", previous: nil, count: 1, confidence: .high)  // graduates now
    let after = tier.admit(token: "ls", previous: "sudo", count: 1, confidence: .high)
    XCTAssertEqual(after, [GraduatedOccurrence(token: "ls", previous: "sudo", count: 1, confidence: .high)])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter GraduationTierTests`
Expected: FAIL — `admit(...confidence:)` and `GraduatedOccurrence.confidence` do not exist (compile error).

- [ ] **Step 3: Write minimal implementation**

In `GraduationTier.swift`, add the enum above `GraduatedOccurrence`:

```swift
/// The privacy confidence a token graduates with — decides whether its literal is
/// persisted (high) or only its lossy frequency count (low). L6 hands this to L7.
public enum LearnConfidence: Sendable, Equatable { case high, low }
```

Update `GraduatedOccurrence`:

```swift
public struct GraduatedOccurrence: Equatable, Hashable, Sendable {
    public let token: String
    public let previous: String?
    public let count: UInt32
    public let confidence: LearnConfidence
    public init(token: String, previous: String?, count: UInt32, confidence: LearnConfidence) {
        self.token = token; self.previous = previous; self.count = count; self.confidence = confidence
    }
}
```

Update `admit` signature and both return sites:

```swift
public mutating func admit(token: String, previous: String?, count: UInt32,
                           confidence: LearnConfidence) -> [GraduatedOccurrence] {
    if graduated.contains(token) {
        return [GraduatedOccurrence(token: token, previous: previous, count: count, confidence: confidence)]
    }
    if pending[token] == nil {
        evictIfNeeded()
        pending[token] = [:]
        pendingOrder.append(token)
    }
    pending[token]![previous, default: 0] += count

    let contexts = pending[token]!
    let graduates = contexts.count >= threshold || (contexts[nil] ?? 0) >= UInt32(threshold)
    guard graduates else { return [] }
    let flushed = contexts.map {
        GraduatedOccurrence(token: token, previous: $0.key, count: $0.value, confidence: confidence)
    }
    graduated.insert(token)
    pending[token] = nil
    pendingOrder.removeAll { $0 == token }
    return flushed
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter GraduationTierTests`
Expected: PASS (all `GraduationTierTests`, including migrated pre-existing ones — see Step 5).

- [ ] **Step 5: Fix pre-existing call sites in the test suite**

Every existing `admit(...)` call in `GraduationTierTests.swift` now needs a `confidence:` arg. Add `confidence: .high` to each (they test graduation mechanics, not confidence; `.high` is the neutral choice). Re-run Step 4 until green.

- [ ] **Step 6: Commit**

```bash
git add Sources/SemicolynKit/Predictor/GraduationTier.swift Tests/SemicolynKitTests/Predictor/GraduationTierTests.swift
git commit -m "feat(predictor): LearnConfidence on GraduatedOccurrence/admit (L7 hand-off)"
```

---

### Task 2: `storeLiteral` split on `RollingVocabulary`

**Files:**
- Modify: `Sources/SemicolynKit/Predictor/RollingVocabulary.swift:65-69`
- Test: `Tests/SemicolynKitTests/Predictor/RollingVocabularyTests.swift`

**Interfaces:**
- Produces: `RollingVocabulary.record(_ token: String, count: UInt32 = 1, storeLiteral: Bool = true)` — `false` skips `index.insert` but still does `today.add`.

- [ ] **Step 1: Write the failing test**

Add to `RollingVocabularyTests.swift`:

```swift
func testRecordCountOnlyWithholdsLiteralFromIndex() {
    var vocab = RollingVocabulary()
    vocab.record("aws_secret_key_value", count: 2, storeLiteral: false)
    // The count is present (frequency contributes)…
    let source = vocab.learnedSource(window: .days30)
    // …but the literal is NOT completable: prefix search returns nothing for it.
    let matches = source.candidates(forPrefix: "aws_")
    XCTAssertTrue(matches.isEmpty, "count-only token must never surface as a completion")
}

func testRecordWithLiteralStillCompletes() {
    var vocab = RollingVocabulary()
    vocab.record("awsconsole", count: 2, storeLiteral: true)
    let matches = vocab.learnedSource(window: .days30).candidates(forPrefix: "aws")
    XCTAssertEqual(matches.map(\.token), ["awsconsole"])
    XCTAssertEqual(matches.first?.count, 2)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter RollingVocabularyTests`
Expected: FAIL — `record` has no `storeLiteral:` parameter (compile error).

- [ ] **Step 3: Write minimal implementation**

Replace `RollingVocabulary.record` (lines 65-69):

```swift
/// Learn `count` occurrences of `token` into today's sketch. When `storeLiteral`
/// is false (L7 low-confidence) the literal is withheld from the prefix index —
/// the count still contributes to frequency, but the token can never be surfaced
/// as a completion or reconstructed from disk. Ignored for empty token / zero count.
public mutating func record(_ token: String, count: UInt32 = 1, storeLiteral: Bool = true) {
    guard !token.isEmpty, count > 0 else { return }
    if storeLiteral { index.insert(token) }
    today.add(token, count: count)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter RollingVocabularyTests`
Expected: PASS (existing callers use the default `storeLiteral: true`, so they are unaffected).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Predictor/RollingVocabulary.swift Tests/SemicolynKitTests/Predictor/RollingVocabularyTests.swift
git commit -m "feat(predictor): storeLiteral split on RollingVocabulary (L7 count-only)"
```

---

### Task 3: `storeLiteral` mirror on `RollingBigramVocabulary`

**Files:**
- Modify: `Sources/SemicolynKit/Predictor/RollingBigramVocabulary.swift:26-30`
- Test: `Tests/SemicolynKitTests/Predictor/RollingBigramVocabularyTests.swift` (add to whichever file tests `RollingBigramVocabulary`; if none, create it with the SPDX header)

**Interfaces:**
- Consumes: `RollingVocabulary.record(_:count:storeLiteral:)` (Task 2).
- Produces: `RollingBigramVocabulary.record(previous: String, next: String, count: UInt32 = 1, storeLiteral: Bool = true)`.

- [ ] **Step 1: Write the failing test**

```swift
func testBigramRecordCountOnlyWithholdsLiteral() {
    var bigram = RollingBigramVocabulary()
    bigram.record(previous: "login", next: "hunter2token", count: 2, storeLiteral: false)
    // The successor is not completable after "login".
    let after = bigram.candidates(after: "login", window: .days30, prefix: "hunter")
    XCTAssertTrue(after.isEmpty, "count-only bigram successor must not surface as a completion")
}

func testBigramRecordWithLiteralCompletes() {
    var bigram = RollingBigramVocabulary()
    bigram.record(previous: "git", next: "commit", count: 2, storeLiteral: true)
    let after = bigram.candidates(after: "git", window: .days30, prefix: "com")
    XCTAssertEqual(after.map(\.token), ["commit"])
}
```

> Confirm the exact read signature: `candidates(after:window:prefix:)` per `RollingBigramVocabulary.swift:49`. If it returns `[TokenCount]`, `.map(\.token)` yields the successor strings.

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter RollingBigramVocabularyTests`
Expected: FAIL — no `storeLiteral:` parameter (compile error).

- [ ] **Step 3: Write minimal implementation**

Replace `RollingBigramVocabulary.record` (lines 26-30):

```swift
public mutating func record(previous: String, next: String, count: UInt32 = 1,
                            storeLiteral: Bool = true) {
    guard count > 0,
          let key = BigramVocabulary.compositeKey(previous: previous, next: next) else { return }
    rolling.record(key, count: count, storeLiteral: storeLiteral)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter RollingBigramVocabularyTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Predictor/RollingBigramVocabulary.swift Tests/SemicolynKitTests/Predictor/RollingBigramVocabularyTests.swift
git commit -m "feat(predictor): storeLiteral mirror on RollingBigramVocabulary"
```

---

### Task 4: `TokenFilter.isPatternAdjacent` (soft L5 signal)

**Files:**
- Modify: `Sources/SemicolynKit/Predictor/TokenFilter.swift`
- Test: `Tests/SemicolynKitTests/Predictor/TokenFilterTests.swift`

**Interfaces:**
- Produces: `TokenFilter.isPatternAdjacent(_ token: String) -> Bool` — true for a token that PASSES `excludes` (not a hard secret) but sits in a soft entropy band just below the hard threshold, so it should graduate low-confidence (no persisted literal). A hard-excluded token returns false here (it never reaches `record`'s confidence step — `excludes` already dropped it).

**Design:** the soft band is `entropyThreshold - softMargin ≤ H(token) < entropyThreshold` for tokens at least `entropyMinLength` long, where `softMargin = 0.75` bits. This flags near-random strings that dodged the hard cutoff without inventing a new list. Returns false when `entropyThreshold` is nil (backstop disabled).

- [ ] **Step 1: Write the failing test**

Add to `TokenFilterTests.swift`:

```swift
func testPatternAdjacentFlagsSoftEntropyBand() {
    let filter = TokenFilter(entropyThreshold: 4.0, entropyMinLength: 16)
    // A 20-char token engineered to land in [3.25, 4.0): high but sub-threshold.
    let token = "aabbccddeeffgghhiijj"  // 10 distinct pairs → H = log2(10) ≈ 3.32
    XCTAssertFalse(filter.excludes(token), "precondition: not a hard-excluded secret")
    XCTAssertTrue(filter.isPatternAdjacent(token), "soft-band token must be flagged low-confidence")
}

func testPatternAdjacentIgnoresLowEntropyToken() {
    let filter = TokenFilter(entropyThreshold: 4.0, entropyMinLength: 16)
    let token = "aaaaaaaaaaaaaaaaaaaa"  // H = 0 → well below the band
    XCTAssertFalse(filter.isPatternAdjacent(token))
}

func testPatternAdjacentIgnoresShortToken() {
    let filter = TokenFilter(entropyThreshold: 4.0, entropyMinLength: 16)
    XCTAssertFalse(filter.isPatternAdjacent("abc123"), "below entropyMinLength — never flagged")
}

func testPatternAdjacentFalseWhenBackstopDisabled() {
    let filter = TokenFilter(entropyThreshold: nil)
    XCTAssertFalse(filter.isPatternAdjacent("aabbccddeeffgghhiijj"))
}
```

> Verify the entropy of the sample token during Step 4; if `H` falls outside `[3.25, 4.0)`, adjust the literal so the test asserts the real band boundary (BVA — pick one clearly inside, one clearly below).

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TokenFilterTests`
Expected: FAIL — `isPatternAdjacent` is undefined (compile error).

- [ ] **Step 3: Write minimal implementation**

Add inside `TokenFilter` (after `excludes`):

```swift
/// Soft L5 signal: true when `token` is NOT a hard-excluded secret but sits in an
/// entropy band just below the hard threshold — near-random enough that L7 should
/// graduate it low-confidence (count only, no persisted literal). Returns false
/// when the entropy backstop is disabled or the token is too short/low-entropy.
public func isPatternAdjacent(_ token: String) -> Bool {
    guard let threshold = entropyThreshold,
          token.unicodeScalars.count >= entropyMinLength else { return false }
    let h = shannonEntropy(token)
    let softMargin = 0.75
    return h >= threshold - softMargin && h < threshold
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TokenFilterTests`
Expected: PASS. If a sample token's entropy is off, adjust the literal (Step 1 note) and re-run.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Predictor/TokenFilter.swift Tests/SemicolynKitTests/Predictor/TokenFilterTests.swift
git commit -m "feat(predictor): TokenFilter.isPatternAdjacent soft-L5 signal (L7)"
```

---

### Task 5: Engine confidence derivation + `storeLiteral` wiring

**Files:**
- Modify: `Sources/SemicolynKit/Predictor/PredictorEngine.swift:49-60`
- Test: `Tests/SemicolynKitTests/Predictor/PredictorEngineTests.swift`

**Interfaces:**
- Consumes: `LearnConfidence` + `admit(...confidence:)` (Task 1); `RollingVocabulary.record(...storeLiteral:)` (Task 2); `RollingBigramVocabulary.record(...storeLiteral:)` (Task 3); `TokenFilter.isPatternAdjacent` (Task 4).
- Produces: `record(_ token: String, count: UInt32 = 1, after previous: String? = nil, echoConfirmed: Bool = true, optedOut: Bool = false)`. Confidence is `.high` iff `echoConfirmed && !optedOut && !filter.isPatternAdjacent(token)`, else `.low`. `storeLiteral = (confidence == .high)`.

- [ ] **Step 1: Write the failing test**

Add to `PredictorEngineTests.swift`. Note `confidenceFloor = 2` — record count 2 so entries clear the floor.

```swift
func testLowConfidenceTokenNeverCompletesButCounts() {
    var engine = PredictorEngine(learned: .empty, seed: nil)
    // Graduate a token low-confidence via 3 distinct contexts (default threshold 3),
    // each with echoConfirmed:false so it graduates .low.
    for prev in ["run", "make", "just"] {
        engine.record("deploysecretxyz", count: 2, after: prev, echoConfirmed: false)
    }
    // It graduated (count is on disk) but has NO literal → never a completion.
    XCTAssertTrue(engine.suggestions(forPrefix: "deploy").isEmpty,
                  "low-confidence token must never surface as a literal completion")
}

func testHighConfidenceTokenCompletes() {
    var engine = PredictorEngine(learned: .empty, seed: nil)
    for prev in ["run", "make", "just"] {
        engine.record("deployprod", count: 2, after: prev, echoConfirmed: true)
    }
    XCTAssertEqual(engine.suggestions(forPrefix: "deploy"), ["deployprod"])
}

func testOptedOutForcesLowConfidence() {
    var engine = PredictorEngine(learned: .empty, seed: nil)
    for prev in ["run", "make", "just"] {
        engine.record("deployxyz", count: 2, after: prev, echoConfirmed: true, optedOut: true)
    }
    XCTAssertTrue(engine.suggestions(forPrefix: "deploy").isEmpty,
                  "opted-out line forces low-confidence → no literal")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PredictorEngineTests`
Expected: FAIL — `record` has no `echoConfirmed`/`optedOut` params (compile error).

- [ ] **Step 3: Write minimal implementation**

Replace `PredictorEngine.record` (lines 49-60):

```swift
public mutating func record(_ token: String, count: UInt32 = 1, after previous: String? = nil,
                            echoConfirmed: Bool = true, optedOut: Bool = false) {
    guard !filter.excludes(token) else { return }
    // L7: derive the graduation confidence from the layers visible here.
    let confidence: LearnConfidence =
        (echoConfirmed && !optedOut && !filter.isPatternAdjacent(token)) ? .high : .low
    for occ in graduation.admit(token: token, previous: previous, count: count, confidence: confidence) {
        let storeLiteral = (occ.confidence == .high)
        learned.unigram.record(occ.token, count: occ.count, storeLiteral: storeLiteral)
        if let prev = occ.previous, !filter.excludes(prev) {
            learned.bigram.record(previous: prev, next: occ.token, count: occ.count,
                                  storeLiteral: storeLiteral)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PredictorEngineTests`
Expected: PASS. Pre-existing engine tests keep passing (defaults `echoConfirmed: true`, `optedOut: false` → `.high`, identical to prior behavior for clean tokens).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Predictor/PredictorEngine.swift Tests/SemicolynKitTests/Predictor/PredictorEngineTests.swift
git commit -m "feat(predictor): engine confidence derivation + storeLiteral wiring (L7)"
```

---

### Task 6: Forget-last-line (tier grouping + engine passthroughs) + panic-purge Kit

**Files:**
- Modify: `Sources/SemicolynKit/Predictor/GraduationTier.swift` (grouping + `beginLine`/`forgetLastLine`)
- Modify: `Sources/SemicolynKit/Predictor/PredictorEngine.swift` (`beginLine`/`forgetLastLine`/`purgeLearned` passthroughs)
- Modify: `Sources/SemicolynKit/Predictor/LearnedStore.swift` (`delete()`)
- Test: `Tests/SemicolynKitTests/Predictor/GraduationTierTests.swift`, `Tests/SemicolynKitTests/Predictor/PredictorEngineTests.swift`, `Tests/SemicolynKitTests/Predictor/LearnedStoreTests.swift`

**Interfaces:**
- Consumes: `admit(...confidence:)` (Task 1); `purgeLearned` clears `LearnedState`/`OutputHarvest`/`GraduationTier`.
- Produces:
  - `GraduationTier.beginLine()`; `GraduationTier.forgetLastLine()`.
  - `PredictorEngine.beginLine()`; `PredictorEngine.forgetLastLine()`; `PredictorEngine.purgeLearned()`.
  - `LearnedStore.delete() throws`.

- [ ] **Step 1: Write the failing tier test**

Add to `GraduationTierTests.swift`:

```swift
func testForgetLastLineReversesPendingContribution() {
    var tier = GraduationTier(threshold: 3)
    tier.beginLine()
    _ = tier.admit(token: "passw0rd", previous: "sudo", count: 1, confidence: .low)
    _ = tier.admit(token: "passw0rd", previous: "sudo", count: 1, confidence: .low)
    tier.forgetLastLine()   // reverse this line's pending increments
    // The token's pending count is gone → it must start from scratch to graduate.
    tier.beginLine()
    let a = tier.admit(token: "passw0rd", previous: "a", count: 1, confidence: .low)
    let b = tier.admit(token: "passw0rd", previous: "b", count: 1, confidence: .low)
    let c = tier.admit(token: "passw0rd", previous: "c", count: 1, confidence: .low)
    XCTAssertTrue(a.isEmpty && b.isEmpty)
    XCTAssertEqual(c.count, 3, "3 fresh distinct contexts graduate; the forgotten ones did not persist")
}

func testForgetLastLineDoesNotTouchGraduatedToken() {
    var tier = GraduationTier(threshold: 1)
    tier.beginLine()
    let flushed = tier.admit(token: "ls", previous: nil, count: 1, confidence: .high)  // graduates now
    XCTAssertEqual(flushed.count, 1)
    tier.forgetLastLine()
    // Already graduated → still graduated; a further admit passes straight through.
    let after = tier.admit(token: "ls", previous: "x", count: 1, confidence: .high)
    XCTAssertEqual(after, [GraduatedOccurrence(token: "ls", previous: "x", count: 1, confidence: .high)])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter GraduationTierTests`
Expected: FAIL — `beginLine`/`forgetLastLine` undefined (compile error).

- [ ] **Step 3: Implement tier grouping + forget**

In `GraduationTier.swift` add the field and methods, and record admits into it:

```swift
/// Tokens admitted since the last `beginLine()`, newest line only — the unit
/// `forgetLastLine()` reverses. Bounded implicitly by a line's token count.
private var lastLineTokens: [(token: String, previous: String?, count: UInt32)] = []

/// Mark a line boundary. The App calls this at each Enter, before recording the
/// line's tokens, so `lastLineTokens` captures exactly this line's admits.
public mutating func beginLine() { lastLineTokens.removeAll(keepingCapacity: true) }

/// Reverse the current line's still-pending increments (surgical forget-last-line).
/// Graduated tokens are untouched by design — they are in the persistent store and
/// not surgically reachable; L7 confidence tiering means a low-confidence one has
/// no literal to leak. Panic-purge is the fallback for graduated state.
public mutating func forgetLastLine() {
    for entry in lastLineTokens {
        guard var contexts = pending[entry.token] else { continue }  // graduated/evicted → skip
        let cur = contexts[entry.previous] ?? 0
        let reduced = cur - min(cur, entry.count)
        if reduced == 0 { contexts[entry.previous] = nil } else { contexts[entry.previous] = reduced }
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

In `admit`, after `pending[token]![previous, default: 0] += count` and only while the token is still pending (i.e. before the graduation flush returns), append the increment:

```swift
    pending[token]![previous, default: 0] += count
    lastLineTokens.append((token: token, previous: previous, count: count))
```

> Placement detail: append immediately after the pending increment. If the token then graduates on this call, that is fine — `forgetLastLine`'s `guard var contexts = pending[entry.token]` finds no pending entry for a just-graduated token and skips it (matching `testForgetLastLineDoesNotTouchGraduatedToken`). Also add `lastLineTokens.removeAll()` to `reset()`.

- [ ] **Step 4: Run tier test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter GraduationTierTests`
Expected: PASS.

- [ ] **Step 5: Write the failing engine + store tests**

Add to `PredictorEngineTests.swift`:

```swift
func testPurgeLearnedClearsUserStateKeepsSeed() {
    // Seed provides "sshd"; learned provides "sshconfig".
    let seed = PredictorSeed.forTesting(unigram: ["sshd"])   // use the suite's existing seed helper
    var engine = PredictorEngine(learned: .empty, seed: seed)
    for prev in ["a", "b", "c"] { engine.record("sshconfig", count: 2, after: prev, echoConfirmed: true) }
    XCTAssertTrue(engine.suggestions(forPrefix: "ssh").contains("sshconfig"))  // precondition
    engine.purgeLearned()
    let after = engine.suggestions(forPrefix: "ssh")
    XCTAssertFalse(after.contains("sshconfig"), "learned literal is gone after purge")
    XCTAssertTrue(after.contains("sshd"), "bundled seed survives purge")
}

func testForgetLastLineOnEngineDropsPendingLine() {
    var engine = PredictorEngine(learned: .empty, seed: nil)
    engine.beginLine()
    engine.record("hunter2pass", count: 1, after: "sudo", echoConfirmed: false)  // pending, not graduated
    engine.forgetLastLine()
    // Never graduated and now forgotten → still absent even after two more distinct contexts.
    engine.record("hunter2pass", count: 1, after: "x", echoConfirmed: false)
    engine.record("hunter2pass", count: 1, after: "y", echoConfirmed: false)
    XCTAssertTrue(engine.suggestions(forPrefix: "hunter").isEmpty)
}
```

> If the suite has no `PredictorSeed.forTesting`, construct the seed the way the existing purge/seed tests in this file do — reuse the established helper, do not invent a new one. If no seed helper exists, pass `seed: nil` and drop the seed-survival assertion into a `SeedStore`-level test instead; the learned-cleared assertion is the load-bearing one.

Add to `LearnedStoreTests.swift`:

```swift
func testDeleteThenLoadReturnsEmpty() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("phase4-del-\(UUID().uuidString)")
    let store = LearnedStore(directory: dir)
    var state = LearnedState.empty
    state.unigram.record("persisted", count: 3)
    try store.save(state)
    XCTAssertFalse(store.load().unigram.learnedSource(window: .days30)
        .candidates(forPrefix: "persist").isEmpty)  // precondition: saved
    try store.delete()
    XCTAssertTrue(store.load().unigram.learnedSource(window: .days30)
        .candidates(forPrefix: "persist").isEmpty, "delete removes the persisted store")
}

func testDeleteMissingFileDoesNotThrow() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("phase4-nofile-\(UUID().uuidString)")
    XCTAssertNoThrow(try LearnedStore(directory: dir).delete())  // idempotent
}
```

- [ ] **Step 6: Run to verify the new engine/store tests fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PredictorEngineTests` and `… --filter LearnedStoreTests`
Expected: FAIL — `purgeLearned`/`forgetLastLine`/`beginLine`/`delete` undefined (compile error).

- [ ] **Step 7: Implement engine passthroughs + store delete**

In `PredictorEngine.swift` (near `resetGraduation`):

```swift
/// Mark an input-line boundary for surgical forget-last-line (App calls at Enter).
public mutating func beginLine() { graduation.beginLine() }

/// Drop the current line's still-pending (un-graduated) tokens — the "oops, I just
/// typed a secret" tool. A clean ephemeral delete: no CMS decrement, no index surgery.
public mutating func forgetLastLine() { graduation.forgetLastLine() }

/// Wipe all user-derived learned state (persistent learned axes + ephemeral output
/// + L6 tier). The bundled seed is a `let` and is untouched. Panic-purge's Kit half.
public mutating func purgeLearned() {
    learned = .empty
    output.clear()
    graduation.reset()
}
```

In `LearnedStore.swift` (after `load`):

```swift
/// Delete the persisted learned store. Idempotent: a missing file is not an error
/// (panic-purge on a never-saved store must not throw). Other I/O errors propagate.
public func delete() throws {
    do {
        try FileManager.default.removeItem(at: fileURL)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
        return
    }
}
```

> Verify `OutputHarvest.clear()` exists (it is called by `clearHarvest()` in `PredictorEngine`, so it does). `LearnedState.empty` is the existing static.

- [ ] **Step 8: Run to verify all pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PredictorEngineTests` and `… --filter LearnedStoreTests` and `… --filter GraduationTierTests`
Expected: PASS.

- [ ] **Step 9: Full Kit suite regression check**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS (no masked regressions across the ~1008-test suite).

- [ ] **Step 10: Commit**

```bash
git add Sources/SemicolynKit/Predictor/GraduationTier.swift Sources/SemicolynKit/Predictor/PredictorEngine.swift Sources/SemicolynKit/Predictor/LearnedStore.swift Tests/SemicolynKitTests/Predictor/
git commit -m "feat(predictor): forget-last-line + purgeLearned + LearnedStore.delete (L7 forget tools)"
```

---

### Task 7: App capture-site plumbing (echoConfirmed / optedOut / beginLine)

**Files:**
- Modify: `App/ConnectionViewModel.swift:782-792` (the Enter-path learn block)
- Verified by: **macOS CI** (not `swift test`).

**Interfaces:**
- Consumes: `engine.record(...echoConfirmed:optedOut:)`, `engine.beginLine()` (Tasks 5, 6).
- Produces: `ConnectionViewModel.forgetLastLine()` (used by Task 8's UI).

- [ ] **Step 1: Wire the verdicts into the Enter path**

Replace the learn block (currently lines ~782-792) so it calls `beginLine()` before recording and passes both verdicts. `optedOut` is the `optedOut` local already read at line 774 from `tracker.lastCommittedLineOptedOut`; `echoConfirmed` is `passwordDetector.shouldLearnCommittedLine()`.

```swift
for b in bytes where b == 0x0d || b == 0x0a {
    DispatchQueue.main.asyncAfter(deadline: deadline + .milliseconds(10)) { [weak self] in
        guard let self else { return }
        let echoConfirmed = self.passwordDetector.shouldLearnCommittedLine()
        // Learn only if L1 confirms echo AND the line was not opted out (L4a); the
        // engine still folds echo/opt-out/L5 into the L7 confidence tier.
        if !optedOut, echoConfirmed {
            self.engine?.beginLine()
            for c in self.pendingLineTokens {
                self.engine?.record(c.token, after: c.previous,
                                    echoConfirmed: echoConfirmed, optedOut: optedOut)
            }
        }
        self.pendingLineTokens.removeAll(keepingCapacity: true)
        self.passwordDetector.resetLine()
    }
}
```

> Note the outer `if !optedOut, echoConfirmed` gate is retained (it already suppresses opted-out/non-echoed lines entirely). The engine's confidence derivation is the *second line of defense* for the tokens that do pass — e.g. an L5 pattern-adjacent token on an otherwise-echoed line still lands `.low`. Passing `echoConfirmed`/`optedOut` here keeps the engine's mapping honest and future-proofs relaxing the outer gate.

- [ ] **Step 2: Add the `forgetLastLine` VM method**

Add near `flushPredictor()`:

```swift
/// Forget the most-recently-typed line's un-graduated tokens (surgical L7 tool).
/// Surfaced by the predictor strip's eraser. No-op when the predictor is off.
func forgetLastLine() {
    engine?.forgetLastLine()
    // Ephemeral drop — nothing to persist; suggestions refresh on next input.
}
```

- [ ] **Step 3: Verify via macOS CI**

Commit (Step 4) then push the branch; watch the macOS job:
Run: `gh run list --branch feat/predictor-secret-exclusion-phase4 --limit 1` then `gh run watch <id>`
Expected: `macos` job green (the only signal that this App code compiles).

- [ ] **Step 4: Commit**

```bash
git add App/ConnectionViewModel.swift
git commit -m "feat(app): plumb echo/opt-out verdicts + beginLine into predictor record (L7)"
```

---

### Task 8: Forget-last-line strip UI + toast

**Files:**
- Modify: `App/Keybar/PredictorStripView.swift`
- Verified by: **macOS CI**.

**Interfaces:**
- Consumes: `ConnectionViewModel.forgetLastLine()` (Task 7).

- [ ] **Step 1: Add the eraser affordance**

Read `PredictorStripView.swift` first to match its existing layout (`HStack`/`ScrollView` of chips + the VM binding). Add a trailing eraser button, shown when the strip has content:

```swift
// Trailing forget-last-line affordance (L7 surgical forget). Shown alongside chips.
Button {
    vm.forgetLastLine()
    withAnimation { showForgetToast = true }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        withAnimation { showForgetToast = false }
    }
} label: {
    Image(systemName: "eraser")
        .accessibilityLabel("Forget last line")
}
.buttonStyle(.plain)
```

Add `@State private var showForgetToast = false` and a lightweight overlay/label rendering "Last line forgotten" when `showForgetToast` (match the app's existing toast pattern if one exists; otherwise a `.overlay` with a capsule `Text`).

> Keep it minimal and consistent with the strip's existing chip styling. Do not restructure the strip.

- [ ] **Step 2: Verify via macOS CI**

Run: `gh run watch <id>` after push. Expected: `macos` job green.

- [ ] **Step 3: Commit**

```bash
git add App/Keybar/PredictorStripView.swift
git commit -m "feat(app): forget-last-line eraser on the predictor strip (L7)"
```

---

### Task 9: Privacy Settings screen + panic-purge wiring

**Files:**
- Create: `App/PrivacySettingsView.swift`
- Modify: `App/SettingsView.swift`
- Modify: `App/ConnectionViewModel.swift` (`panicPurge()` VM method) — or the appropriate store owner if the predictor store is reached without a live connection (see Step 3 note).
- Verified by: **macOS CI**.

**Interfaces:**
- Consumes: `engine.purgeLearned()` (Task 6); `AppStores.shared.predictorLearnedStore().delete()` (Task 6).

- [ ] **Step 1: Add the panic-purge action**

The purge must work even with no live session (Settings is reachable from the host list). It has two halves: delete the on-disk file (always possible via `AppStores`), and reset the live engine if one exists. Put a standalone helper where Settings can call it without a `ConnectionViewModel`. Add to `AppStores`:

```swift
/// Delete the persisted predictor learned store (panic-purge's disk half). The
/// bundled seed is separate and untouched. A missing file is not an error.
func purgePredictorLearned() throws {
    try predictorLearnedStore().delete()
}
```

If a live `ConnectionViewModel` exists, also add there so the running session clears immediately:

```swift
/// Panic-purge: wipe all user-derived predictor state now (live engine + disk).
func panicPurge() {
    engine?.purgeLearned()
    try? AppStores.shared.purgePredictorLearned()
}
```

> Wiring note: the Settings sheet is presented without a connection in the host-list context, so `PrivacySettingsView` calls `AppStores.shared.purgePredictorLearned()` directly for the disk wipe. If it is ever presented over a live session, that session's engine is separately reset on next `startPredictor`/`teardown`; a stale in-memory engine writing back on background is the only edge — acceptable for v1 (the file is re-deleted on next purge and the next launch loads empty). Document this in the view.

- [ ] **Step 2: Create the Privacy screen**

`App/PrivacySettingsView.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Privacy controls. v1 surfaces the predictor panic-purge — the honest, complete
/// "forget everything it learned" reset. Wipes user-derived learned state only; the
/// bundled seed suggestions (shipped app content, no secret) remain.
struct PrivacySettingsView: View {
    @State private var confirming = false
    @State private var purged = false

    var body: some View {
        List {
            Section {
                Button(role: .destructive) { confirming = true } label: {
                    Label("Forget everything the predictor learned", systemImage: "trash")
                }
            } footer: {
                Text("Removes everything the keyboard predictor learned from what you typed. The built-in suggestions remain.")
            }
        }
        .navigationTitle("Privacy")
        .confirmationDialog("Forget the predictor's learned words?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("Forget Everything", role: .destructive) {
                try? AppStores.shared.purgePredictorLearned()
                purged = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone. Built-in suggestions are kept.")
        }
        .alert("Predictor memory cleared", isPresented: $purged) {
            Button("OK", role: .cancel) {}
        }
    }
}
```

- [ ] **Step 3: Add the Settings row**

In `App/SettingsView.swift`, add a second `NavigationLink` under Appearance:

```swift
NavigationLink {
    PrivacySettingsView()
} label: {
    Label("Privacy", systemImage: "hand.raised")
}
```

- [ ] **Step 4: Verify via macOS CI**

Run: `gh run watch <id>` after push. Expected: `macos` job green.

- [ ] **Step 5: Commit**

```bash
git add App/PrivacySettingsView.swift App/SettingsView.swift App/ConnectionViewModel.swift App/AppStores.swift
git commit -m "feat(app): Privacy Settings screen + predictor panic-purge (L7)"
```

---

### Task 10: Full-branch verification + docs

**Files:**
- Verified by: full Kit suite + macOS CI.

- [ ] **Step 1: Full Kit suite**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS, count ≥ prior 1008 (new tests added, none removed).

- [ ] **Step 2: Rust fmt/lint safety (no Rust touched, but the branch pushes CI)**

No Rust changed this phase — skip `cargo fmt`. (Recorded so the reviewer doesn't expect a Rust diff.)

- [ ] **Step 3: Push + full CI**

Run: `git push -u github feat/predictor-secret-exclusion-phase4` then open the PR:
`gh pr create --repo ds7n/semicolyn --fill --title "feat(predictor): L7 storage + forget-last-line + panic-purge (secret-exclusion Phase 4)"`
Expected: `linux-swift`, `lint`, `macos` all green. If `linux-rust` flakes on `sshd fixtures not reachable`, rerun that job (`gh run rerun <id> --failed`).

- [ ] **Step 4: Update TODO.md + memory pointer**

Mark Phase 4 shipped in `TODO.md` (mirror the Phase 1–3 entries) and note the follow-up: no L2/L8 yet. Commit:

```bash
git add TODO.md
git commit -m "docs: mark predictor secret-exclusion Phase 4 shipped"
```

---

## Self-review

**Spec coverage:**
- L7 confidence hand-off → Tasks 1, 5, 7. ✓
- Low-confidence storage split (unigram + bigram symmetry) → Tasks 2, 3, 5. ✓
- `isPatternAdjacent` soft-L5 → Task 4. ✓
- Forget-last-line (tier grouping + engine + strip UI) → Tasks 6, 7, 8. ✓
- Panic-purge (engine + store delete + Privacy screen) → Tasks 6, 9. ✓
- All security-critical tests from the spec present: low-conf-never-completes (Task 5), high-conf-completes (Task 5), confidence mapping BVA (Tasks 4, 5), forget removes pending / not graduated (Task 6), purge keeps seed (Task 6), delete idempotent (Task 6). ✓

**Type consistency:**
- `LearnConfidence` (Task 1) used identically in Tasks 5, 6. ✓
- `GraduatedOccurrence(token:previous:count:confidence:)` init consistent across Tasks 1, 6. ✓
- `record(...storeLiteral:)` consistent Tasks 2→3→5. ✓
- `admit(...confidence:)` consistent Tasks 1→6. ✓
- `beginLine()`/`forgetLastLine()`/`purgeLearned()` names consistent Tasks 6→7→8→9. ✓

**Placeholder scan:** no TBD/TODO; every code step shows code; the two "verify the sample entropy / reuse the existing seed helper" notes are grounding caveats (real values to confirm at run time), not placeholders — each has a concrete fallback.

**Deviation flagged:** `CommittedToken.optedOut` dropped in favor of the App-latch plumbing (documented at top). Confirm on review.
