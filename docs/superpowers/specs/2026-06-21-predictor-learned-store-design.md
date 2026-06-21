# Predictor learned store

**Date:** 2026-06-21
**Status:** Locked
**Phase:** 4n (predictor) — persist and restore the user's learned windowed
vocabulary (unigram ``RollingVocabulary`` + bigram ``RollingBigramVocabulary``)
across launches. The read-write counterpart to
[[2026-06-21-predictor-seed-runtime-load-design]]'s ``SeedStore``, built on the
whole-state serialization of [[2026-06-21-predictor-rolling-serialization-design]].
Linux-testable against temp dirs.

## The gap this fills

4m made the rolling state serializable; nothing yet writes it to disk or reads it
back. The user's learning is still lost every relaunch. This slice adds the
on-disk store: atomic save, fail-soft load, first-run empty state.

## LearnedStore — mirror SeedStore, two differences

```
struct LearnedState { var unigram: RollingVocabulary; var bigram: RollingBigramVocabulary }

struct LearnedStore(directory: URL) {
  save(_ state: LearnedState) throws
  load() -> LearnedState               // never nil — fresh-empty on absence/corruption
}
```

On-disk: **one** atomically-written `learned.sketch`:

```
magic "GLRN" | formatVersion(1) | len|unigram-GRLV-blob | len|bigram-GRBG-blob
```

Both rolling states in one atomic write — the same all-or-nothing reasoning as
``SeedStore``: an interrupted save can never pair a fresh unigram state with a
stale bigram one.

Two deliberate differences from ``SeedStore``:

1. **No version compare.** There is no "bundled version" to gate on — `save` always
   overwrites with the current in-memory state (the app flushes its live store).
2. **`load` never returns nil — it returns fresh-empty on any miss.** First run
   (no file) is the *expected* path, not an error, and a corrupt file is fail-soft
   to empty too: better to restart learning than to crash input. (The master
   spec's event-log rebuild is the future, higher-fidelity recovery; until then,
   empty is the safe floor.) So the return is a non-optional `LearnedState` whose
   stores are the default-dimension empties (unigram `4 × 2^14`, bigram `4 × 2^16`,
   matching ``RollingVocabulary`` / ``RollingBigramVocabulary``).

Integrity is delegated to the fail-closed sub-deserializers (`GRLV`/`GRBG`); the
wrapper adds only its own magic/version check and the no-trailing-slack guard. On
iOS the file is written with `NSFileProtectionComplete`.

## What this is not

`save` is whole-state and synchronous; the app decides *when* to call it
(app-background / periodic). The master spec's hot-path refinements —
high-frequency `today.sketch`-only flush and an append-only event log for
crash recovery — layer on later and are out of scope here, exactly as the
combined-blob seed store preceded any incremental seed handling.

## Out of scope (later slices)

- **Incremental flush + append-only event log** — the hot-path/crash-recovery
  optimization.
- **App-edge assembly** — `Bundle` seed resource, the real Application-Support
  predictor dir, and wiring `SeedStore` + `LearnedStore` into a live
  ``SeededSuggester`` at startup (needs an app target).
