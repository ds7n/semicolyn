# Predictor Architecture — Design Spec

**Date:** 2026-06-13
**Status:** Locked direction, ready for implementation plan
**Scope:** On-device predictive input subsystem for Semicolyn

---

## North star

Make terminal input on iOS **fast, error-free, and adaptive to the individual user's vocabulary** — without ever silently mutating what the user typed. Every prediction is a suggestion the user explicitly accepts; no autocorrect-style rewrite is ever performed by Semicolyn.

The marquee user-visible behavior: when a user has typed `claude` ten times in Semicolyn, the next time they type `clau` the suggestion strip shows `claude` instead of iOS's `crayon`. The system learns *the user's* vocabulary, not Apple's English dictionary.

---

## Suggestion surface

A **thin auto-hiding row above the keybar**.

- ~24pt tall when visible (smaller than the keybar's ~36pt — visually a different surface).
- **Auto-hides when there is no suggestion** at or above the confidence floor — no permanent vertical chrome cost.
- Slides in/out with a ~150ms spring; not jumpy.
- Lives on its own row, **cannot** reflow the keybar — keys stay at fixed positions to preserve muscle memory.
- Chip styling visually distinct from keybar keys: pill-shaped, accent-colored, distinct background, so it never reads as a tappable literal-key surface.
- Capacity: top-K candidates (K = 3 by default; see Per-prefix gating).
- Interaction: tap a chip → token committed into the input field; ignore the chip → continue typing as if it wasn't there. Never silent.

### iOS field-level setup

- `autocorrectionType = .no` — iOS's silent rewrite is off, always, when the predictor is on.
- `smartQuotesType = .no`, `smartDashesType = .no`, `smartInsertDeleteType = .no` — defensive disables of every iOS feature that would mutate the input.
- iOS's own suggestion bar (above the system keyboard) is suppressed — our custom row is the only suggestion surface while the predictor is on.
- When the user opts out of the predictor entirely ("master off"), these flags revert to defaults and iOS's own suggestion bar takes over. Our row disappears.

---

## Predictor architecture

### Sketches and tables

The predictor uses **probabilistic data structures** (sketches) to track usage with bounded memory and O(1) read/write.

| Sketch | Tracks | Used for |
|---|---|---|
| **Unigram CMS** | per-token frequency | Single-word prediction |
| **Bigram CMS** | (prefix-token, next-token) frequency | Subcommand / flag prediction (`kubectl` → `get`) |
| **Token Bloom filter** | "have we seen this token before?" | Fast "is this a typo of something known?" check |
| **(future) (host, hour-of-day, token) CMS** | time-of-day patterns | Surfacing contextually-relevant commands |

Storage format: each sketch is a serialized binary blob.

### Storage

- Path: `Library/Application Support/semicolyn/predictor/`
- File protection: `NSFileProtectionComplete` — encrypted at rest by iOS, decryptable only when device is unlocked, key derived from the Secure Enclave.
- Sketches sync via CloudKit Private DB + client-side AES-256-GCM (default ON, opt-out per device in Settings → App preferences → Predictor). Justified by CMS/Bloom's structural lossiness: the synced data is a frequency fingerprint, not recoverable text. See `2026-06-16-icloud-sync-scope-design.md` for the full revision rationale.
- Structure:
  - SQLite for metadata: token strings, host index, retention settings, opt-out rules.
  - Binary blobs for sketches: one blob per sketch per time window.
  - Append-only event log for the current day's events before they're rolled into the sealed daily sketch. Allows replay if a flush is corrupt.
- Expected size: a few MB for a heavy user, tens of KB for a light user. Sketches are tiny by design.

### Daily versioning + pre-computed rolling aggregates

Querying across N daily files on every keystroke is O(retention) per query and unacceptable for a read-dominated workload. Instead:

```
on-disk state:
  today.sketch          ← hot, in-memory + periodic flushes
  rolling_7d.sketch     ← sealed pre-aggregate (last 7 sealed days)
  rolling_30d.sketch    ← sealed pre-aggregate (last 30 sealed days)
  rolling_90d.sketch    ← sealed pre-aggregate (last 90 sealed days)
  seed_pinned.sketch    ← seeded vocabulary (read-only, pinned)
  daily/2026-06-12.sketch
  daily/2026-06-11.sketch
  ...                   ← sealed dailies, kept up to the retention horizon
```

**Rollover** (executed at user-local midnight):

```
rolling_7d  +=  today.sketch
rolling_7d  -=  daily/(today − 7).sketch
(same for 30d and 90d)
today.sketch sealed into daily/<date>.sketch
new today.sketch initialized to zeros
oldest daily past the retention horizon is pruned
```

CMS supports pointwise add (for merge) and pointwise subtract (for evict). Subtraction can underflow on rare collisions; clamp at zero.

**Query path** (every keystroke):

```
candidates = (today ⊕ rolling_<window> ⊕ seed_pinned).rank(prefix)
                 ↑ live   ↑ pre-aggregated      ↑ shipped seed
```

Three sketches summed → O(1) regardless of retention window. Sketch merge is pointwise addition, trivially fast.

### Implementation note: sketch sizing

CMS dimensions and Bloom filter sizes need tuning against expected vocab size. A reasonable starting point:

- Unigram CMS: 4 hash functions × 2^14 cells = 64KB serialized.
- Bigram CMS: 4 × 2^16 = 256KB serialized.
- Bloom filter: m ≈ 64K bits for n ≈ 10K expected tokens at ~1% FPR.

Total per-window sketch storage on the order of hundreds of KB. With 4 windows (today + 3 rolling) plus 90 dailies, total disk footprint is in the low MB.

---

## Seeding the vocabulary

A bundled seed gives day-one value — the system has useful suggestions before the user has typed anything.

### Sources (build-time pipeline)

| Source | Provides | License |
|---|---|---|
| **carapace** | Structured completion specs for 400+ CLI tools: command → subcommand → flag → flag-value | MIT |
| **tldr pages** | Real-world example invocations, parsed from code blocks | CC-BY 4.0 |
| **Curated public dotfiles corpus** | Aggregate command-frequency statistics from a curated set of permissive dotfiles repos | Per-repo permissive |

Pipeline:

1. Pull carapace specs → parse → emit `(command, subcommand)` and `(command, flag)` bigrams.
2. Pull tldr pages → parse code blocks → emit token sequences and bigram patterns.
3. Pull curated dotfiles → aggregate command-frequency analysis → emit unigram and bigram counts.
4. Merge into a single `(unigram_counts, bigram_counts)` pair.
5. Serialize into the same sketch format as the user's sketches.
6. Bundle the resulting `seed_v<N>.sketch` blob as a resource in the app.
7. On first launch (and on app version upgrade), copy the bundled seed into `seed_pinned.sketch` in the predictor directory.

The seed is **pinned, not merged** into the user's learned sketches:

- Preserves the privacy story — "my learned dictionary is mine; the seed is what Semicolyn ships."
- Lets us update seeds across app versions without contaminating user data.
- Queries simply add `today ⊕ rolling_<window> ⊕ seed_pinned`.

### Seed weights

Each seed token has a small "as-if-you-typed-this-once" baseline weight. Real user activity overwhelms seed weights quickly; rare seed tokens that the user never touches stay at low rank.

### Future: community-contributed seed (v1.5)

Publish an open-source tool that runs locally on a contributor's machine, anonymizes their shell history (strip secret-shaped tokens, drop low-count tokens, enforce k-anonymity thresholds), emits an aggregate sketch, and the contributor uploads it. We merge contributions into the next seed release.

Skipped for v1 — needs anonymization rigor and contribution moderation.

---

## Per-prefix deference: how seed gracefully steps aside

As the user's learned vocabulary grows, the seed's contribution to ranking decreases — not on a global timer, but **per prefix**, **continuously**, **automatically**. Two layers.

### Layer 1 — per-token weighting (always on)

When a token appears in both learned and seed sketches, the seed contribution is scaled down so it cannot out-rank a comparable learned entry:

```
score(token) = learned_count + seed_weight × seed_count
seed_weight  ≈ 0.5   (tunable; lives in config, not code)
```

A thumb on the scale. Same token, counted in both, leans toward the user's.

### Layer 2 — per-prefix gating (kicks in when the user has signal)

```
candidates_for(prefix):
  learned = filter(learned_sketch.query(prefix), score >= confidence_floor)
  if len(learned) >= top_k:
    return top_k(learned)            # seed not consulted at all
  else:
    return top_k(learned ∪ seed)     # fill remaining slots from seed
```

Effects:

- **Experienced user, prefix they've typed often** (`git`): the predictor finds K+ confident learned candidates → seed entries are invisible for this prefix. They never see `git tldr-example-xyz` because they've shown they don't use it.
- **Experienced user, prefix they've never typed** (`carapace`): no learned candidates clear the floor → seed candidates surface and they get day-1-style help where they need it.
- **New user, any prefix**: learned sketch is everywhere empty → seed fills every slot. Day-1 experience is full of value.

The shift is invisible to the user — no mode, no cliff, no "seed retirement day."

### Tunable defaults

- `top_k` = 3 (suggestion row visible slot count)
- `confidence_floor` = 2 (minimum learned occurrences to count as a confident candidate)
- `seed_weight` = 0.5

These are config values, not hard-coded constants. They're starting points and need empirical tuning.

### N-gram deference

The same per-prefix gating applies at the bigram level. After typing `git`, the next-token predictions defer to the user's `git X` history with the same rule: if there are ≥ `top_k` confident learned `git X` entries, seed `git Y` entries are hidden.

---

## Privacy controls

Layered, not a single switch.

| Layer | Behavior | Use case |
|---|---|---|
| **Master off** | Predictor disabled entirely; iOS native autocorrect/suggestions take over. | "I don't want this feature." |
| **Read-only mode** | Predictions surface from existing sketches; nothing typed during this session is recorded. | "I want autocomplete but not learning right now." |
| **Per-host incognito** | A flag on a specific host; connections to that host neither learn nor surface predictions. | "Never learn from `prod-db`." |
| **Pattern-exclude list** | Regex/glob patterns whose matching tokens are never recorded. | Belt-and-suspenders against learning credentials. |

### Pattern-exclude defaults (ships with the app)

- `.*password.*`
- `.*token.*`
- `.*secret.*`
- `ghp_*`, `gho_*`, `ghs_*` (GitHub tokens)
- `sk-*`, `pk_*` (Stripe / common API keys)
- High-entropy strings above an entropy threshold (default: skip).

User-editable.

### Transparency surface

- **"What Semicolyn has learned" screen** — settings view showing top tokens, top n-grams, per-host counts. Delete individual entries.
- **Wipe button** — one tap, all sketches zeroed, sealed days deleted. Reset to factory.
- **Retention window** — default 90 days, adjustable from "session only" to "forever."

The transparency surface is what makes "we learn from you" not creepy. It's not optional polish; it's load-bearing.

---

## Beyond unigrams: features unlocked by the predictor

The predictor's substrate (CMS, Bloom, daily versioning) supports more than basic suggestion. Some land in v1, some defer; all are listed so we don't accidentally architecturally exclude them.

### v1 — core suggestion experience

- **Unigram suggestion** — the foundation. (Locked.)
- **Sub-command bigram prediction** — `kubectl` → `get` / `apply` / `describe`. (Locked.)
- **Output-token harvesting** — when `ls` / `cat` / `kubectl get pods` runs, the resulting output's tokens (filenames, pod names, branch names, container IDs) are added to a short-lived Bloom filter; they surface as suggestions when the user starts typing a matching prefix. Killer feature; turns "tail a log and then refer to one of its lines" into a one-tap completion. (Locked.)

### v1.5 — high-value extensions

- **Flag prediction** — `tar -` → `-czvf`. CMS over `(command, flag)` pairs.
- **Next-command prediction** — after `git checkout -b foo`, suggest `git push -u origin foo` as a one-tap follow-up.
- **In-context shortcut prediction** — after `:` in vim, suggest `:wq` / `:q!`. Anchored on the preceding character; no app detection needed.
- **Time-of-day / day-of-week patterns** — CMS keyed by `(host, hour, day)`. Surfaces familiar commands at familiar times.
- **Host-conditioned suggestions** — sketches internally sharded by host. Different vocab on `prod-db` vs `laptop` without exposing the sharding to the user.
- **Snippet smart-sort** — the locked snippet/macro launcher's "smart sort" becomes PDS-backed: frecency over snippet use per `(host, time-of-day)`.

### Speculative — v2+

- **Soft typo correction toward known commands** — `gti status` → suggestion chip "did you mean `git status`?" (Suggestion, never silent rewrite.)
- **Anomaly / "are you sure?" detection** — soft visual flag when about to run a command unlike anything seen on this host. CMS-based novelty score.
- **Secret-pattern guard** — about-to-send a token-shaped high-entropy string → warning before send. Bloom filter over known-secret-hash-prefixes. Catches the paste-then-Enter footgun.

---

## Edge cases and gotchas

- **CMS subtract underflow.** At rollover, `rolling_7d -= daily/(today - 7).sketch`. Hash collisions can produce negative cell values; clamp at zero. Tolerable noise.
- **Sealed sketches vs in-flight events.** Today's sketch is being written; querying it must be safe under concurrent append. Either lock briefly or use a copy-on-write read snapshot.
- **App version upgrade with seed change.** New `seed_v(N+1).sketch` replaces `seed_pinned.sketch` in place. User's learned sketches are untouched; only the seed contribution changes.
- **First-launch performance.** Building the seed from bundled blob → predictor dir is a one-time cost. Do it on first launch in the background; predictor can run with seed-only candidates immediately.
- **Cold start of a new user.** Seed alone provides good suggestions for ~hundreds of common commands. No degraded UX while learning starts.
- **Sketch format versioning.** Each blob carries a format version header. On app upgrade with a breaking format change, sketches are rebuilt from the event log if possible, or zeroed if not (with a user-visible notice).
- **Privacy-pattern matching at write time, not read time.** When the user types a token matching the exclude list, the token is never recorded. Reading is never gated by patterns — the data simply isn't there.

---

## Deferred questions

- ~~**iCloud sync of learned sketches**~~ — **Locked in `2026-06-16-icloud-sync-scope-design.md`**: sync via CloudKit + client-side AES, default ON, opt-out per device. Snapshot time-travel (rolling back to a prior sealed daily) remains deferred to v1.5+.
- **Per-host vocabulary scoping** — currently Semicolyn-wide. Per-host internal sharding (for time-of-day patterns above) lays groundwork. Promoting host-level scope to user-visible setting is a v1.5 question.
- **Community seed contribution pipeline** — open-source script, anonymization rigor, contribution moderation.
- **Tuning of `seed_weight`, `confidence_floor`, `top_k`** — defaults are starting points. Need empirical tuning once Semicolyn has real users.

---

## Open subquestions (raise next session)

- N-gram order: bigrams in v1, but trigrams (`kubectl get pods`) are tempting. Storage cost is real; need to estimate value.
- Output-token harvesting lifespan: how long does a harvested pod name stay relevant? Hours? Until next `kubectl get pods`? Probably needs a separate short-decay sketch.
- The "What Semicolyn has learned" UI — how is it structured? List? Search? Per-host filter? Top-K view?
- Failure-mode UX: what does the suggestion row look like when the predictor disk is corrupted and the system has to rebuild from the event log? "Predictor is rebuilding…" toast?
