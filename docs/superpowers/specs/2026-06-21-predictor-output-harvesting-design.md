# Predictor output-token harvesting

**Date:** 2026-06-21
**Status:** Locked
**Phase:** 4p (predictor) — harvest tokens from command *output* (filenames, pod
names, branch names, container IDs) into a short-lived store so they surface as
one-tap completions the moment the user types a matching prefix. The master
spec's *Locked* v1 "killer feature" ([[2026-06-13-predictor-design]]). Pure value
types, Linux-testable; wires into ``PredictorEngine``.

## The gap this fills

Learned + seed suggestions cover *vocabulary*; they can't know the pod name a
`kubectl get pods` just printed. Output harvesting closes that: tail a log, then
refer to one of its lines with a tap. This is ephemeral, high-relevance context —
not learning, not persisted.

## Why not (just) a Bloom filter

The master spec's table lists a "Token Bloom filter" — but that answers *"have I
seen this token?"* (typo detection), and a Bloom filter **cannot enumerate**.
Surfacing a harvested token as a *prefix suggestion* requires listing the tokens
that share a prefix, so harvesting needs a **prefix-queryable** structure. The
Bloom filter's typo-detection role is separate and not built here.

## OutputHarvest — a bounded recency store

```
struct OutputHarvest(capacity: Int = 200) {
  mutating func harvest(_ token: String)
  mutating func harvest(_ tokens: [String])     // last element = most recent
  mutating func clear()
  func candidates(forPrefix:) -> [TokenCount]    // recency-ranked, newest first
}
```

- **Distinct, recency-ordered.** Tokens are held oldest→newest; re-harvesting an
  existing token moves it to newest. A prefix query returns matches **newest
  first**, with `count` set to the token's recency position — so it is a valid
  ``CandidateSource`` whose natural ranking is recency.
- **Decay = bounded capacity, not a clock.** When `capacity` is exceeded the
  oldest tokens are evicted; new output naturally pushes old output out (a heavy
  `ls` scrolls last hour's pod names away). This captures "short-lived"
  *deterministically and testably* — no wall-clock, which this environment and the
  pure-value-type style both avoid. Time-based decay (the spec's open "hours? until
  next command?" question) is a future refinement on top.
- **Ephemeral — never persisted.** Unlike learned state, harvest lives only in
  memory for the session; `clear()` lets the app drop it on a context change
  (host switch, incognito).

Byte-prefix matching mirrors ``PrefixIndex`` (UTF-8 bytes), the module's
consistent prefix semantics. Capacity is small (hundreds), so a linear prefix
scan is plenty.

## Privacy at the harvest boundary

Command output can contain secrets (`cat config.env`). Harvesting is gated by the
same ``TokenFilter`` as `record`, applied **at the engine boundary** before a
token enters the store — so an excluded output token is harvested nowhere and can
never surface. Reads stay un-gated.

## Integration into PredictorEngine

```
harvest(output: String):                 // tokenize lines, privacy-filter, store
suggestions(forPrefix: p, after: prev):
  base      = SeededSuggester(learned, seed).suggestions(p)   // existing axis logic
  harvested = outputHarvest.candidates(forPrefix: p)          // newest first, axis-independent
  return dedup(harvested ++ base).prefix(topK)
```

- **Harvested leads.** Just-seen output tokens are the most contextually relevant,
  so they take the front of the row (recency order), and learned/seed fill the
  remaining `topK` slots; duplicates collapse to their first (harvested)
  position. This maximizes the killer-feature payoff; it is a deliberate,
  tunable choice (a future config could cap the harvested lead).
- **Axis-independent.** Harvest is purely prefix-based, so it leads in both the
  unigram and the next-token (`after:`) axes — `cat <just-listed-file>` wants the
  harvested filename as the next token just as much as a bare prefix does.

## Out of scope (later)

- **Time-based decay / a short-decay sketch** — the spec's lifespan question.
- **Bloom-filter typo detection** — the "did you mean" axis.
- **Per-context harvest scoping** (per-host buffers) and a configurable
  harvested-lead cap.
