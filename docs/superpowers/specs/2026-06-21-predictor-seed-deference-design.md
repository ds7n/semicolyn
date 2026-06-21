# Predictor seed deference

**Date:** 2026-06-21
**Status:** Locked
**Phase:** 4c (predictor) — composes the learned ``Vocabulary`` (4b) with a pinned
read-only seed so day-1 suggestions are useful and the seed steps aside,
per-prefix and invisibly, as the user builds vocabulary. Pure value types,
Linux-testable. Implements the "Per-prefix deference" section of
[[2026-06-13-predictor-design]].

## The two layers (from the spec)

A `SeededSuggester` holds a mutable **learned** `Vocabulary`, a pinned read-only
**seed** `Vocabulary`, and a tunable `SuggestionConfig`. `suggestions(forPrefix:)`
applies:

### Layer 2 — per-prefix gating (decides whether the seed is consulted)

```
confident = learned.candidates(prefix).filter { count >= confidenceFloor }
if confident.count >= topK:
    rank confident by learned count alone           # seed NOT consulted
else:
    rank (confident ∪ seed.candidates(prefix))      # fill remaining slots from seed
take topK
```

So a prefix the user types often (≥ `topK` confident learned candidates) never
shows seed entries; a prefix they've never typed surfaces seed help. The shift is
continuous and per-prefix — no mode, no "seed retirement day."

**Below-floor learned tokens do not surface.** `confident` is the floor-filtered
set; a token typed once (below a floor of 2) is not a candidate until typed
again. This is the spec's noise guard (a once-typed typo shouldn't be suggested);
the seed fills the slot instead.

### Layer 1 — per-token weighting (applied whenever the seed IS consulted)

In the fill path, a token's score blends both sources, with the seed on a thumb
scale so it can't out-rank a comparable learned entry:

```
score(token) = learnedCount + seedWeight × seedCount      (seedWeight ≈ 0.5)
```

A token in both leans toward the user's count; a seed-only token contributes
`seedWeight × seedCount`. In the **fast path** the seed is not consulted at all
(per Layer 2), so scores there are just `learnedCount` — consistent with "seed
not consulted."

### Ranking

Score **descending**; ties broken by token **ascending (UTF-8 bytes)** — the same
total, deterministic order as [[2026-06-21-predictor-prefix-ranking-design]], so
identical states never reshuffle the suggestion chips.

## Tunable config (defaults from the spec, not hard-coded)

| Field | Default | Meaning |
|---|---|---|
| `topK` | 3 | suggestion-row slot count |
| `confidenceFloor` | 2 | min learned occurrences to count as a confident candidate |
| `seedWeight` | 0.5 | seed thumb-on-the-scale multiplier |

Scores are computed in `Double` because `seedWeight` is fractional; counts up to
`UInt32.max` are exactly representable in `Double` (< 2^53), so no precision loss.

## Supporting API on Vocabulary

`Vocabulary` gains `candidates(forPrefix:) -> [TokenCount]` — every prefix match
with its estimated count, unranked (the suggester re-ranks). `TokenCount` is a
small `Equatable` DTO (`token`, `count`). This exposes the scores the gating and
weighting need, which the string-only `suggestions(forPrefix:limit:)` hides.

## Behavior matrix (tested)

| Scenario | Result |
|---|---|
| Experienced, frequent prefix (≥ topK confident) | top-K learned; **seed invisible** even with huge seed counts |
| New user / never-typed prefix (0 confident) | seed fills every slot |
| Mixed (1 confident < topK) | confident-learned + seed, blended, fill to topK |
| Same token in both | `learned + 0.5·seed` (leans user) |
| Learned-only vs comparable seed-only, equal raw count | learned out-ranks (seed × 0.5) |
| Token typed once (below floor) | not suggested; seed fills instead |
| Token typed twice (at floor) | suggested |

## Out of scope (later 4x slices)

- **Daily windowing / rollover** — "learned" here is a single `Vocabulary`; 4d
  makes it the `today ⊕ rolling_<window>` aggregate feeding the same gating.
- **Bigram / next-token** seed deference (same rule at the bigram level).
- **Persistence / seed bundling** — building `seed_pinned` from the build-time
  carapace/tldr/dotfiles pipeline, copying it in on first launch.
- **Privacy write-time filtering** before `record`.

## Related

- [[2026-06-21-predictor-prefix-ranking-design]] — the `Vocabulary` being composed
- [[2026-06-13-predictor-design]] — the deference design this implements
