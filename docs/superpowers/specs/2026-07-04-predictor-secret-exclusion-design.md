<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Predictor secret-exclusion — defense-in-depth (design)

**Date:** 2026-07-04
**Status:** DRAFT — design approved section-by-section; awaiting a final read before
implementation-planning. Written durably so work can resume after a context clear.

## Decisions locked (chosen this session — settled, not re-litigable)

- **All 8 layers in scope**, comprehensive in one design (not a focused subset).
- **Reframe governs:** predictor, not scanner — a false positive costs one skipped word,
  a false negative leaks a credential → *exclusion wins ties; filter aggressively.*
- **Echo IS detectable** (the prior "can't detect echo" was half-wrong): L1 buffer-anchored
  check (SSH, all-public SwiftTerm APIs) + L2 mosh prediction-engine state. Only the
  *deterministic SSH-wire flag* is genuinely absent. See the research doc.
- **`EchoOracle` protocol seam** keeps L1's logic pure-Kit/Linux-tested; the SwiftTerm
  adapter is the only Apple-only piece.
- **Alt-screen ⇒ suppress the whole line** (don't learn inside vim/htop; safe default).
- **L4a leading-space opt-out: YES** (shell-`ignorespace` gesture; the power-user "don't
  learn this" escape hatch).
- **L4b denylist: conservative defaults only**, no user-editable rules in v1 (YAGNI).
- **L6 graduation threshold N = 3 across *distinct* contexts** (distinct = different
  preceding token/command; same line replayed does not over-count).
- **L7 keeps the two-tier confidence split** (high-confidence → literal stored for prefix
  completion; low-confidence → lossy count only) — NOT everything-lossy (that would kill
  literal completion for all learned tokens).
- **Both forget tools:** *forget-last-line* is the primary surgical tool (cheap because L6
  defers learning — a regretted line is still un-graduated in the ephemeral tier);
  *panic-purge* is the nuclear fallback (wipes all user-derived state, keeps the static
  seed vocab).
- **Phased into 6 slices; each spec-phase should become its OWN implementation plan** —
  do NOT write one monolithic plan. Start with Phase 1 (L1 + `EchoOracle`).

## Current state (for a cold resume)

- This spec + `docs/superpowers/research/2026-07-04-echo-detection-investigation.md` live
  on branch **`feat/predictor-secret-exclusion`** (off `main`). Nothing implemented yet.
- The shipped **`PasswordEntryDetector`** (`Sources/SemicolynKit/Predictor/`, merged in
  PR #41 on `main`) is the single-signal detector this design UPGRADES (L1), not removes.
- Capture chokepoint today: `observePredictorInput` in `App/ConnectionViewModel.swift`
  (fed by `sendTerminalInput`); output taps `passwordDetector.noteOutput` at the
  raw + tmux harvest sites. `InputTokenTracker` (Kit) reconstructs lines. `PrefixIndex`
  stores literal tokens verbatim (the recoverability problem L7 fixes). Mosh's
  `OverlayManager`/`PredictionEngine` is already instantiated in
  `extern/mosh/src/frontend/iosclient.h` (L2's signal exists on-device, no getter yet).
- Predictor is **local-only** today — no CloudKit sync yet (L8 gates that future).
- **Phase 1 (L1 buffer echo + `EchoOracle` seam) IMPLEMENTED** — plan
  `docs/superpowers/plans/2026-07-04-predictor-secret-exclusion-phase1-echo-oracle.md`.
  **Next step:** invoke `writing-plans` for **Phase 2** (L3 paste + L4 context/leading-space).
**Supersedes-in-part:** the shipped single-signal `PasswordEntryDetector`
(PR #41) — kept and upgraded, not removed.
**Grounded in:** `docs/superpowers/research/2026-07-04-echo-detection-investigation.md`
(what echo signals are actually reachable) and the layered-approach research the user
supplied (`/tmp/x`).
**Related:** `2026-06-21-predictor-privacy-filter-design.md` (the `TokenFilter`
pattern/entropy layer, already shipped), `2026-06-16-icloud-sync-scope-design.md`
(predictor sketches sync default-ON — the future aggravator this design gates).

## Problem & reframe

The keystroke predictor learns tokens from the outgoing input stream, so a password
typed at an in-session prompt (`sudo`, nested `ssh`, `passphrase`, a TUI field) can be
learned into the on-disk vocabulary and surfaced as a suggestion. The shipped
`PasswordEntryDetector` reduces this with a single heuristic (byte-count echo inference
+ prompt-text), but it is one probabilistic layer.

**The reframe that governs every decision here:** we are **not** building a secret
scanner. A scanner agonizes over false positives because a wrong flag creates alert
fatigue. Our predictor never alerts — a false positive costs exactly **one skipped
word**; a false negative **leaks a credential**. That asymmetry means *when in doubt,
don't learn* is nearly free, and we can filter far more aggressively than any scanner
would. **Exclusion wins ties, always.**

## Goal

A layered, defense-in-depth exclusion stack where **no single layer is load-bearing** —
echo detection misses pasted args, paste-detection misses typed secrets, pattern/entropy
misses human-chosen passwords (`Summer2024!`), frequency-gating misses repeated secrets —
so they are stacked and OR-combined toward suppression, with a final storage tier that
makes even a *missed* secret non-recoverable and non-syncable.

## The layers (strongest-per-transport first)

Each layer is independent, testable in isolation, and fails toward exclusion. A token is
learned only if it survives **every** applicable layer.

| # | Layer | What it catches | Transport | Determinism |
|---|---|---|---|---|
| L1 | **Buffer-anchored echo check** (upgrades the current detector) | keystrokes not echoed at the cursor cell (hidden or masked) | SSH (+ mosh) | robust-statistical |
| L2 | **Mosh prediction-engine echo state** | server-not-echoing, validated vs. the real framebuffer | mosh only | high |
| L3 | **Paste exclusion** (bracketed-paste `ESC[200~…201~`) | pasted keys/tokens (`export TOKEN=…`, `curl -H`) — echo-invisible | both | deterministic |
| L4 | **Context / arg-position + leading-space opt-out** | secrets after `-p`/`--password`/`--token`, `Authorization:`, `user:pass@host`; user's explicit "don't learn this line" | both | deterministic |
| L5 | **Pattern + entropy** (existing `TokenFilter`, extended) | known credential formats + high-entropy blobs | both | deterministic |
| L6 | **Frequency graduation** | anything above that slips through — incl. human passwords; a token learns only after recurring across N distinct contexts | both | deterministic |
| L7 | **Non-recoverable storage** | a *missed* secret that graduated anyway — store only lossy counts, never the literal, for low-confidence tokens | both | structural |
| L8 | **Sync-boundary firewall** | cross-device propagation — only the lossy aggregate leaves the device, never the literal index | both | structural |

L1–L2 are the transport-specific echo signals; L3–L6 are echo-independent deterministic
gates; L7–L8 are the "assume everything above failed" structural backstops. The existing
prompt-text suppressor folds into L1 (a corroborating input to the echo verdict).

## Non-goals

- **Perfect detection.** Impossible in principle (a prompt that echoes the secret,
  e.g. `read` without `-s`, is undetectable by any client). The stack drives residual
  leakage low and makes any residual non-recoverable — it does not claim zero.
- **Blocking the user.** No layer ever interrupts typing or blocks a command; the only
  effect of any layer is *not learning* a token.
- **Active probing in v1.** The iTerm2-style space+BS echo probe is invasive (injects
  bytes into a live session) and out of scope; noted as a future confirmation-only option.

---

## L1 — Buffer-anchored echo check (SSH path; also active under mosh)

**Upgrades** the shipped `PasswordEntryDetector`'s byte-count inference into a check
against SwiftTerm's *rendered grid*. Per the research, all APIs are public and the app
already holds `getTerminal()`.

**Mechanism.** Around each outgoing printable keystroke, sample the terminal:
1. Before delivering the keystroke, record the cursor cell `(preRow, preCol)` via
   `getCursorLocation()`.
2. After a bounded settle window (adaptive, ~1 RTT; verdict deferred to line commit —
   never blocks input), read the cell that *would* hold the echo (`getCharData` at/near
   the pre-keystroke cursor) and the new cursor position.
3. Classify, three-way:
   - **echoed** — the typed scalar appears at the expected cell and cursor-x advanced.
   - **masked** — cursor-x advanced but the cell holds a constant mask char (`*`, `•`)
     ≠ the typed scalar → still a secret.
   - **hidden** — cursor did not advance and no cell changed → non-echoing.
   `masked` and `hidden` both count as *not echoed* (secret-bearing).

**Gates (suppress false positives):**
- `isCurrentBufferAlternate == true` → skip the check entirely and **do not learn** the
  line (full-screen TUIs — vim/htop — don't echo 1:1; learning their input is low-value
  and risky). Fail-safe: alt-screen ⇒ suppress.
- **Output liveness** — if no output at all is arriving, an "unechoed" reading is
  ambiguous (network stall vs. real non-echo); bias to suppress.

**Line-level aggregation.** The per-keystroke classification is noisy; the *verdict* is
per committed line: learn the line only if a strong majority of its typed printables
were positively `echoed`. "Near-zero of N printables echoed" is a far stronger statistic
than any single-char timing. This subsumes the current prompt-text suppressor, which
becomes a corroborating input (a `Password:`-style tail ⇒ force the line to non-echoed).

**Two-tier boundary.** The pure `PasswordEntryDetector` (Kit, Linux-tested) must stay
Linux-testable, but buffer inspection needs the live `Terminal` (Apple-only). Resolve
with a small injected **`EchoOracle` protocol** (Kit): `func sampleCell(row:col:) ->
EchoCell?` / `func cursor() -> (row:Int,col:Int)` / `var isAlternateBuffer: Bool`. The
detector consumes the protocol; the App tier provides a `SwiftTermEchoOracle` backed by
`getTerminal()`; Kit tests provide a scripted fake. The detector's *logic* stays pure
and fully unit-tested; only the thin oracle adapter is macOS-CI-only.

## L2 — Mosh prediction-engine echo state (mosh path only)

On the mosh transport, a **stronger** signal exists: mosh's `PredictionEngine` validates
its local-echo predictions against the server's actual framebuffer. At a hidden prompt
every prediction is contradicted → the engine sits `tentative`
(`prediction_epoch > confirmed_epoch`, with `IncorrectOrExpired` culls). This is *why
mosh never local-echoes passwords* — it is high-reliability and immune to the
redraw/timing confounders L1 fights, because it is checked against ground truth.

**Mechanism.** The state exists on-device (our `iosclient` runs the `OverlayManager`);
it has no getter. Add a minimal read-only exposure through the layers we vendor/own:
`PredictionEngine` getter (e.g. `bool serverIsEchoing() const` derived from the
epoch/validity state) → `iOSClient` accessor → `moshiosbridge.cc` C shim →
`MoshSession` Obj-C++ property/callback → Swift. The Mosh path's detector consults this
instead of (or ahead of) L1's buffer check.

**Caveat & fallback.** The signal is only live when the user's mosh prediction mode is
not `Never` (`new_user_byte` returns early otherwise). When prediction is off, the mosh
path **falls back to L1** (buffer-anchored check works under mosh too, since SwiftTerm
still renders the frames). So L2 is a strict *upgrade* where available, never a
single point of failure.

**Scope note.** L2 is the one layer that touches the vendored-mosh patch surface
(`docs/vendor/mosh.md` already documents that we carry first-party patches). It is
macOS-CI-only and validated by the existing `SemicolynBridgeTests` seam plus a new
assertion that the exposed flag flips at a scripted non-echo point.

---

## L3 — Paste exclusion (bracketed paste)

Pasted content is disproportionately secrets (`export TOKEN=…`, `curl -H
"Authorization: …"`, a pasted key) **and** is low-value to predict (you don't need a
suggestion for something you pasted). Critically, pasted secrets are **echo-invisible** —
they're echoed normally as command text, so L1/L2 never flag them. This is the biggest
gap the echo layers leave, closed deterministically.

**Mechanism (pure Kit).** The outgoing stream carries bracketed-paste markers when the
terminal has paste mode on: `ESC[200~` … `ESC[201~` (DEC mode 2004). The input tokenizer
tracks a `withinPaste` flag: on `200~` enter paste, on `201~` exit. **Any token committed
while `withinPaste` is true is never learned** — regardless of what any other layer says.

**Edge cases:**
- Paste markers only appear if the terminal *enabled* bracketed paste (the remote app
  requested it). SwiftTerm forwards them when active. When paste mode is off, a paste
  arrives as raw bytes indistinguishable from typing — L3 can't see it, but the other
  layers still apply (a pasted secret is caught by L5/L6/L7). L3 is a *bonus*
  deterministic catch, not a guarantee.
- A `201~` without a matching `200~` (malformed / split across chunks) fails **closed**:
  an unmatched close is ignored; an unmatched open keeps `withinPaste` set until the
  next `201~` or a line-context reset (ESC/Ctrl-C), suppressing more, never less.

Implemented in the existing `InputTokenTracker` (it already scans outgoing bytes) — add
the paste-marker state machine there so the paste flag rides with each `CommittedToken`.

## L4 — Context / argument-position + leading-space opt-out (pure Kit)

Two deterministic sub-rules, borrowed from shell history hygiene (`HISTCONTROL`
`ignorespace`, `HISTIGNORE`).

**(a) Leading-space opt-out (power-user escape hatch).** If the current line's first
byte is a space, **the whole line is never learned** — the same gesture that keeps a
command out of shell history. Zero-cost, fully under the user's control, and the most
predictable "don't learn this" affordance. (The space is still sent to the remote; many
shells with `ignorespace` also skip it in history, so behavior is consistent.)

**(b) Argument-position denylist.** Reconstructing the line (the tracker already does),
suppress the *value token* that follows a known secret-bearing flag or construct:
- after `-p` / `--password` / `-P` / `--pass` / `--token` / `--api-key` / `--secret` /
  `--passphrase` (case-insensitive, `=`-joined or space-separated: `--token=X` and
  `--token X` both suppress `X`).
- the value in an `Authorization:` / `X-Api-Key:` header argument.
- the `pass` in a `user:pass@host` connection string (suppress the whole credential token).

The denylist is a small typed table (not regex over the whole line), matched against the
tokenized line so it composes with L3/L5. It suppresses **only the value token**, not the
command — `curl` and `--header` are still learnable; the secret value is not.

**Scope:** the flag/construct table ships with a conservative default set (above);
user-editable rules are out of scope for v1 (YAGNI — revisit if asked).

## L5 — Pattern + entropy (existing `TokenFilter`, extended)

Already shipped (`2026-06-21-predictor-privacy-filter-design.md`): `ExcludePattern`
(`ghp_`, `sk-`, `contains("password")`, …) + a Shannon-entropy backstop for
high-randomness strings. **Kept as-is; extended, not redesigned.**

**Extensions:**
- **Lift more known-format patterns** from the well-trodden public credential rulesets
  (gitleaks-style): AWS `AKIA…`/`ASIA…`, Google `AIza…`, Stripe `sk_live_`/`rk_live_`,
  Slack `xox[baprs]-`, `github_pat_`, JWT (`eyJ…` three-segment), PEM headers
  (`-----BEGIN … PRIVATE KEY-----`). A curated, conservative subset — not the full
  150-rule set (most are irrelevant to a terminal predictor and add surface).
- Entropy tuning stays as specified in the existing filter (min-length + bits/char
  threshold); no change to the algorithm.

**Known limit (why L5 alone is insufficient — motivates L6):** human-chosen passwords
(`Summer2024!`, `hunter2`) are **low-entropy and match no pattern**. L5 structurally
cannot catch them. This is the explicit reason the stack does not stop here.

## L6 — Frequency graduation (pure Kit) — the format-agnostic catch-all

The cleanest fit for a *predictor* specifically, and it catches exactly what L1–L5 miss:
low-entropy human passwords, custom-format secrets, one-off pastes that slipped L3.

**Mechanism.** A token does not enter the persistent, *suggestable* vocabulary on first
sight. New tokens live in an **ephemeral in-session tier**; a token **graduates** to the
persistent learned store only after it has recurred **≥ N times across distinct
contexts** (default N = 3; "distinct context" = a different preceding token / command, so
`kubectl get pods` typed thrice counts, but the same full line replayed does not
over-count). Real vocabulary recurs; a password typed once — or one that rotates on each
use — never graduates.

**Interaction with the existing rolling store.** The predictor already has a
`today ⊕ rolling_<window>` structure and a `PrefixIndex`. Graduation inserts a gate
*before* the persistent `PrefixIndex.insert`: the in-session tier is a small
count-by-context map (ephemeral, never persisted); only on reaching the threshold is the
literal token written to the persistent index. Suggestions may still surface from the
seed/known-command vocabulary immediately; only *learned* tokens are gated.

**Why this is the backstop that makes the stack robust:** even if every echo/paste/
pattern layer fails on a given secret, a password is almost never typed ≥ N times across
distinct contexts, so it never becomes a persistent suggestion. Format-agnostic, and it
degrades gracefully (a genuinely-reused non-secret token just takes N sightings to
learn — a minor, safe delay).

---

## Phase 4 handoff notes (resume here — written 2026-07-05 after Phase 3 merged)

**Status:** Phases 1–3 SHIPPED to `main` (PRs #43/#44/#45; merge commits `caacd42`/`6a48e3d`/`03dae46`). Full Kit suite 1008/0. Phase 4 = **L7 (non-recoverable confidence-tiered storage) + forget-last-line + panic-purge** — the next `writing-plans` slice. Plans so far: `docs/superpowers/plans/2026-07-0{4,5}-predictor-secret-exclusion-phase{1,2,3}-*.md`. Ledger convention: `.superpowers/sdd/progress.md` (git-ignored, one per phase).

**Concerns to resolve during Phase 4 brainstorm/plan (carried over from the Phase 3 controller):**

1. **L6→L7 confidence hand-off is UNBUILT.** Phase 3's `GraduationTier.admit(...) -> [GraduatedOccurrence]` (`Sources/SemicolynKit/Predictor/GraduationTier.swift`) currently carries only `(token, previous, count)` — **no confidence signal**. L7's whole design hinges on a token graduating as *high-* vs *low-confidence* (spec above). **Decision needed:** where does confidence originate? The layer verdicts (L1 echo class, L3 paste flag, L4b denylist, L5 pattern-adjacency) are computed in DIFFERENT places than the engine — L1 in `PasswordEntryDetector` (App-driven), L3/L4 in `InputTokenTracker`, L5 in `TokenFilter`, and the engine's `record` only sees `(token, count, previous)`. So a confidence field must be **plumbed from the capture site (`observePredictorInput` in `App/ConnectionViewModel.swift`) through `record` → `admit` → `GraduatedOccurrence`**. That's a signature change to `PredictorEngine.record` and `GraduationTier` — a cross-cutting design task that should be its OWN early Phase-4 task, decided with the user (options: a `Confidence` enum param on `record`; or a richer `CommittedToken` that already carries the per-line layer verdicts). Note the confidence for a *high-echo, low-recurrence* token vs a *stalled-echo* token differs — the exact mapping is a user decision.

2. **Low-confidence storage split needs a real seam.** L7 says low-confidence tokens store "only the lossy aggregate (CMS/Bloom), never the literal in `PrefixIndex`." Today `RollingVocabulary` (`RollingVocabulary.swift`) writes BOTH the `PrefixIndex` (literal) and the `CountMinSketch` (lossy) together in `record`. L7 needs `record` to optionally SKIP the `PrefixIndex.insert` while still doing the sketch increment. Check whether `RollingVocabulary.record` can take a `storeLiteral: Bool` (or a two-method split) without breaking the existing `learnedSource`/rollover/serialize paths. This is the structural core of L7 and likely the hardest task.

3. **Phase 4 has REAL App-tier UI** (unlike pure-Kit Phase 3) — forget-last-line is a keybar/quick-action, panic-purge is in Settings → predictor controls. So: (a) the macOS CI job GATES this phase again (it did not for Phase 3); (b) there's SwiftUI + `ConnectionViewModel`/`AppStores` wiring the per-task reviewers can't locally build — plan those as macOS-CI-verified tasks. Forget-last-line's Kit primitive is a `GraduationTier.forgetLastLine()` (drop the most-recent line's un-graduated tokens — needs the tier to track per-line grouping, which it does NOT today → a tier change). Panic-purge = delete `learned.sketch` + `graduation.reset()`, keep `SeedStore` (bundled) — mostly App/store wiring.

4. **Process note for whoever resumes:** the **Docker socket is sandbox-blocked for subagents** — implementers must flag tooling errors (not misdiagnose them as code bugs); the CONTROLLER runs `swift test` via `dangerouslyDisableSandbox: true` for verification. Two Phase-3 implementer agents STALLED silently after writing correct files but failing to commit (stuck retrying the blocked Docker run) — watch for this: if an agent goes quiet, check `git log` + file mtimes; the work is often done-but-uncommitted, and a controller test-run + commit-on-its-behalf resolves it. Also: brief example-code that uses `Set(x)` requires the element type be `Hashable`, and engine suggestion tests must respect `confidenceFloor = 2` (a count-1 backfilled entry won't surface) — both bit Phase 3.

---

## L7 — Non-recoverable storage (structural; "assume detection failed")

L1–L6 are detection. L7 assumes detection **failed** on some token and asks: if a secret
did get learned, is it *recoverable* from what we persist? Today it is — the literal
token string is written verbatim into the `PrefixIndex` (that is what made the shipped
finding a real plaintext-on-disk leak). L7 changes what persistence *can even hold*.

**Confidence tiering at graduation (L6 hands off to L7).** When a token graduates
(L6), it carries a **confidence** derived from the layers it passed:
- **high-confidence** — echoed cleanly (L1/L2 said echoing), not paste/denylist/pattern
  flagged, recurred across distinct contexts. Safe to store the **literal** token in the
  `PrefixIndex` (needed for prefix completion — the feature).
- **low-confidence** — graduated on count alone but with any ambiguity (an echo layer was
  *unsure*, output was stalled, or the token is pattern-adjacent). Store **only the lossy
  aggregate** (the CMS/Bloom count that already exists for frequency), **never the literal
  string** in the `PrefixIndex`. The token still contributes to frequency ranking but can
  never be *reconstructed* or offered as a literal completion.

**Consequence:** a missed secret that somehow graduated low-confidence leaves only a lossy
count on disk — not a recoverable string. The worst residual degrades from "plaintext
password in `learned.sketch`" to "an anonymous increment in a probabilistic counter,"
which is the structural property the CMS/Bloom design already provides for the aggregate.

**Storage hygiene + the two forget tools (folded in here):**
- Nothing captured during an L1/L2 non-echo window is persisted even to the *ephemeral*
  L6 tier — it is dropped at capture, not just at graduation.
- The on-disk `learned.sketch` keeps its existing `.completeFileProtection`.

**Forget-last-line (primary, surgical).** The everyday "oops, I just typed a secret"
tool. Drops the most-recently-committed line's tokens from the **ephemeral L6 tier**
before they graduate. This is exact and cheap **precisely because L6 defers learning**:
a regretted line's tokens are still sitting ungraduated in the ephemeral tier (a
freshly-typed password has by definition not recurred ≥ N times across sessions), so
forgetting it is a clean ephemeral delete — **no CMS decrement, no `PrefixIndex`
surgery**, avoiding the lossy-decrement problem the original predictor spec deferred as
hard. Surfaced as a lightweight action (a keybar/quick action, not buried in Settings)
so it's usable in the moment. Bounds: it can only forget lines that have **not yet
graduated** — a token that graduated to the persistent store in a *prior* session is not
reachable surgically (see panic-purge), but L7's confidence tiering means such a token,
if low-confidence, has no literal form to leak anyway.

**Panic-purge (fallback, nuclear).** The "I don't trust it — wipe it all" reset, in
Settings → the existing predictor controls. Wipes **all user-derived learned state** —
the persistent learned store (`RollingVocabulary` + `PrefixIndex` + bigram) *and* the
ephemeral tier. Leaves the **static bundled seed vocabulary** (`SeedStore`) untouched —
it is shipped app content, not user data, contains no secret, and re-ships with the app;
wiping it would only degrade suggestions for nothing. This is the honest complete answer
to "did it learn my password?" — everything you contributed is gone; generic seed
suggestions remain. On-device the wipe is complete by construction (file delete under
`.completeFileProtection`).

## L8 — Sync-boundary firewall (structural; gates the future aggravator)

The predictor is **local-only today**, but the sync spec
(`2026-06-16-icloud-sync-scope-design.md`) has predictor sketches syncing to CloudKit
**default-ON** once that ships — which would turn a local leak into a cross-device one.
L8 makes that structurally safe **before** sync exists, so it can't regress later.

**The firewall rule:** only the **lossy aggregate** (the CMS/Bloom frequency sketches) may
cross the sync boundary. The **literal-token `PrefixIndex` never syncs** — it stays
device-local. Cross-device, a user gets frequency-informed ranking of vocabulary that
*also* recurs on the new device, but no literal string authored on device A is ever
transmitted or reconstructable on device B.

**Why this composes with L7:** L7 already ensures low-confidence tokens have *no* literal
form anywhere. L8 additionally ensures that even *high-confidence* literals (legitimately
stored for local completion) never leave the device. So the sync channel carries only the
structurally-lossy tier — the same property that made the sync spec argue CMS/Bloom is
"lossy aggregate, not recoverable text," now enforced by construction rather than assumed.

**Scope now vs. later.** Sync itself is unbuilt (2b-ii, enrollment-gated). L8's
*enforcement* is: define the sync-eligible surface as "aggregate sketches only, never the
`PrefixIndex`," and encode it where the persistence tier is split (a `syncEligible` marker
on the store components) so the future CloudKit sync engine physically cannot pick up the
literal index. This is a small, cheap structural commitment now that prevents a whole
class of future regression — no CloudKit code is written in this design.

**Wipe propagation (a requirement recorded for the sync era, not built now).** When sync
ships, both forget tools must be sync-aware, or a wipe is a lie: forget-last-line and
panic-purge must **propagate the deletion to all synced devices**, not just the local
one — a purge that leaves the aggregate increment on your iPad has not forgotten it.
Recorded here so the CloudKit sync engine is built with wipe-propagation as a first-class
requirement rather than a retrofit. (Local-only today, so purge is complete by
construction; this note binds the future.)

---

## Data flow & layer ordering

One capture chokepoint, one verdict per committed line, ordered cheapest-and-most-
decisive first so an early suppress short-circuits the rest.

```
outgoing keystrokes  →  InputTokenTracker (existing)  →  per line, at commit:
   L3  withinPaste?            → suppress line, stop
   L4a leading space?          → suppress line, stop
   L2  mosh & prediction-live? → echoVerdict = mosh state   (else fall through)
   L1  echoVerdict (buffer)    → non-echoed? suppress line, stop      [SSH + mosh-fallback]
   for each token on the line:
     L4b arg-position denylist? → drop token
     L5  TokenFilter.excludes?  → drop token
   surviving tokens → L6 ephemeral tier (+context); on graduation →
     L7 confidence: high → literal into PrefixIndex; low → lossy count only
                    (L8 marks PrefixIndex sync-ineligible)
```

- **Ordering rationale:** the deterministic line-level gates (L3/L4a) are cheapest and
  most decisive, so they run first. The echo verdict (L2 preferred, L1 fallback) is
  per-line. The per-token gates (L4b/L5) run only on lines that survived the line gates.
  L6/L7/L8 are the persistence tier.
- **incognito / master-off short-circuit (unchanged):** when the predictor engine is nil
  (per-host incognito, or master-off), `observePredictorInput` early-returns before any
  of this — no capture at all. The stack sits *inside* the already-gated learning path.
- **Suggestions are unaffected:** all layers gate *learning* (what enters the vocabulary),
  never *reading*. Seed/known-command suggestions surface immediately as today; only
  learned-from-you tokens pass through the stack.

## Error handling & failure modes

Every layer's failure mode is **suppress** (fail toward not-learning), consistent with
the reframe. Concretely:
- **EchoOracle unavailable / throws** (e.g. SwiftTerm API drift): the buffer check yields
  "unknown" → treat as non-echoed → suppress. Never learns on an oracle error.
- **Mosh flag unreadable** (bridge error, prediction=Never): fall back to L1. If L1 is
  also unavailable, suppress.
- **Malformed paste markers / split escapes:** fail closed (L3, as specified).
- **Ephemeral tier lost** (backgrounded/killed mid-session): the un-graduated tokens are
  simply dropped — a safe loss (they hadn't been learned yet).
- **No path can crash or block input** — a verdict is always computable (worst case:
  suppress), and it is computed off the input hot path at line commit.

## Testing

| Unit | Where | What | Tier |
|---|---|---|---|
| L1 echo classifier (via `EchoOracle` fake) | Kit / Linux | scripted oracle: echoed line → learn; hidden line → suppress; masked line → suppress; alt-screen → suppress; mixed/majority → the specific verdict | Critical |
| L3 paste state machine | Kit / Linux | tokens inside `200~…201~` never learned; unmatched open/close fail closed | Critical |
| L4a leading space | Kit / Linux | space-first line → whole line suppressed; non-space unaffected | Core |
| L4b arg denylist | Kit / Linux | `--token X` / `--token=X` / `-p X` / `Authorization: X` / `user:pass@host` → value token dropped, command kept; adversarial: each flag form, case-insensitivity | Critical |
| L5 extended patterns | Kit / Linux | each added format (`AKIA…`, `sk_live_`, JWT, PEM, …) excluded; human password `Summer2024!` NOT excluded (documents L5's limit) | Critical |
| L6 graduation | Kit / Linux | token typed < N contexts → not in persistent store; ≥ N distinct contexts → graduates; same line replayed does NOT over-count; a once-typed password never graduates | Critical |
| L7 confidence tiering | Kit / Linux | high-confidence → literal in index; low-confidence → lossy count only, literal absent (assert the literal is NOT recoverable from the store) | Critical |
| L8 sync-eligibility | Kit / Linux | the `PrefixIndex` component is marked sync-ineligible; the aggregate is eligible (assert the marker; no CloudKit) | Core |
| Integration: the ordered pipeline | Kit / Linux | a `hunter2` at a hidden prompt is suppressed by L1; a pasted `ghp_…` by L3/L5; a re-typed legit command graduates; end-to-end "no literal secret in the persisted store" | Critical |
| `EchoOracle` SwiftTerm adapter + mosh flag exposure | macOS CI | the adapter reads `getTerminal()` correctly; the mosh bridge flag flips at a scripted non-echo point (`SemicolynBridgeTests`) | Core |

Anti-tautology: every negative asserts the *specific* outcome (this token absent / this
line suppressed / this literal not in the index), never merely "excludes returned true."
Adversarial cases (a secret crafted to slip each layer) are mandatory for the Critical
units, per the testing standard.

## Wiring & file layout

- **Kit (Linux-tested):** the layer logic. Extend `PasswordEntryDetector` →
  rename/refactor to a `SecretExclusionPipeline` (or keep the name, expand) that composes
  L1/L3/L4 and emits the per-line verdict; `EchoOracle` protocol; extend `TokenFilter`
  (L5); add the L6 ephemeral-graduation tier + L7 confidence to the predictor store
  (`RollingVocabulary`/`LearnedStore`/`PrefixIndex`); the L8 `syncEligible` marker.
- **App (macOS-CI):** `SwiftTermEchoOracle` (backed by `getTerminal()`); the mosh
  bridge getter (L2, vendored-mosh patch → `MoshSession` → Swift); wire the forget-last-
  line action into the keybar/quick actions; panic-purge into Settings → predictor.
- **Vendored mosh:** the minimal read-only `PredictionEngine` echo-state getter (L2),
  documented in `docs/vendor/mosh.md`.
- The existing `observePredictorInput` chokepoint (`App/ConnectionViewModel.swift`) stays
  the single capture point; it feeds the pipeline and consults the per-line verdict at the
  record boundary — the tier rule (logic in Kit, thin wiring in App) is preserved.

## Out of scope (v1)

- **Active echo probing** (iTerm2 space+BS) — invasive; future confirmation-only option.
- **User-editable denylist / pattern rules** — conservative defaults only; revisit on demand.
- **Remote `stty` polling channel** — deterministic but fragile; not worth the cost.
- **OSC 133 prompt-mark integration** — corroborative, low coverage; a later add if
  shell-integration adoption warrants it.
- **CloudKit sync itself** — unbuilt (2b-ii). L8 only encodes the eligibility boundary +
  the wipe-propagation requirement; no sync engine here.
- **"Forget this exact string"** across the lossy persistent tier — structurally hard
  (CMS is not cleanly decrementable); L6 deferral + L7 non-recoverability make it
  unnecessary for the secret case.

## Phasing (implementation order — build-value first)

Each phase is independently shippable and reduces risk on its own:

1. **L1 buffer-anchored echo + `EchoOracle` seam** — the biggest single upgrade to the
   already-shipped detector; SSH + mosh-fallback coverage.
2. **L3 paste + L4 context/leading-space** — cheap deterministic gates; close the
   pasted-secret gap the echo layers can't see. **IMPLEMENTED (Phase 2, plan
   `docs/superpowers/plans/2026-07-05-predictor-secret-exclusion-phase2-paste-context.md`):**
   L3 in `InputTokenTracker` (bracketed-paste state machine, fail-closed, drops
   in-paste partials on close), L4a leading-space line opt-out (`lineOptedOut`,
   gated in the App learn flow), L4b `SecretArgDenylist` applied in the tracker
   (drop secret values, reach-back-over bigram via a split `previous`/`secretCheckPrev`
   to avoid cascading drops). Next: Phase 3 (L5 pattern extension + L6 graduation).
3. **L5 pattern extension + L6 frequency graduation** — the format-agnostic catch-all;
   L6 also unlocks forget-last-line. **IMPLEMENTED (Phase 3, plan
   `docs/superpowers/plans/2026-07-05-predictor-secret-exclusion-phase3-pattern-graduation.md`):**
   L5 = curated credential-format prefixes (AWS/Google/Stripe/Slack) + structural
   JWT/PEM-private detection in `TokenFilter`. L6 = `GraduationTier` (pure, ephemeral,
   never-persisted) gating `PredictorEngine.record`: a token graduates only when
   `distinctContexts ≥ 3` OR `nilCount ≥ 3` (nil-special refinement — repeated
   start-of-line commands graduate via nil count for utility; a prompt-secret with a
   non-nil preceding word needs 3 *distinct* contexts, so a once/few-typed password
   never graduates), with count backfill and a bounded tier. **L6 reset is currently
   engine-lifecycle-covered** — every context switch (`teardown`, incognito, host
   switch) nils-and-recreates the engine, giving a fresh empty tier by construction;
   `PredictorEngine.resetGraduation()` exists (unit-tested) as the reset primitive for
   a future engine-preserving switch, but has no live App call site today, so **Phase 3
   is entirely pure Kit (no App-tier change)**. Next: Phase 4 (L7 storage + forget tools).
4. **L7 confidence storage + forget-last-line + panic-purge** — the non-recoverable tier
   and the user-facing forget tools.
5. **L2 mosh prediction-engine signal** — the vendored-mosh patch; strict upgrade on the
   mosh path.
6. **L8 sync-eligibility marker** — the cheap structural commitment for the sync era.
