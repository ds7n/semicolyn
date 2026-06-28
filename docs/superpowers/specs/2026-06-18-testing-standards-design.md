# Testing Standards

**Date:** 2026-06-18
**Status:** Locked
**Applies to:** all Semicolyn development — existing tests (backfill audit) and future work, Rust and Swift.

## Goal

Make every test **valid** (it exercises real behavior) and **complete** (good *and* bad cases for all major functionality, user interaction, and security). The guiding invariant:

> **A test is real if and only if it would FAIL when the implementation is wrong.**

A test that passes against a broken implementation is worse than no test — it manufactures false confidence. This standard exists to prevent that.

## Methodology

Four complementary techniques, each covering a gap the others leave:

1. **Equivalence Partitioning (EP)** — divide the input/state space into classes that *should* behave identically; test one representative per class. Always include **invalid** partitions, not just valid ones. This is the source of "good and bad cases."
2. **Boundary Value Analysis (BVA)** — bugs cluster at partition edges. For each boundary, test `min`, `min−1`, `max`, `max+1` (and the exact boundary). EP alone tests the middle of a range and misses off-by-one errors.
3. **Adversarial cases** — for security surfaces, the "bad cases" are *crafted attacks*, not merely out-of-range inputs: tampering, downgrade, replay, trust violation, malformed data. These get explicit enumeration (see Adversarial Catalog).
4. **Anti-tautology rule** — assertion quality is orthogonal to input selection. A test can partition perfectly and still assert nothing meaningful. The rule (below) governs *what* a test asserts; mutation testing is its objective backstop.

## Risk tiers

Rigor scales with consequence. Classify every testable unit into exactly one tier, then meet its minimum.

| Tier | What qualifies | Required techniques | Minimum cases | Mutation tested |
|---|---|---|---|---|
| **Critical** | security, cryptography, authentication, SSH protocol negotiation, trust decisions | EP + BVA + **adversarial** | ≥1 negative per applicable attack vector, plus valid-path coverage | **Yes** — `cargo-mutants`, no surviving mutants |
| **Core** | major features, user interactions, non-trivial business logic | EP + BVA | good **and** bad cases for every partition | No (rule only) |
| **Trivial** | pure helpers, DTO/`Codable` round-trips, simple getters | at least one real behavior or round-trip assertion | ≥1 (never zero) | No |

**Classification examples (current code):**

- **Critical:** `algorithms::build_preferred` / `is_tier3` (allowlist), `RecordEnvelope` (crypto), `HostKeyVerifier` + `check_server_key` (trust), `AuthOutcome` / `authenticate_*` (auth), `kex_done` Tier-3 detection.
- **Core:** `resolvePort` / `hasCycle` (resolution + cycle detection), `Inherited<T>` inherit-vs-explicit-none semantics, `ThemeColor.rgba()` hex parsing.
- **Trivial:** `ThemeColor.alpha`, `Host`/`Identity` `Codable` round-trips.

When in doubt between two tiers, pick the higher one.

## The anti-tautology rule

Every test must satisfy all of the following. These are review-gating.

- **Assert on observable output or state** — never merely that a call returned, that no panic occurred, or that a `Result` is `Ok`/`Err` without checking *which*.
- **Prefer exact expected values** over weak predicates (`contains`, `is_ok`, non-empty, "greater than zero") wherever the expected value is knowable. Exact-equality assertions catch drops, reorders, and typos that membership checks miss.
  - *Precedent:* the algorithm allowlist asserts the **full ordered vector** per category per toggle combination, not `contains("mlkem768x25519-sha256")`.
- **Every negative test asserts the *specific* failure** — the exact error variant or message, not "it errored." `assert!(matches!(err, ConnectError::HostKeyRejected))`, not `assert!(result.is_err())`.
- **Test doubles drive a real assertion about the system-under-test (SUT)** — a fake that returns a fixed value is a legitimate *fixture*, but the test must assert what the SUT *did* given that value, never assert the fake's own return.
  - *Precedent:* `RecordingVerifier` returns a fixed trust decision **and records the `HostKeyInfo` it was shown**; the test asserts the fingerprint the SUT presented (`starts_with("SHA256:")`), not that the fake returned `true`.
- **Boundaries are explicit** — a Core/Critical test for a bounded value tests the boundary, not just an interior value.

**Banned smells** (a reviewer rejects these on sight):

- `assert!(true)`, `assert_eq!(x, x)`, asserting a constant against itself.
- A test with no assertions, or whose body still passes when the production call is deleted.
- A "negative" test that only checks `is_err()` / `!= success` without identifying the failure.
- A test whose only assertion is on a mock's return value or call count *without* tying it to SUT behavior.
- Snapshot/golden tests with no mechanism to fail on regression.

## Mutation testing (objective backstop)

For **Critical** Rust modules, the anti-tautology rule is verified objectively, not by eyeballing.

- Tool: **`cargo-mutants`** (`cargo install cargo-mutants --locked`).
- Command (scoped to a module): `cargo mutants -p semicolyn-ssh-core --file crates/semicolyn-ssh-core/src/algorithms.rs`
- A **surviving mutant** (the tool changed the implementation and no test failed) is a concrete test gap. Close it by adding the case that would have caught the mutation.
- **Expectation:** a phase's Critical modules are mutation-clean (no survivors, or every survivor explicitly justified as equivalent/unreachable) before that phase merges to `master`. Run is **on-demand / local** while CI is deferred — it is not yet a CI gate, but it is a merge expectation.
- **Swift:** mutation tooling is immature; Swift Critical code relies on the anti-tautology rule + review only. The same EP/BVA/adversarial *thinking* still applies.

## Adversarial catalog (security "bad cases")

For each **Critical** unit, walk this catalog and write a negative case for every applicable vector. The required behavior is the test's assertion.

| Vector | Required behavior (what the test asserts) | Applies to |
|---|---|---|
| **Tampering** — flip a byte in ciphertext/tag/signature | reject (specific error) | `RecordEnvelope` (have it), cert parsing |
| **Wrong key / credential** | reject, distinctly from "not found" | `RecordEnvelope`, auth |
| **Downgrade / forced-weak** — server offers only weak/dead algos | Tier-4 never offered; Tier-3 negotiated → flagged | allowlist (have it), `kex_done` |
| **Trust violation** — host-key mismatch or delegate rejection | abort with the specific trust error | `HostKeyVerifier` / `connect_core` (have reject path) |
| **Expiry / replay** — expired or not-yet-valid cert | hard-fail, **no** silent fallback to bare key | 1c-cert |
| **Malformed input** — garbage key/cert/fingerprint/host string | typed error, **no panic** | auth, cert, host parsing |
| **Empty / boundary auth** — zero-length password, missing prompt response | handled, never a crash | auth |

The catalog is a floor, not a ceiling — add vectors specific to the unit.

## Workflow integration

Making the standard binding, forward and backward:

1. **Project `CLAUDE.md`** (repo root) carries a concise "Testing standards" rule — the three tiers, the anti-tautology invariant, and "adversarial cases mandatory for Critical" — pointing here for detail. Loaded every session.
2. **`writing-plans`**: every plan task gains a **`Test design:`** line stating *tier · partitions · boundaries · adversarial vectors*, filled in **before** the implementation steps. Test thinking precedes code.
3. **Backfill audit** (one-time): walk the existing Phase 0 / 1a / 1b tests against this standard; record gaps; fix the cheap ones (likely: BVA on `resolvePort` boundaries, an adversarial case or two, any weak predicate that should be exact).
4. **Merge expectation:** a phase's Critical modules satisfy their tier minimum (including mutation-clean) before merge.

## Cross-language summary

| | Rust | Swift |
|---|---|---|
| Runner | `cargo test` (unit + integration) | `swift test` |
| Mutation | `cargo-mutants` on Critical modules | n/a (rule + review) |
| Integration | real `sshd` fixtures — real by construction, but still owe negative cases | UI/integration testing arrives with the macOS-gated phases |

Integration tests against a live server prove the happy path is real, but a real server is **not** a substitute for testing the bad paths (reject, wrong creds, downgrade). Negative cases are required regardless of test layer.

## Out of scope

- **Coverage-percentage targets.** Line/branch coverage is a weak proxy; the tier minimums + mutation testing are the real bar. No coverage gate in v1.
- **CI enforcement.** CI is deferred (see project docs); these are local/merge expectations until CI exists, at which point mutation runs on Critical modules and `swift test`/`cargo test` become gates.
- **Property-based / fuzz testing.** Valuable for parsers (cert, host-key) and a likely future addition, but not required by this standard in v1. Use where it fits; don't mandate yet.
- **Performance/load testing.** Separate concern, not covered here.

## Related

- `docs/superpowers/plans/` — each plan's per-task `Test design:` line operationalizes this standard.
- The algorithm-allowlist exact-ordered tests and the `RecordingVerifier` pattern are the worked precedents this standard generalizes.
