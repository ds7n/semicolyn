<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Full Code + Security Review — Plan (execute on Fable 5)

**Purpose:** A single, high-signal review of the semicolyn codebase before broader TestFlight
testing. Two lenses over the same code: **(A) security** (trust decisions, secrets, auth,
untrusted-input handling) and **(B) correctness/quality** (bugs, concurrency, reuse, dead code).

**Why this plan exists:** planned in Opus (cheap, high-leverage) so the Fable run is *targeted* —
no wandering the whole tree, no generic checklists. Fable reviews **specific files against their
own locked specs and stated invariants.** On the $100 plan, tokens are spent where they change the
answer.

**Model routing:** Run the whole review on **Fable 5** (most capable; strongest at bug-finding).
Fable's safety classifiers target cybersecurity content and can false-positive on legitimate
security probes → a `stop_reason: "refusal"`. If a security section refuses, **re-run that section
on Opus 4.8** (note it in the output). Do not let a refusal silently drop a section.

---

## Ground truth the review measures against (READ FIRST, don't re-derive)

The value of this review is checking the implementation against its **locked specs**, not against
a generic OWASP list. Before reviewing a subsystem, read its spec:

| Subsystem | Spec | The invariant to verify |
|---|---|---|
| Host-key trust (TOFU) | `docs/superpowers/specs/2026-06-17-host-key-trust-design.md` | First-trust prompt is real; a **mismatch is never silently accepted**; trust is written only after an explicit accept; fail-closed on prompt dismissal |
| SSH cert auth | `docs/superpowers/specs/2026-06-17-ssh-cert-auth-design.md` | No silent downgrade; a present-but-rejected cert/key returns its outcome, not a password fallback |
| Chain auth (ProxyJump) | `docs/superpowers/specs/2026-06-17-chain-auth-design.md` | Each hop's host key is verified; no hop bypasses trust |
| Identities / keys | `docs/superpowers/specs/2026-06-15-identities-keys-management-design.md` | Private keys live in Keychain; never logged, never shell-interpolated; SE-flavor deferral is honored |
| SSH algorithms | `docs/superpowers/specs/2026-06-17-ssh-algorithms-design.md` | No weak/deprecated algorithms silently enabled; `allowLegacy`/`allowDeprecated` gates are honored |
| Testing standards | `docs/superpowers/specs/2026-06-18-testing-standards-design.md` | Tests are real (EP+BVA, assert specific values, negative tests assert the *specific* failure) — used to judge whether a "tested" claim is trustworthy |

**Also load:** `CLAUDE.md` (tier rules: Kit = pure/Linux-tested, App = Apple-only), and
`docs/brainstorming-decisions.md` if a decision's rationale is in question.

---

## Scope — the files that matter, by risk tier

Do **not** review generated code, `extern/mosh` (vendored upstream), tests-as-targets, or theme/UI
cosmetics. Focus budget on the trust/auth/secret/concurrency surface.

### Tier 1 — SECURITY-CRITICAL (deepest scrutiny; adversarial)

Rust SSH core:
- `crates/semicolyn-ssh-core/src/connection.rs` (785 L) — host-key verify callback, auth flow, channel lifecycle
- `crates/semicolyn-ssh-core/src/keys.rs` (207 L) — key parsing/loading
- `crates/semicolyn-ssh-core/src/algorithms.rs` (307 L) — algorithm allow/deny gates
- `crates/semicolyn-ssh-core/src/forward.rs` (355 L) — port-forward / proxyjump plumbing

Kit trust + secrets:
- `Sources/SemicolynKit/Storage/HostKeyTrustEvaluator.swift` — the TOFU decision logic (`.trusted`/`.firstTrust`/`.mismatch`)
- `Sources/SemicolynKit/Storage/HostKeyStore.swift`, `Fingerprint.swift`
- `Sources/SemicolynKit/Storage/KeychainSecretStore.swift`, `SecretStore.swift`, `IdentityService.swift`
- `Sources/SemicolynKit/Crypto/RecordEnvelope.swift`, `Storage/EncryptedRecordStore.swift`

App trust/auth wiring:
- `App/Bridges.swift` — `TofuHostKeyVerifier` (Rust trust callback → SwiftUI prompt; **fail-closed on dismissal** is the load-bearing property)
- `App/ConnectionViewModel.swift` — `authenticate()` precedence (key > password, no silent fallback), Mosh key handling (opaque bytes, no shell interpolation), session teardown
- `App/CoreIdentityMinter.swift`, `App/HostKeyPrompt.swift`

### Tier 2 — CORE CORRECTNESS/CONCURRENCY (thorough)

- `App/Mosh/MoshSession.mm` (396 L) — **the one place with hand-rolled pthread/fd concurrency.** Verify the ownership model in its header comment actually holds: single-mutex, join-before-close, no fd-reuse race, `onFirstFrame`/`onEnd` fire-once, no callback-after-stop. Adversarial: can any interleaving double-close an fd or fire a callback after `-stop`?
- `App/ConnectionViewModel.swift` — the `@MainActor` connect state machine; the new pre-frame Mosh fallback; the harvest-path race flagged (predictor-only) in PR #40 — confirm it's benign
- `Sources/SemicolynKit/Tmux/ControlModeParser.swift` (222 L) — parses **untrusted server output**; verify no panic/overflow on malformed control-mode input (injection-adjacent)
- `Sources/SemicolynKit/Model/Resolution.swift` — the `Inherited` three-state resolution (a wrong resolve = wrong host/user/key used); `credentialResolution` (just added)
- `App/Bridges.swift` `TerminalShellOutput` + `Sources/SemicolynKit/Terminal/PendingOutputBuffer.swift` — the just-added buffering; verify no re-entrancy / lost-flush

### Tier 3 — SUPPORTING (lighter; reuse/simplification/dead-code lens)

- `App/SessionView.swift`, `App/TerminalScreen.swift`, `App/TmuxPaneContainer.swift`
- `Sources/SemicolynKit/Storage/HostStore.swift`, `Model/Host.swift`, `Model/HostFormValidation.swift`
- Predictor privacy: `Sources/SemicolynKit/Predictor/TokenFilter.swift` + `…privacy-filter-design.md` (does the predictor ever learn a password/secret typed at a prompt?)

---

## The two review passes

### Pass A — Security (Tier 1 + the untrusted-input parts of Tier 2)

For each Tier-1 file, answer these **specific** questions (not "is it secure?"):

1. **Host-key trust:** Trace the Rust `verify` callback → `TofuHostKeyVerifier.verify` → prompt →
   storage. Can a **mismatch** ever return `true` without an explicit user accept? What happens if
   the prompt sheet is **dismissed** (not answered)? (Spec says fail-closed — verify `onDismiss`.)
   Is the stored fingerprint compared correctly (constant-time not required, but exact-match yes)?
2. **No silent auth downgrade:** In `authenticate()`, if a host has a key and the server **rejects**
   it, does the code fall back to password? (Spec: it must NOT.) Is `AuthOutcome` mapped faithfully?
3. **Secret handling:** Grep every path a private key / password / mosh session-key flows through.
   Is any of them **logged** (`print`, `os_log`, `NSLog`, `debugPrint`, `dump`)? **Shell-interpolated**
   into a command string (mosh bootstrap, tmux)? Written to disk outside Keychain? The mosh key must
   be treated as **opaque untrusted bytes**.
4. **Algorithm gates:** Can a weak/deprecated algorithm be negotiated when `allowLegacy=false` /
   `allowDeprecated=false`? Are the defaults conservative?
5. **Chain/forward:** For ProxyJump, is **each hop's** host key verified, or only the final target?
6. **Untrusted server output:** `ControlModeParser` + terminal feed — can malformed server bytes
   panic, overflow, over-allocate, or escape into a trust decision? (Terminal escape injection,
   OSC 52 clipboard abuse — is OSC 52 gated by `osc52Allowed`?)
7. **Adversarial catalog** (per testing-standards spec): for each trust/auth unit, is there a
   **negative test** for tampering, wrong-key, downgrade, mismatch/replay, malformed-input? If the
   code claims "tested," judge the tests against the standard — a tautological test = untested.

### Pass B — Correctness / quality (Tier 2 + Tier 3)

1. **MoshSession.mm concurrency (highest priority):** Read the ownership-model comment, then try to
   **break it** by hand: enumerate the thread interleavings of `-start` / `-writeInput:` / `-stop` /
   `runMoshLoop` exit / `runReaderLoop` exit. Find any double-close, use-after-close, callback-after-stop,
   or missed-join. This is the single riskiest file for a real crash.
2. **State-machine correctness:** `ConnectionViewModel` connect flow — can it land in `.shell` with no
   working I/O path? Double-connect? The pre-frame fallback Task — does it race the connect Task?
3. **Resolution correctness:** `Inherited` three-state — any place using `.value` where it must use
   `resolveOptional` (the documented footgun)? A wrong resolve silently uses the wrong host/user/key.
4. **The just-shipped fixes:** `PendingOutputBuffer` (re-entrancy? lost flush on detach/reattach?),
   `credentialResolution` (precedence matches `authenticate`?), first-responder (fights the user?).
5. **Reuse / simplification / dead code:** flag duplication, unreachable branches, `TODO(phase4)`
   stragglers, and anything the app-tier does that Kit already does.

---

## Output format (what Fable returns)

A single prioritized findings report — **not** a file-by-file dump. For each finding:

- **Severity:** Critical (exploitable trust/auth/secret bug or a real crash) / Important (correctness
  bug, weakened invariant, missing negative test on a security unit) / Minor (reuse/dead-code/style).
- **Location:** `file:line`.
- **Claim + evidence:** what's wrong and the exact code path that proves it. **No hand-waving** —
  if it's a race, give the interleaving; if it's a downgrade, give the fallback line.
- **Spec conflict (if any):** which locked invariant it violates.
- **Fix sketch:** one or two lines. Do **not** apply fixes in the review pass.

**Ordering:** Critical → Important → Minor. Security findings before quality findings at equal severity.

**Adversarial self-check before returning:** for each Critical/Important, ask "would this actually
fire at runtime, or is it theoretical?" Drop or downgrade the theoretical ones and say so. A short
list of *real* findings beats a long list of maybes.

---

## Execution notes

- **Read specs before code** for each subsystem (the table above). The whole point is spec-vs-impl.
- **Tier the effort:** Tier 1 gets `xhigh`/`max`-level scrutiny; Tier 3 gets a quick reuse/dead-code pass.
- **Linux-testable claims are checkable now** (`docker compose run --rm dev swift test`, `cargo test`);
  App-tier is macOS-CI-only, so reason about it statically.
- **If a security section refuses on Fable** (`stop_reason: refusal`), re-run that section on Opus 4.8
  and mark it in the report. Never drop a refused section silently.
- **Do not fix in this pass.** Produce the report; fixes are a separate, reviewed step.
