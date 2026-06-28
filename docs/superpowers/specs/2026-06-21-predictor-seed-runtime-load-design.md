# Predictor seed runtime load (seed_pinned)

**Date:** 2026-06-21
**Status:** Locked
**Phase:** 4l (predictor) — the consumer end of the seed pipeline: install the
bundled seed into `seed_pinned` on first launch / version upgrade, and load it
back as the read-only seed ``CandidateSource`` the ``SeededSuggester`` defers to.
Closes the loop opened by [[2026-06-21-predictor-vocab-serialization-design]] /
[[2026-06-21-predictor-seed-ingestion-design]] / [[2026-06-21-predictor-fig-ingestion-design]].
Implements step 7 of the seed pipeline in [[2026-06-13-predictor-design]].

## The gap this fills

4i–4k build and serialize a seed; nothing yet loads one at runtime. The master
spec: *"On first launch (and on app version upgrade), copy the bundled seed into
`seed_pinned.sketch`."* The seed is **pinned, not merged** — a read-only source
the ranker consults only when the user lacks signal, never mixed into learned
sketches. This slice is the install-and-load mechanism; it is the first component
in `SemicolynKit` that touches the filesystem.

## Keep the platform glue at the edges

The pinned-seed *location* (`Library/Application Support/semicolyn/predictor/`,
`NSFileProtectionComplete`) and the *bundled* seed (an app `Bundle` resource) are
iOS specifics. The install/load *logic* — version comparison, copy, deserialize,
fail-soft — is pure and Linux-testable. So ``SeedStore`` is parameterized:

- it takes a `directory: URL` (the caller passes the real predictor dir; tests
  pass a temp dir),
- it installs a `BundledSeed` *value* (the caller builds it from `Bundle`
  resources; tests build it from a ``SeedBuilder``),

and never references `Bundle.main`. The app supplies both at the edge; everything
here runs and is tested on Linux against temp directories.

## BundledSeed + SeedStore

```
struct BundledSeed { version: Int; unigramBlob: [UInt8]; bigramBlob: [UInt8] }

struct SeedStore(directory: URL) {
  installIfNeeded(_ bundled) throws -> Bool      // true if it installed
  loadSeed() -> PredictorSeed?                    // nil if absent/corrupt
}

struct PredictorSeed { unigram: Vocabulary; bigram: BigramVocabulary }
```

On-disk layout in `directory` — **one** self-describing file (matching the master
spec's singular `seed_pinned.sketch`):

```
seed_pinned.sketch:
  magic "GSED" | formatVersion(1) | contentVersion(LE32)
              | len|unigram-GVOC-blob | len|bigram-GBGM-blob
```

Both blobs **and** the content version live in this one file. That is the crux of
install atomicity: a single write is all-or-nothing, so there is **no window**
where a freshly-written unigram blob can pair with a stale bigram blob (the
failure mode a two-file layout has on a mid-upgrade throw). The sub-blobs are
length-prefixed and read with the shared `readLengthPrefixed` primitive.

### installIfNeeded — first launch + upgrade, idempotent

```
if a readable up-to-date seed is present  (installed != nil
                                           && bundled.version <= installed
                                           && loadSeed() succeeds):
    return false                              // leave it
else:                                         // absent / newer bundle / corrupt
    atomically write the combined GSED blob   (iOS: NSFileProtectionComplete)
    return true
```

A corrupt-but-header-valid file (e.g. a truncated body) would pass a bare version
check yet fail to load; including `loadSeed() succeeds` in the skip condition lets
such a file **self-heal** on the next launch rather than persisting until a
version bump.

- **Versioned, not first-launch-only** — a newer bundled seed (a later app
  release) replaces the pinned one; an equal or older one is left untouched, so a
  downgrade or re-launch is a no-op. The seed content version is a plain integer
  (`seed_v<N>`), distinct from the blob *format* version the deserializers carry.
- **Single atomic write** — a thrown/interrupted install leaves the prior file
  (or none) intact; the next launch re-installs from the unchanged version. No
  half-written or cross-blob-mismatched seed is ever observable.
- Creates `directory` if absent.

### loadSeed — fail-soft

Reads the two pinned blobs and deserializes each. **Any** problem — files
absent, unreadable, or a blob the fail-closed deserializer rejects — yields
`nil`, not a throw: a missing or corrupt seed must degrade the predictor to
learned-only, never break input. (The seed is pure day-one help; its absence is
survivable, a crash is not.) The blobs' own format/version guards
([[2026-06-21-predictor-vocab-serialization-design]]) do the integrity checking.

## Wiring into ranking

`loadSeed()` hands back a ``Vocabulary`` and a ``BigramVocabulary``; both already
expose ``CandidateSource`` (`bigram.nextSource(after:)`), so assembling the
deferring ranker is exactly the established composition:

```
SeededSuggester(learned: userBigram.nextSource(after: cmd),
                seed:    seed.bigram.nextSource(after: cmd))
```

No new ranking code — this slice only adds install + load.

## Out of scope (later slices)

- **Bundle.main resource wiring + the real Application-Support path** — the app
  edge that constructs `directory` and `BundledSeed`; trivial glue, no test value
  on Linux.
- **Persisting the user's learned rolling store** — the other half of predictor
  storage (today/daily flushes, event log); a separate slice. This slice loads
  only the read-only seed.
- **Seed rebuild-on-format-break / event-log replay** — master-spec edge cases.
