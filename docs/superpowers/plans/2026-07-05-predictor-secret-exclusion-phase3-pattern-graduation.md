<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Predictor Secret-Exclusion — Phase 3: L5 Pattern Extension + L6 Frequency Graduation (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the predictor's write-time exclusion with L5 (more known credential-format patterns in the existing `TokenFilter`) and L6 (frequency graduation — a token enters the persistent learned store only after it recurs across ≥3 distinct contexts, so a once-typed password — even a low-entropy human one L5 can't match — never becomes a suggestion).

**Architecture:** Both layers are **pure Kit (Linux-tested)**, no App-tier work. L5 adds conservative `ExcludePattern` entries + a JWT/PEM structural check to `TokenFilter` (algorithm unchanged). L6 interposes an ephemeral, never-persisted **graduation tier** in front of `PredictorEngine.record`'s writes to the persistent stores: a per-token map of distinct preceding-token contexts with accumulated counts; a token graduates (and backfills its accumulated occurrences) only on reaching N=3 distinct contexts, then records directly.

**Tech Stack:** Swift 6.1, SemicolynKit (XCTest, Linux via Docker `semicolyn-dev`). No new dependencies.

## Global Constraints

- **Pure Kit, Linux-tested:** all Phase 3 logic in `Sources/SemicolynKit/Predictor/` — no `import UIKit`/`SwiftUI`/`SwiftTerm`/`CryptoKit`. `TokenFilter` stays `Sendable`; `PredictorEngine` stays a value-type `struct`.
- **Reframe governs:** predictor, not scanner — a false positive costs one skipped word, a false negative leaks a credential. **Exclusion wins ties; every failure mode suppresses / defers.**
- **L6 threshold N = 3.** A token graduates when `distinctContexts ≥ N` **OR** `nilCount ≥ N`, where:
  - `distinctContexts` = number of distinct preceding tokens seen (including `nil` as one of them);
  - `nilCount` = total start-of-line (`previous == nil`) occurrences.
  - "Distinct context" = a different preceding token; the same `(token, previous)` pair replayed does NOT add a new distinct context (but it DOES accumulate that context's count, and if `previous == nil` it increments `nilCount`).
  - **Rationale (user-locked):** a bare command typed repeatedly at the prompt (`ls`↵`ls`↵`ls`↵ — all `nil`) graduates via `nilCount ≥ N` (utility). A secret typed at a prompt has a NON-nil preceding word (the prompt token / `sudo` / a flag), so it needs `≥ N` DISTINCT preceding tokens → a once- or few-times-typed password at the same prompt never graduates (protection). This refines the spec's plain "distinct contexts" text; the spec's "same line replayed does not over-count" still holds for the distinct-context axis.
- **Graduation backfills accumulated counts** (locked decision): the ephemeral tier tracks each token's `{previous → accumulated count}`; on the Nth distinct context, ALL accumulated occurrences flush into the real store at once, then the token records directly thereafter.
- **The ephemeral tier is NEVER persisted** — it lives on `PredictorEngine` and is not part of `LearnedState` (which is what `LearnedStore` serializes). Session-scoped; lost on app kill (a safe loss — un-graduated tokens hadn't been learned).
- **The ephemeral tier is bounded** — a cap on the number of tracked un-graduated tokens prevents a hostile/very-long session from growing it unboundedly; eviction is oldest-first and only ever DELAYS learning (safe).
- **Suggestions are unaffected by L6** — L6 gates only *learning* (writes). Seed/known-command/harvest suggestions surface immediately as today; only *learned-from-you* tokens are deferred.
- **L5 is extended, not redesigned** — the entropy algorithm and existing patterns are unchanged; only new patterns + a structural JWT/PEM check are added.
- **Every source file carries the SPDX header** (`// SPDX-FileCopyrightText: 2026 True Positive LLC` / `// SPDX-License-Identifier: GPL-3.0-only`). REUSE-compliant.
- **Tests must be real** (testing-standards spec): equivalence-partitioning + boundary values, assert the *specific* observable outcome. L5 pattern additions + L6 graduation are **Critical-tier** (a miss leaks a credential) — adversarial negatives + boundary (N−1, N) mandatory.
- **Conventional commits**; feature branch `feat/predictor-secret-exclusion-phase3` off `main`; squash-merge.
- **Build/test command (no host Swift toolchain):**
  `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <TestClass>`
  (If the Docker socket is sandbox-blocked for a subagent, it must report that and NOT assume its code is wrong; the controller runs the suite.)

## Spec & Source References

- Spec: `docs/superpowers/specs/2026-07-04-predictor-secret-exclusion-design.md` — sections **L5**, **L6**, "Data flow & layer ordering", "Testing".
- L5 target: `Sources/SemicolynKit/Predictor/TokenFilter.swift` (`ExcludePattern` enum, `defaultPatterns`, `excludes(_:)`, `shannonEntropy`).
- L6 target: `Sources/SemicolynKit/Predictor/PredictorEngine.swift` (`record(_:count:after:)` at :48 — the single write gate; `harvest`, `suggestions`, `rollover` unchanged). The persistent stores are `learned.unigram`/`learned.bigram` (`LearnedState`, serialized by `LearnedStore`). The ephemeral tier must live on `PredictorEngine` OUTSIDE `LearnedState`.
- Existing filter design: `docs/superpowers/specs/2026-06-21-predictor-privacy-filter-design.md` (L5 is an extension of this).

## Current behavior these layers extend

- `TokenFilter.excludes(token)` returns true if any `ExcludePattern` matches (case-insensitive `contains`, case-sensitive `hasPrefix`) OR the token is ≥`entropyMinLength` (16) chars with Shannon entropy ≥`entropyThreshold` (4.0). L5 adds patterns + a JWT/PEM structural check.
- `PredictorEngine.record(token, count, after: previous)`: guards `filter.excludes(token)` (L5), then IMMEDIATELY writes `learned.unigram.record` + (if `previous` not excluded) `learned.bigram.record`. L6 interposes the graduation gate between the filter guard and these writes.

## File Structure

- **Modify** `Sources/SemicolynKit/Predictor/TokenFilter.swift` — L5: add credential-format patterns to `defaultPatterns` + a structural `isStructuredSecret(_:)` helper (JWT three-segment `eyJ…`, PEM `-----BEGIN … PRIVATE KEY-----`) consulted by `excludes`. One responsibility unchanged: the write-time exclude predicate.
- **Create** `Sources/SemicolynKit/Predictor/GraduationTier.swift` — L6: the pure ephemeral graduation state machine (`GraduationTier` struct: per-token `{previous → count}` map, N threshold, bound + eviction; `admit(token:previous:count:) -> [GraduatedOccurrence]` returns the occurrences to flush when a token graduates, else empty). One responsibility: decide when a token has earned persistence and what to backfill. Kept separate from the engine so it is independently unit-testable (mirrors `TokenFilter`/`SecretArgDenylist` living apart).
- **Modify** `Sources/SemicolynKit/Predictor/PredictorEngine.swift` — wire `GraduationTier` into `record`; add a reset for context switches; remove the now-superseded leading-space `TODO` comment (handled by Phase 2 L4a).
- **Modify** `Tests/SemicolynKitTests/TokenFilterTests.swift` (create if absent) — L5 pattern + structural tests.
- **Create** `Tests/SemicolynKitTests/GraduationTierTests.swift` — L6 unit tests (threshold boundary, distinct-context counting, backfill, bound/eviction).
- **Modify** `Tests/SemicolynKitTests/PredictorEngineTests.swift` (or the existing engine test file) — L6 integration through `record`/`suggestions`.

---

## Task 1: L5 — extend `TokenFilter` with credential-format patterns

Add conservative known-format prefixes to `defaultPatterns`. These are exact, high-confidence prefixes (case-sensitive `hasPrefix`), lifted from public credential rulesets — a curated subset, not the full 150-rule set.

**Files:**
- Modify: `Sources/SemicolynKit/Predictor/TokenFilter.swift`
- Test: `Tests/SemicolynKitTests/TokenFilterTests.swift`

**Interfaces:**
- Consumes: existing `ExcludePattern.hasPrefix`, `defaultPatterns`, `excludes`.
- Produces: extended `defaultPatterns` (later tasks + the engine consume `excludes` unchanged).

- [ ] **Step 1: Write the failing test**

Create `Tests/SemicolynKitTests/TokenFilterTests.swift` (if it already exists, append the `// MARK: - L5` section):

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Critical-tier: a known credential format that slips through is a leaked secret,
/// so each added format is an adversarial negative asserting `excludes == true`,
/// and a benign lookalike asserts `excludes == false` (no over-broad prefix).
final class TokenFilterTests: XCTestCase {
    private let f = TokenFilter()   // default patterns + entropy backstop

    // MARK: - L5 added credential-format prefixes

    func testAwsAccessKeyExcluded() {
        XCTAssertTrue(f.excludes("AKIAIOSFODNN7EXAMPLE"))
        XCTAssertTrue(f.excludes("ASIAIOSFODNN7EXAMPLE"))
    }

    func testGoogleApiKeyExcluded() {
        XCTAssertTrue(f.excludes("AIzaSyD-EXAMPLE_key_1234567890abcdefg"))
    }

    func testStripeLiveKeysExcluded() {
        XCTAssertTrue(f.excludes("sk_live_abc123DEF456"))
        XCTAssertTrue(f.excludes("rk_live_abc123DEF456"))
    }

    func testSlackTokensExcluded() {
        XCTAssertTrue(f.excludes("xoxb-1234-5678-abcdefg"))
        XCTAssertTrue(f.excludes("xoxp-1111-2222-zzz"))
    }

    func testGithubFineGrainedPatExcluded() {
        // Already present via `github_pat_` in the shipped defaults — assert it stays.
        XCTAssertTrue(f.excludes("github_pat_11ABCDEFG_examplekeymaterial"))
    }

    func testBenignTokenNotExcludedByL5Prefixes() {
        // A normal command/arg that shares no credential prefix must NOT be excluded.
        XCTAssertFalse(f.excludes("kubectl"))
        XCTAssertFalse(f.excludes("git"))
        // "asia" as a plain word is lowercase — the ASIA prefix is case-sensitive.
        XCTAssertFalse(f.excludes("asia-region"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TokenFilterTests`
Expected: FAIL — `testAwsAccessKeyExcluded` etc. fail (those prefixes aren't in `defaultPatterns` yet).

- [ ] **Step 3: Add the patterns**

In `Sources/SemicolynKit/Predictor/TokenFilter.swift`, extend `defaultPatterns`. Replace the existing array literal:

```swift
    public static let defaultPatterns: [ExcludePattern] = [
        .contains("password"), .contains("token"), .contains("secret"),
        .hasPrefix("ghp_"), .hasPrefix("gho_"), .hasPrefix("ghs_"),  // GitHub classic PATs
        .hasPrefix("github_pat_"),                                   // GitHub fine-grained PATs
        .hasPrefix("sk-"),                                           // OpenAI API keys
        .hasPrefix("sk_"), .hasPrefix("pk_"),                        // Stripe secret / publishable keys
    ]
```

with:

```swift
    public static let defaultPatterns: [ExcludePattern] = [
        .contains("password"), .contains("token"), .contains("secret"),
        .hasPrefix("ghp_"), .hasPrefix("gho_"), .hasPrefix("ghs_"),  // GitHub classic PATs
        .hasPrefix("github_pat_"),                                   // GitHub fine-grained PATs
        .hasPrefix("sk-"),                                           // OpenAI API keys
        .hasPrefix("sk_"), .hasPrefix("pk_"),                        // Stripe secret / publishable keys
        // L5 (Phase 3) — curated public credential-format prefixes.
        .hasPrefix("AKIA"), .hasPrefix("ASIA"),                      // AWS access key IDs
        .hasPrefix("AIza"),                                          // Google API keys
        .hasPrefix("sk_live_"), .hasPrefix("rk_live_"),             // Stripe live keys (narrower than sk_)
        .hasPrefix("xoxb-"), .hasPrefix("xoxa-"),                    // Slack bot / app tokens
        .hasPrefix("xoxp-"), .hasPrefix("xoxr-"), .hasPrefix("xoxs-"), // Slack user/refresh/config tokens
    ]
```

> Note: `sk_live_`/`rk_live_` are redundant with the existing `sk_`/`pk_`? No — `sk_` is present but `rk_` is not, and `sk_live_` is a documenting narrower entry. Keeping both is harmless (first match wins). `AKIA`/`ASIA` are case-sensitive prefixes so a lowercase `asia-region` does not match (asserted by `testBenignTokenNotExcludedByL5Prefixes`).

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TokenFilterTests`
Expected: PASS — all L5 prefix tests + the benign-negative test.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Predictor/TokenFilter.swift Tests/SemicolynKitTests/TokenFilterTests.swift
git commit -m "feat(predictor): L5 add curated credential-format prefixes to TokenFilter"
```

---

## Task 2: L5 — structural JWT + PEM detection

JWTs (`eyJ…` three dot-separated base64url segments) and PEM private-key headers (`-----BEGIN … PRIVATE KEY-----`) are not fixed prefixes over the whole token — they need a small structural check. Add `isStructuredSecret(_:)` and consult it from `excludes`.

**Files:**
- Modify: `Sources/SemicolynKit/Predictor/TokenFilter.swift`
- Test: `Tests/SemicolynKitTests/TokenFilterTests.swift`

**Interfaces:**
- Consumes: the Task 1 `TokenFilter`.
- Produces: `excludes` additionally returns true for JWT/PEM-shaped tokens.

- [ ] **Step 1: Write the failing test**

Append to `Tests/SemicolynKitTests/TokenFilterTests.swift`:

```swift
    // MARK: - L5 structural (JWT / PEM)

    func testJwtExcluded() {
        // Three base64url segments, first starts with the standard `eyJ` header.
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        XCTAssertTrue(f.excludes(jwt))
    }

    func testPemPrivateKeyHeaderExcluded() {
        XCTAssertTrue(f.excludes("-----BEGIN RSA PRIVATE KEY-----"))
        XCTAssertTrue(f.excludes("-----BEGIN OPENSSH PRIVATE KEY-----"))
    }

    func testNonJwtDottedTokenNotExcluded() {
        // A dotted token that is NOT a JWT (doesn't start with eyJ, wrong shape)
        // must not be excluded by the structural check — e.g. a hostname or version.
        XCTAssertFalse(f.excludes("example.com.au"))
        XCTAssertFalse(f.excludes("1.2.3"))
    }

    func testPublicPemHeaderNotExcluded() {
        // A PUBLIC key / certificate header is not a secret — must NOT be excluded
        // by the PEM check (only PRIVATE KEY headers are secret-bearing).
        XCTAssertFalse(f.excludes("-----BEGIN PUBLIC KEY-----"))
        XCTAssertFalse(f.excludes("-----BEGIN CERTIFICATE-----"))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TokenFilterTests`
Expected: FAIL — `testJwtExcluded` / `testPemPrivateKeyHeaderExcluded` fail (no structural check yet).

- [ ] **Step 3: Add the structural check**

In `TokenFilter.swift`, add the helper (file scope, below `shannonEntropy` or as a `private` method) and consult it in `excludes`. Add the standalone function:

```swift
/// True if `token` is a structurally-shaped secret that no fixed prefix catches:
/// a JWT (three `.`-separated base64url segments, first beginning `eyJ`) or a PEM
/// PRIVATE KEY header. Conservative: only PRIVATE (not PUBLIC/CERTIFICATE) PEM
/// headers, and JWT requires the standard `eyJ` (`{"` base64url) leader so a plain
/// dotted hostname/version does not match.
func isStructuredSecret(_ token: String) -> Bool {
    // JWT: eyJ… . … . …  (exactly three non-empty base64url segments).
    if token.hasPrefix("eyJ") {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        if segments.count == 3, segments.allSatisfy({ !$0.isEmpty && isBase64URL($0) }) {
            return true
        }
    }
    // PEM private key header (any key type: RSA / OPENSSH / EC / plain).
    if token.hasPrefix("-----BEGIN") && token.contains("PRIVATE KEY") {
        return true
    }
    return false
}

/// True if `s` contains only base64url characters (A–Z a–z 0–9 - _ =).
private func isBase64URL(_ s: Substring) -> Bool {
    s.allSatisfy { c in
        c.isLetter || c.isNumber || c == "-" || c == "_" || c == "="
    }
}
```

In `excludes(_:)`, add the structural check just before the entropy backstop — insert after the pattern loop, before the `if let threshold = entropyThreshold` block:

```swift
        if isStructuredSecret(token) { return true }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TokenFilterTests`
Expected: PASS — JWT + PEM-private excluded; dotted-non-JWT + PEM-public NOT excluded.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Predictor/TokenFilter.swift Tests/SemicolynKitTests/TokenFilterTests.swift
git commit -m "feat(predictor): L5 structural JWT + PEM private-key detection"
```

---

## Task 3: L6 — the `GraduationTier` pure unit

The ephemeral graduation state machine. A token is tracked in a per-token map of `previous → accumulated count`. `admit` returns the occurrences to flush (empty until graduation; on the Nth distinct context, ALL accumulated occurrences including the current one). Already-graduated tokens pass through immediately (their occurrence returned as-is). Bounded by a cap on tracked un-graduated tokens (oldest-first eviction).

**Files:**
- Create: `Sources/SemicolynKit/Predictor/GraduationTier.swift`
- Test: `Tests/SemicolynKitTests/GraduationTierTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces (relied on by Task 4 engine wiring):
  - `public struct GraduatedOccurrence: Equatable, Sendable { public let token: String; public let previous: String?; public let count: UInt32 }`
  - `public struct GraduationTier: Equatable, Sendable`
    - `public init(threshold: Int = 3, maxTracked: Int = 4096)`
    - `public mutating func admit(token: String, previous: String?, count: UInt32) -> [GraduatedOccurrence]` — returns occurrences to persist NOW (empty while still deferred).
    - `public mutating func reset()` — clears all ephemeral state (context/incognito switch).

**Design note — the state machine.**
- A `graduated: Set<String>` of tokens that have already crossed the threshold. If `token ∈ graduated`, `admit` returns `[GraduatedOccurrence(token, previous, count)]` immediately (record directly).
- Otherwise a `pending: [String: [String?: UInt32]]` map (token → its distinct `previous` contexts → accumulated count). `Optional<String>` conforms to `Hashable` when `String` does, so `[String?: UInt32]` is a valid dictionary. Add `count` to `pending[token][previous]`.
- **Graduation predicate (combined OR):** after adding, let `contexts = pending[token]`. Graduate if `contexts.count >= threshold` (distinct preceding tokens) **OR** `contexts[nil] ?? 0 >= threshold` (start-of-line occurrences — `contexts[nil]` is the accumulated `nilCount` because every `previous == nil` occurrence adds to the single `nil` key). On graduation: move `token` to `graduated`, remove from `pending`, RETURN one `GraduatedOccurrence` per `(previous, accumulatedCount)` entry (the backfill). Otherwise return `[]`.
- Bound: if inserting a NEW token into `pending` would exceed `maxTracked`, evict the oldest-inserted pending token first (FIFO of token keys). Eviction only delays learning (safe).

- [ ] **Step 1: Write the failing test**

Create `Tests/SemicolynKitTests/GraduationTierTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Critical-tier: L6 is the format-agnostic backstop — a token that graduates too
/// early could persist a once-typed secret. Tests pin the exact N boundary
/// (N−1 defers, N graduates), distinct-context counting, and the backfill.
final class GraduationTierTests: XCTestCase {

    func testBelowThresholdDefers() {
        var t = GraduationTier(threshold: 3)
        // Two distinct contexts (< 3) → nothing graduates yet.
        XCTAssertEqual(t.admit(token: "deploy", previous: "git", count: 1), [])
        XCTAssertEqual(t.admit(token: "deploy", previous: "make", count: 1), [])
    }

    func testGraduatesOnNthDistinctContextWithBackfill() {
        var t = GraduationTier(threshold: 3)
        _ = t.admit(token: "deploy", previous: "git", count: 1)     // ctx 1
        _ = t.admit(token: "deploy", previous: "make", count: 2)    // ctx 2
        // ctx 3 → graduate; backfill ALL accumulated occurrences (incl. this one).
        let flushed = t.admit(token: "deploy", previous: "npm", count: 1)
        // Order-independent: assert the SET of occurrences.
        XCTAssertEqual(
            Set(flushed),
            Set([
                GraduatedOccurrence(token: "deploy", previous: "git", count: 1),
                GraduatedOccurrence(token: "deploy", previous: "make", count: 2),
                GraduatedOccurrence(token: "deploy", previous: "npm", count: 1),
            ]))
    }

    func testSameNonNilContextReplayedDoesNotGraduate() {
        var t = GraduationTier(threshold: 3)
        // The SAME (token, NON-nil previous) three times = ONE distinct context and
        // nilCount stays 0 → defer. A password re-typed at the same `sudo` prompt
        // never graduates — the core secret-protection guarantee of L6.
        XCTAssertEqual(t.admit(token: "pw", previous: "sudo", count: 1), [])
        XCTAssertEqual(t.admit(token: "pw", previous: "sudo", count: 1), [])
        XCTAssertEqual(t.admit(token: "pw", previous: "sudo", count: 1), [])
    }

    func testRepeatedStartOfLineGraduatesViaNilCount() {
        var t = GraduationTier(threshold: 3)
        // A bare command typed repeatedly at the prompt (all previous=nil): the
        // nilCount reaches N on the 3rd → graduate (utility for reused commands).
        XCTAssertEqual(t.admit(token: "ls", previous: nil, count: 1), [])   // nilCount 1
        XCTAssertEqual(t.admit(token: "ls", previous: nil, count: 1), [])   // nilCount 2
        let flushed = t.admit(token: "ls", previous: nil, count: 1)         // nilCount 3 → graduate
        // Backfill is the single accumulated nil context with count 3.
        XCTAssertEqual(flushed, [GraduatedOccurrence(token: "ls", previous: nil, count: 3)])
    }

    func testTwoStartOfLineOccurrencesDoNotGraduate() {
        var t = GraduationTier(threshold: 3)
        // Boundary N−1: two nil occurrences is below the nilCount threshold.
        XCTAssertEqual(t.admit(token: "ls", previous: nil, count: 1), [])
        XCTAssertEqual(t.admit(token: "ls", previous: nil, count: 1), [])   // nilCount 2 < 3
    }

    func testNilPreviousIsOneDistinctContext() {
        var t = GraduationTier(threshold: 3)
        _ = t.admit(token: "ls", previous: nil, count: 1)           // ctx nil
        _ = t.admit(token: "ls", previous: "then", count: 1)        // ctx "then"
        let flushed = t.admit(token: "ls", previous: "also", count: 1)   // ctx "also" → graduate
        XCTAssertEqual(flushed.count, 3)
        XCTAssertTrue(flushed.contains(GraduatedOccurrence(token: "ls", previous: nil, count: 1)))
    }

    func testAlreadyGraduatedRecordsDirectly() {
        var t = GraduationTier(threshold: 3)
        _ = t.admit(token: "deploy", previous: "git", count: 1)
        _ = t.admit(token: "deploy", previous: "make", count: 1)
        _ = t.admit(token: "deploy", previous: "npm", count: 1)     // graduates
        // Post-graduation: each occurrence passes straight through, no backfill.
        XCTAssertEqual(
            t.admit(token: "deploy", previous: "yarn", count: 5),
            [GraduatedOccurrence(token: "deploy", previous: "yarn", count: 5)])
    }

    func testResetClearsEphemeralState() {
        var t = GraduationTier(threshold: 3)
        _ = t.admit(token: "deploy", previous: "git", count: 1)
        _ = t.admit(token: "deploy", previous: "make", count: 1)
        t.reset()
        // After reset, prior contexts are gone — the third distinct context alone
        // does NOT graduate (count restarts).
        XCTAssertEqual(t.admit(token: "deploy", previous: "npm", count: 1), [])
    }

    func testBoundEvictsOldestPendingToken() {
        var t = GraduationTier(threshold: 3, maxTracked: 2)
        _ = t.admit(token: "a", previous: "x", count: 1)   // pending {a}
        _ = t.admit(token: "b", previous: "x", count: 1)   // pending {a,b}
        _ = t.admit(token: "c", previous: "x", count: 1)   // inserts c → evicts a (oldest)
        // "a" was evicted: its single prior context is gone, so re-admitting two more
        // distinct contexts for "a" is only 2 → still defers (proves eviction happened).
        _ = t.admit(token: "a", previous: "y", count: 1)   // a: {y}
        XCTAssertEqual(t.admit(token: "a", previous: "z", count: 1), [])  // a: {y,z} = 2 < 3
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter GraduationTierTests`
Expected: FAIL — `cannot find 'GraduationTier'` / `'GraduatedOccurrence'`.

- [ ] **Step 3: Implement `GraduationTier`**

Create `Sources/SemicolynKit/Predictor/GraduationTier.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// One occurrence to persist into the learned store when a token graduates (or,
/// post-graduation, passes straight through). Mirrors the `record(token, count,
/// after: previous)` shape the engine already uses.
public struct GraduatedOccurrence: Equatable, Sendable {
    public let token: String
    public let previous: String?
    public let count: UInt32
    public init(token: String, previous: String?, count: UInt32) {
        self.token = token; self.previous = previous; self.count = count
    }
}

/// L6 frequency-graduation tier (pure, ephemeral, never persisted). A token does
/// not enter the persistent learned vocabulary on first sight: it must recur across
/// ≥ `threshold` DISTINCT preceding-token contexts, OR be typed ≥ `threshold` times
/// at start-of-line (`previous == nil`), first. A password typed at a prompt has a
/// non-nil preceding word, so it needs N *distinct* contexts → a once/few-typed
/// password (even a low-entropy human one L5 can't match) never graduates; a bare
/// command repeated at the prompt graduates via the nil count (utility).
///
/// On graduation the accumulated pre-graduation occurrences are BACKFILLED (returned
/// all at once) so frequency ranking reflects the true history. Bounded by
/// `maxTracked` (oldest-pending eviction) so a long/hostile session can't grow it
/// unboundedly; eviction only ever DELAYS learning (safe).
public struct GraduationTier: Equatable, Sendable {
    /// Tokens that have crossed the threshold — record directly, no deferral.
    private var graduated: Set<String> = []
    /// Un-graduated tokens → their distinct `previous` contexts → accumulated count.
    private var pending: [String: [String?: UInt32]] = [:]
    /// Insertion order of pending token keys, for oldest-first eviction.
    private var pendingOrder: [String] = []
    private let threshold: Int
    private let maxTracked: Int

    public init(threshold: Int = 3, maxTracked: Int = 4096) {
        self.threshold = max(1, threshold)
        self.maxTracked = max(1, maxTracked)
    }

    /// Admit one observed occurrence. Returns the occurrences to persist NOW: empty
    /// while the token is still deferred; on the graduating call, every accumulated
    /// occurrence (backfill); post-graduation, just this occurrence.
    public mutating func admit(token: String, previous: String?, count: UInt32) -> [GraduatedOccurrence] {
        if graduated.contains(token) {
            return [GraduatedOccurrence(token: token, previous: previous, count: count)]
        }
        if pending[token] == nil {
            evictIfNeeded()
            pending[token] = [:]
            pendingOrder.append(token)
        }
        pending[token]![previous, default: 0] += count

        let contexts = pending[token]!
        // Combined predicate: ≥N distinct preceding tokens, OR ≥N start-of-line
        // (nil) occurrences. A bare command repeated at the prompt graduates via the
        // nil count; a prompt-secret (non-nil preceding word) needs N distinct
        // contexts and so a once/few-typed password never graduates.
        let graduates = contexts.count >= threshold || (contexts[nil] ?? 0) >= UInt32(threshold)
        guard graduates else { return [] }
        // Graduate: flush the backfill, promote, drop from pending.
        let flushed = contexts.map { GraduatedOccurrence(token: token, previous: $0.key, count: $0.value) }
        graduated.insert(token)
        pending[token] = nil
        pendingOrder.removeAll { $0 == token }
        return flushed
    }

    /// Clear all ephemeral state (context/incognito/host switch). Graduated tokens
    /// are also forgotten — this is a session-scoped tier; the persistent store holds
    /// what already graduated.
    public mutating func reset() {
        graduated.removeAll()
        pending.removeAll()
        pendingOrder.removeAll()
    }

    /// Evict the oldest pending token if at capacity, to bound memory. Only delays
    /// learning for the evicted token (safe).
    private mutating func evictIfNeeded() {
        guard pending.count >= maxTracked, let oldest = pendingOrder.first else { return }
        pending[oldest] = nil
        pendingOrder.removeFirst()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter GraduationTierTests`
Expected: PASS — all 7 graduation tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Predictor/GraduationTier.swift Tests/SemicolynKitTests/GraduationTierTests.swift
git commit -m "feat(predictor): L6 GraduationTier pure unit (N-distinct-context deferral + backfill)"
```

---

## Task 4: Wire `GraduationTier` into `PredictorEngine.record`

Interpose the tier between the L5 filter guard and the persistent-store writes. `record` becomes: filter-guard → `admit` → for each returned occurrence, write to `learned.unigram`/`learned.bigram`. Add a `resetGraduation()` for context switches, and remove the superseded leading-space `TODO` (Phase 2 handled it).

**Files:**
- Modify: `Sources/SemicolynKit/Predictor/PredictorEngine.swift`
- Test: the existing engine test file (find it: `Tests/SemicolynKitTests/PredictorEngineTests.swift` or similar — if absent, create it).

**Interfaces:**
- Consumes: `GraduationTier`, `GraduatedOccurrence` (Task 3); existing `learned.unigram.record`/`learned.bigram.record`, `filter.excludes`.
- Produces: `record` now defers via L6; new `public mutating func resetGraduation()`. `state`/`suggestions`/`harvest`/`rollover` unchanged. `LearnedState` (persisted) is UNCHANGED — the tier is not part of it.

**Design note — where the writes go.** A `GraduatedOccurrence` carries `(token, previous, count)`. The existing `record` writes `learned.unigram.record(token, count:)` always, and `learned.bigram.record(previous:next:token:count:)` when `previous` is non-nil and not filter-excluded. Preserve that exactly per flushed occurrence. The L5 filter guard on `token` stays at the TOP of `record` (a filtered token never even enters the tier). The `previous`-exclusion check moves to the per-occurrence bigram write (unchanged logic).

- [ ] **Step 1: Write the failing test**

Find the engine test file first: `ls Tests/SemicolynKitTests/ | grep -i predictorengine`. Append (or create `PredictorEngineTests.swift` with the SPDX header + `import XCTest` + `@testable import SemicolynKit`):

```swift
    // MARK: - L6 frequency graduation through the engine

    /// Build a seedless engine on an empty learned state.
    private func freshEngine() -> PredictorEngine {
        PredictorEngine(learned: .empty, seed: nil)
    }

    func testTokenNotLearnedBeforeThreeDistinctContexts() {
        var e = freshEngine()
        e.record("hunter2", after: "sudo")           // ctx 1 (one-off password)
        // A single-context token must NOT be suggestable from the learned store.
        // Prefix "hunter" should yield nothing learned (no seed, no harvest).
        XCTAssertFalse(e.suggestions(forPrefix: "hunter", after: nil).contains("hunter2"))
        XCTAssertFalse(e.suggestions(forPrefix: "hunter", after: "sudo").contains("hunter2"))
    }

    func testTokenLearnedAfterThreeDistinctContexts() {
        var e = freshEngine()
        e.record("deploy", after: "git")             // ctx 1
        e.record("deploy", after: "make")            // ctx 2
        e.record("deploy", after: "npm")             // ctx 3 → graduates
        // Now "deploy" is in the learned unigram store and suggestable.
        XCTAssertTrue(e.suggestions(forPrefix: "dep", after: nil).contains("deploy"))
    }

    func testGraduationBackfillsBigramContexts() {
        var e = freshEngine()
        e.record("deploy", after: "git")             // ctx 1
        e.record("deploy", after: "make")            // ctx 2
        e.record("deploy", after: "npm")             // ctx 3 → graduates, backfills all 3
        // A backfilled bigram context is suggestable: after "git", "deploy" ranks.
        XCTAssertTrue(e.suggestions(forPrefix: "dep", after: "git").contains("deploy"))
    }

    func testFilterExcludedTokenNeverEntersTierOrStore() {
        var e = freshEngine()
        // ghp_ is L5-excluded → filtered at the top of record, never graduates even
        // across many distinct contexts.
        e.record("ghp_secretA", after: "a")
        e.record("ghp_secretA", after: "b")
        e.record("ghp_secretA", after: "c")
        e.record("ghp_secretA", after: "d")
        XCTAssertFalse(e.suggestions(forPrefix: "ghp", after: nil).contains("ghp_secretA"))
    }

    func testResetGraduationClearsDeferredCounts() {
        var e = freshEngine()
        e.record("deploy", after: "git")
        e.record("deploy", after: "make")
        e.resetGraduation()
        e.record("deploy", after: "npm")             // only 1 context post-reset
        XCTAssertFalse(e.suggestions(forPrefix: "dep", after: nil).contains("deploy"))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PredictorEngineTests`
Expected: FAIL — `testTokenNotLearnedBeforeThreeDistinctContexts` fails (today `record` writes immediately → "deploy"/"hunter2" learned on first sight); `resetGraduation` undefined.

- [ ] **Step 3: Wire the tier into the engine**

In `Sources/SemicolynKit/Predictor/PredictorEngine.swift`:

Add a stored property after `output`:

```swift
    /// L6 frequency-graduation tier — ephemeral, never persisted (not part of
    /// `LearnedState`). Defers learning until a token recurs across N distinct
    /// contexts, so a once-typed secret never enters the suggestable store.
    private var graduation = GraduationTier()
```

Delete the `// TODO(predictor): leading-space opt-out` comment block (lines ~36–41) — Phase 2's L4a `InputTokenTracker.lineOptedOut` handles it upstream.

Replace `record`:

```swift
    public mutating func record(_ token: String, count: UInt32 = 1, after previous: String? = nil) {
        guard !filter.excludes(token) else { return }
        // L6: defer until the token has recurred across N distinct contexts. `admit`
        // returns the occurrences to persist now (empty while deferred; the full
        // backfill on graduation; just this one once already graduated).
        for occ in graduation.admit(token: token, previous: previous, count: count) {
            learned.unigram.record(occ.token, count: occ.count)
            if let prev = occ.previous, !filter.excludes(prev) {
                learned.bigram.record(previous: prev, next: occ.token, count: occ.count)
            }
        }
    }

    /// Clear the ephemeral graduation tier (context/host switch / incognito). The
    /// persistent learned store is untouched — only un-graduated deferrals are lost.
    public mutating func resetGraduation() {
        graduation.reset()
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PredictorEngineTests`
Expected: PASS — the new L6 engine tests, AND all pre-existing engine tests stay green (a pre-existing test that recorded a token once and expected it suggestable would now need three contexts — see Step 4a).

- [ ] **Step 4a: Migrate the pre-existing engine tests broken by deferral (explicit list)**

L6 deferral legitimately changes `record`'s behavior: a token no longer learns until it graduates (≥3 distinct contexts OR ≥3 nil occurrences). Several pre-existing `PredictorEngineTests` record a token `<3` times in one context and assert it's learned — those now fail correctly. These tests validate OTHER subsystems (unigram ranking, bigram, rollover, persistence), so the fix is to give each token enough occurrences to graduate **without changing what the test asserts**. Apply exactly these migrations (the ONLY tests that break; verified against the current file). The graduation-safe idiom: for a UNIGRAM token, record it `≥3×` at start-of-line (nil) — it graduates via `nilCount`. For a BIGRAM `X after Y` assertion, first graduate `X` via 3 nil occurrences, THEN record the `Y`-context occurrences (which, once `X` is graduated, record directly).

| Test | Current setup | Migrate to | Why intent preserved |
|---|---|---|---|
| `testLearnedUnigramSuggested` | `claude`×3, `crayon`×2 | `claude`×3 (nil, graduates), `crayon`×3 (nil, graduates) | Still tests unigram frequency ranking claude>crayon; give crayon a 3rd nil sighting (bump `0..<2` → `0..<3`). Ranking still holds (claude count ≥ crayon). |
| `testSeedlessEngineStillSuggestsFromLearned` | `deploy`×2 (nil) | `deploy`×3 (nil) | Still tests seedless learned suggestion; `deploy` now graduates. |
| `testLearnedNextTokenSuggested` | `status`×3, `commit`×2 after `git` | graduate each via 3 nil first, then record after `git`: `for _ in 0..<3 { e.record("status") }; for _ in 0..<3 { e.record("status", after:"git") }` and same for `commit` (2 → keep ≥ floor; graduate commit via 3 nil first) | Tests bigram ranking after `git`; graduating the tokens first lets the after-`git` records persist. Keep the relative counts so status outranks commit. |
| `testLearnedNextTokenOutranksSeed` | `commit`×3 after `git` | graduate `commit` via 3 nil first, then `commit`×3 after `git` | Tests learned git→commit outranking seed git→status; unchanged assertion. |
| `testEmptyPreviousFallsBackToUnigram` | `deploy`×2 (nil) | `deploy`×3 (nil) | Tests empty-previous → unigram fallback; `deploy` graduates via nil. |
| `testExcludedPreviousSuppressesAdjacencyButNotUnigram` | `deploy`×2 after `secret-token` | graduate `deploy` via 3 nil first, then `deploy`×2 after `secret-token` | Tests that an excluded `previous` suppresses adjacency but the unigram survives; graduate `deploy` so the unigram assertion holds, the excluded-previous adjacency is still suppressed. |
| `testRolloverPreservesInWindowSuggestions` | `deploy`×2 (nil) | `deploy`×3 (nil) | Tests rollover preserves suggestions; `deploy` graduates via nil. |
| `testStateExposesLearnedForPersistence` | `status` once after `git` | graduate `status` via 3 nil first, then `status` after `git` | Tests `state` exposes the learned bigram; graduating first lets the git→status bigram persist into `state`. |

`testExcludedTokenNeverLearned`, `testExcludedNextTokenSuppressesBothAxes`, `testSeedNextTokenSurfacesWhenUserHasNoHistory`, `testSeedFillsUnigramWhenLearnedEmpty`, `testTopKConfigCapsResults` (seed/harvest/exclusion paths) are UNAFFECTED — do not touch them (L6 gates only learning; an excluded token never reaches the tier).

> IMPORTANT: do NOT weaken any assertion. Each migration only changes the SETUP (more occurrences to graduate the token); the `XCTAssertEqual(...)` expectations stay identical. If bumping counts perturbs a frequency-ranking expectation, keep the RELATIVE ordering the test asserts (e.g. give both tokens the same +1 nil bump). Report each changed test + its before/after setup so the reviewer confirms the intent is preserved, not masked.

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PredictorEngineTests`
Expected: PASS — the new L6 tests + all migrated pre-existing tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Predictor/PredictorEngine.swift Tests/SemicolynKitTests/PredictorEngineTests.swift
git commit -m "feat(predictor): L6 gate record() behind GraduationTier (defer until N contexts)"
```

---

## Task 5: Wire `resetGraduation()` into the App context-switch path (macOS-CI-only)

The engine already resets on host/context switches (where `tracker.reset()` / `passwordDetector.reset()` are called). Add `resetGraduation()` alongside so a host switch drops un-graduated deferrals (consistent with the ephemeral, per-context intent). App-tier — macOS-CI-verified.

**Files:**
- Modify: `App/ConnectionViewModel.swift` (the teardown / context-switch site around `:312`/`:331` where `tracker.reset()` and `passwordDetector.reset()` are called).

**Interfaces:**
- Consumes: `engine?.resetGraduation()` (Task 4).
- Produces: none (behavior only).

**Design note.** Find where the predictor context is cleared on a session/host switch — the same block that calls `tracker.reset()` + `passwordDetector.reset()` + `flushPredictor()`. Add `engine?.resetGraduation()` there. If `engine` is the `PredictorEngine?` stored on the VM, call it directly; the graduation tier is per-engine so this is the natural reset point.

- [ ] **Step 1: Add the reset call**

In `App/ConnectionViewModel.swift`, locate the teardown/reset block that already contains `tracker.reset()` and `passwordDetector.reset()` (near `:311`). Add immediately after `passwordDetector.reset()`:

```swift
        engine?.resetGraduation()          // drop un-graduated L6 deferrals on context switch
```

> If the engine is stored under a different name or the reset happens in a different method, add the call at the same site as the other predictor resets. Keep it to this one line — no other change.

- [ ] **Step 2: Verify via macOS CI (no local App build)**

Commit, push, and rely on the macOS CI job (the App tier does not build on Linux):

```bash
git add App/ConnectionViewModel.swift
git commit -m "feat(app): reset L6 graduation tier on predictor context switch"
git push github feat/predictor-secret-exclusion-phase3
```

Open the PR (CI triggers on PR here) or, if already open, watch the run. Expected: `linux-swift` green (no Kit change this task), `macos` compiles the one-line addition.

- [ ] **Step 3: Commit** (done in Step 2)

---

## Task 6: Full-suite regression + spec bookkeeping

**Files:**
- Modify: `docs/superpowers/specs/2026-07-04-predictor-secret-exclusion-design.md` (Phasing note).

- [ ] **Step 1: Run the full Kit suite**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS — entire SemicolynKit + SeedKit suite green (prior suite + new L5/L6 tests + any updated engine tests).

- [ ] **Step 2: Record Phase 3 completion in the spec**

In `docs/superpowers/specs/2026-07-04-predictor-secret-exclusion-design.md`, under `## Phasing`, append to the phase-3 bullet:

```
3. **L5 pattern extension + L6 frequency graduation** — the format-agnostic catch-all;
   L6 also unlocks forget-last-line. **IMPLEMENTED (Phase 3, plan
   `docs/superpowers/plans/2026-07-05-predictor-secret-exclusion-phase3-pattern-graduation.md`):**
   L5 = curated credential-format prefixes + structural JWT/PEM in `TokenFilter`;
   L6 = `GraduationTier` (ephemeral, never-persisted; N=3 distinct-context deferral +
   backfill) gating `PredictorEngine.record`. Next: Phase 4 (L7 storage + forget tools).
```

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-07-04-predictor-secret-exclusion-design.md
git commit -m "docs(spec): mark predictor secret-exclusion Phase 3 (L5+L6) implemented"
```

---

## Self-Review

**Spec coverage (L5 + L6 sections):**

| Spec requirement | Task |
|---|---|
| L5 lift AWS `AKIA`/`ASIA`, Google `AIza`, Stripe `sk_live_`/`rk_live_`, Slack `xox[baprs]-`, `github_pat_` | Task 1 |
| L5 JWT (`eyJ…` three-segment) + PEM private-key header | Task 2 |
| L5 entropy algorithm unchanged | Tasks 1–2 (only patterns/structural added) |
| L5 known limit (human passwords uncatchable) → motivates L6 | Task 3/4 (L6 catches them) |
| L6 token deferred until ≥ N distinct contexts OR ≥ N nil occurrences (N=3) | Tasks 3 + 4 |
| L6 "distinct context" = distinct preceding token; same non-nil context replayed doesn't over-count | Task 3 (`testSameNonNilContextReplayedDoesNotGraduate`) |
| L6 nil-special refinement: repeated start-of-line graduates via nilCount (utility); prompt-secret (non-nil) still needs N distinct contexts (protection) | Task 3 (`testRepeatedStartOfLineGraduatesViaNilCount`, `testSameNonNilContextReplayedDoesNotGraduate`) |
| L6 ephemeral in-session tier, never persisted | Task 3 (not in `LearnedState`) + Task 4 (engine field outside `state`) |
| L6 graduation backfills accumulated occurrences | Task 3 (`testGraduatesOnNthDistinctContextWithBackfill`) + Task 4 (bigram backfill) |
| L6 gates learning only; suggestions (seed/harvest) immediate | Task 4 (filter/harvest/seed paths untouched; only `record` deferred) |
| L6 bounded ephemeral tier | Task 3 (`maxTracked` + eviction) |
| L6 reset on context switch | Task 4 (`resetGraduation`) + Task 5 (App wiring) |

**Placeholder scan:** no TBD/TODO left as work (the one code TODO removed is the superseded leading-space note); every code step shows complete code; Task 4a explicitly handles pre-existing-test breakage with a concrete rule (record across 3 contexts, never weaken the assertion) rather than "fix tests".

**Type consistency:** `GraduationTier`/`GraduatedOccurrence` with `admit(token:previous:count:) -> [GraduatedOccurrence]`, `reset()`, `resetGraduation()`, `threshold`/`maxTracked`, `pending`/`graduated`/`pendingOrder`, `isStructuredSecret`/`isBase64URL` are used identically across Tasks 3–5. `record`'s per-occurrence write matches the existing `learned.unigram.record`/`learned.bigram.record` signatures.

**Fresh-eyes note:** Task 4 deferral is a real behavior change to `record` — Task 4a is called out explicitly because pre-existing engine tests that recorded-once-then-asserted-learned WILL break and must be updated to reflect graduation (not weakened), with the implementer reporting each change for the reviewer to confirm.
