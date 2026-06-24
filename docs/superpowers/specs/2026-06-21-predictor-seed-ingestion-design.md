# Predictor seed ingestion — tldr-pages

**Date:** 2026-06-21
**Status:** Locked
**Phase:** 4j (predictor) — the build-time pipeline that turns real CLI corpora
into the bundled seed blobs. This slice ingests **tldr-pages** (the cleanest,
fully-reproducible source) into a unigram + bigram seed; carapace ingestion (a
second source merged into the same builder) is the 4k follow-on. Implements steps
1–6 of the seed pipeline in [[2026-06-13-predictor-design]].

## Shape: pure parser + builder in a tooling target, thin executable, fetch in a script

The shipped app (`NeotildeKit`) must not carry a tldr/markdown parser. So the
build-time code lives in its own targets:

```
Sources/SeedKit/            library, depends on NeotildeKit — pure, unit-tested
  TldrParser.swift          markdown page → command-invocation token sequences
  SeedBuilder.swift         token sequences → Vocabulary + BigramVocabulary → blobs
Sources/neotilde-seedbuild/    executable, depends on SeedKit — thin I/O glue
  main.swift                walk a dir of .md → build → write seed_*.sketch
Tests/SeedKitTests/         fixtures-driven tests for parser + builder
scripts/build-seed.sh       clone tldr-pages @ pinned tag → run the tool
```

**Why fetch in a script, not in-process.** Reproducible, real-data ingestion only
needs the *data* to be real; the *fetch mechanism* is incidental. A script that
`git clone --depth 1 --branch <pinned-tag>`s tldr-pages and points the tool at
the checkout keeps the Swift code free of networking/zip/tar handling and makes
the whole pipeline testable against a fixture directory. Pinning the tag makes
the build deterministic.

## TldrParser — markdown page → token sequences

A tldr page documents one command with example invocations, each an inline code
span:

```
# git commit
> Commit files to the repository.

- Commit staged files with a message:

`git commit --message "{{message}}"`
```

`invocations(fromPage:) -> [[String]]` returns one token sequence per code span:

- **Extract inline code spans** — the text between paired backticks. Description
  prose, headers, and `>` info lines carry no backticks and are ignored.
- **Tokenize** each span on whitespace.
- **Drop placeholder tokens** — any token containing `{{` or `}}` is a
  user-substituted argument (`"{{message}}"`, `{{path/to/file}}`), not real
  vocabulary; dropped. This is what leaves clean `git` / `commit` / `--message`.
- **Drop empty** tokens. Surrounding shell quotes on a kept token are trimmed so
  `"--foo"` doesn't diverge from `--foo`; a token that is *only* quotes/punctuation
  collapses to empty and drops.

The parser emits raw tokens; it does **not** decide unigram vs bigram — that's the
builder's job, keeping the parser a pure text→tokens function.

## SeedBuilder — token sequences → seed blobs

Accumulates every parsed sequence into two stores, then serializes both:

```
ingest(_ tokens: [String]):
  for t in tokens:                unigrams.record(t)                  // one per occurrence
  for (a, b) in adjacentPairs:    bigrams.record(previous: a, next: b)

blobs() -> (unigram: [UInt8], bigram: [UInt8])   // Vocabulary + BigramVocabulary
```

- **No baked-in seed weight.** Each occurrence counts once; natural corpus
  frequency makes common commands rank higher. The `seed_weight = 0.5`
  thumb-on-the-scale is applied at *query* time by ``SeededSuggester``
  ([[2026-06-21-predictor-seed-deference-design]]), never in the stored counts —
  so the seed sketch is a plain frequency fingerprint, identical in format to a
  user's learned sketch (the [[2026-06-21-predictor-vocab-serialization-design]]
  blobs).
- **No privacy filter.** The seed is public CLI vocabulary; ``TokenFilter`` guards
  *user* recording, not seed building.
- Bigram sketch sized `4 × 2^16`, unigram `4 × 2^14` — the spec defaults, matching
  ``BigramVocabulary`` / ``Vocabulary``.

## neotilde-seedbuild — thin executable

`neotilde-seedbuild <pages-dir> <out-dir>`: recursively find `*.md` under
`pages-dir`, parse each, ingest, then write `seed_unigram_v1.sketch` and
`seed_bigram_v1.sketch` to `out-dir`. All real logic is in `SeedKit`; `main` is
directory walking + file read/write, deliberately too thin to need its own tests
(the parser and builder carry the coverage).

## Out of scope (later slices)

- **Carapace ingestion** (4k) — a `CarapaceParser` feeding the same `SeedBuilder`;
  merges `(command, subcommand)` / `(command, flag)` structure that tldr examples
  under-represent. May add a YAML dependency or shell out to `carapace … export`.
- **Curated dotfiles frequency** — the third master-spec source.
- **Runtime first-launch load into `seed_pinned`** (the consumer of these blobs).
- **Seed version bump / app-bundle resource wiring** — packaging `seed_*_vN.sketch`
  into the app.
