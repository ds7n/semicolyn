# Predictor bigram / next-token prediction

**Date:** 2026-06-21
**Status:** Locked
**Phase:** 4g (predictor) — the second predictive axis: after the user commits a
token, suggest the token that usually *follows* it (`git` → `status` / `commit`,
`kubectl` → `get` / `apply`). Pure value types, Linux-testable. Implements the
sub-command bigram path of [[2026-06-13-predictor-design]] for a single learned
sketch; windowing and seed deference arrive later for free (see *Composition*).

## The gap this fills

Phases 4a–4f built the **unigram** path: type a prefix → rank tokens sharing it
([[2026-06-21-predictor-prefix-ranking-design]]). That answers "what word am I
typing?" but not "what word comes next?". The marquee bigram behavior: the user
who runs `git status` repeatedly should, the instant they commit `git`, see
`status` offered before they type a single letter of it.

The master spec lists a dedicated **Bigram CMS** keyed by `(previous-token,
next-token)`. The realization here needs no new sketch type and no new ranking
logic — only a key encoding.

## Key insight: a bigram is a unigram over composite keys

Predicting the next token *after a fixed `previous`* is exactly the unigram
problem — prefix-rank the set of tokens that have followed `previous` — restricted
to that one previous token. Encode each observed pair as a single composite key:

```
composite(previous, next) = previous + US + next        US = "\u{1F}" (0x1F)
```

`US` (ASCII unit separator) is a control byte that never appears in a shell
token, so the encoding is unambiguous and reversible. With this, a
``BigramVocabulary`` is a thin wrapper over the existing ``Vocabulary``
(``PrefixIndex`` + ``CountMinSketch``):

- **record** `(previous, next)` → `vocab.record(composite(previous, next))`.
- **next-token candidates after `previous`** with typed prefix `p` →
  `vocab.candidates(forPrefix: composite(previous, p))`, then strip the
  `previous + US` prefix off each returned key to recover `next`.

Why this is correct and not a hack:

- **The contiguous-run theorem still holds.** ``PrefixIndex`` orders by UTF-8
  bytes, so every key beginning `previous + US` forms one contiguous sorted run —
  the same property the unigram prefix scan relies on. Querying `git + US`
  matches exactly the `git`-successors and *cannot* bleed into `github`'s
  successors: byte 4 of `github…` is `h` (0x68) ≠ `US` (0x1F), and because
  `US` is lower than every normal token byte, `git + US + …` sorts as its own
  block. Prefix containment of one previous-token in another is a non-issue.
- **The CMS is unchanged.** It already hashes an arbitrary `String`; a composite
  key is just a string. One-sided error, saturating counters, merge/subtract all
  carry over verbatim — which is what makes windowing free later.

## BigramVocabulary

```
record(previous:next:count = 1)               → learn one observed adjacency
nextSource(after previous:) -> CandidateSource → ranked successors of `previous`
candidates(after previous:, prefix = "")       → convenience over nextSource
```

- **`nextSource(after:)`** returns a ``CandidateSource`` scoped to one previous
  token. `candidates(forPrefix: p)` on it yields the successor tokens (already
  prefix-`p`-filtered) paired with their estimated counts — *decoded back to bare
  `next` strings*, not composite keys. An empty prefix (the common case: token
  just committed, next word not yet started) returns every known successor.
- **`candidates(after:prefix:)`** is sugar: `nextSource(after:).candidates(forPrefix:)`.
  Default `prefix = ""` for the "predict immediately on commit" path.

### Recording guards (fail-closed)

`record` is a no-op when:

- `previous` or `next` is **empty** — no useful adjacency, and an empty side
  would desync index from sketch exactly as in the unigram `record`.
- `count == 0` — same reasoning as unigram.
- `previous` or `next` contains the **`US` byte** — would corrupt the encoding by
  introducing a false separator. Tokens never legitimately contain `0x1F`;
  rejecting is pure defense against a malformed/hostile token reaching the store.

Privacy (the [[2026-06-21-predictor-privacy-filter-design]] `TokenFilter`) is the
caller's gate, applied to *each side* before `record`, exactly as for unigrams —
the bigram store stays a pure mechanism.

### Decoding successors

Each composite key returned for previous `q` begins with `q + US`. Strip it by
**byte count** (`q.utf8.count + 1`; `US` is one UTF-8 byte) and decode the
remainder as UTF-8 — byte-consistent with the rest of the module, and immune to
a leading combining mark in `next` that a Character-wise `dropFirst` could
mis-handle.

## Composition — what comes for free

Because `nextSource(after:)` yields a plain ``CandidateSource``, the existing
composers apply with **zero new code**:

- **Seed deference / N-gram gating** — the master spec's "after `git`, defer to
  the user's `git X` history" is just
  `SeededSuggester(learned: userBigram.nextSource(after: "git"),
  seed: seedBigram.nextSource(after: "git"))`. Layer-1 weighting and Layer-2
  per-prefix gating fall out unchanged ([[2026-06-21-predictor-seed-deference-design]]).
- **Daily windowing** — a later slice can hold per-window bigram sketches and sum
  their `nextSource`s through ``AggregateCandidateSource``
  ([[2026-06-21-predictor-candidate-aggregate-design]]), mirroring
  ``RollingVocabulary`` ([[2026-06-21-predictor-daily-rollover-design]]). The
  composite-key CMS merges/subtracts pointwise like any other.

This slice deliberately ships only the **single-sketch core** so those layers
compose onto a verified base, exactly as 4b preceded 4c/4d/4e.

## Sketch dimensions

Default `4 × 2^16` (the master spec's bigram sizing, ~256KB serialized) — wider
than the unigram `4 × 2^14` because the `(previous, next)` pair space is larger,
so more distinct keys hash in and a wider sketch keeps collision inflation low.
Caller-overridable, like ``Vocabulary``/``RollingVocabulary``.

## Out of scope (later slices / deferred)

- **Windowing & rollover for bigrams** — composes via the aggregate (above).
- **Bigram seed blob** — the build-time seed pipeline emitting `(command,
  subcommand)` pairs; this slice consumes any `CandidateSource` as the seed.
- **Trigrams** — the master spec's open question; storage cost unresolved.
- **Flag prediction (`tar -` → `-czvf`)** — a v1.5 `(command, flag)` axis; the
  same composite-key mechanism would serve it, but it is not this slice.
