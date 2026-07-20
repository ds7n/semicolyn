<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Design: predictor seed install (the missing app-edge glue) — 2026-07-20

## Problem

The predictor never suggests anything on device (issue #3, TF build 66). Root cause,
proven from device traces + code + git history (see `.superpowers/sdd/predictor-3-diagnosis.md`):

**The bundled seed dictionary is never installed into the running app.** The engine is
built with `seed: AppStores.shared.predictorSeed()` (`ConnectionViewModel.swift:1129`);
`predictorSeed()` calls `SeedStore(.../predictor).loadSeed()` (`AppStores.swift:114`);
`loadSeed()` reads `seed_pinned.sketch`, which only exists after
`installIfNeeded(_ bundled:)` writes it. **`installIfNeeded` is never called anywhere in
`App/`** — every call in history is in `SeedStoreTests`. So the engine runs with `seed=nil`
+ an empty learned store, and `predictor:suggest` returns `results=0` for every prefix in
both tmux and raw-SSH (device trace: `prefixLen=11 results=0` in raw).

Why: the Phase 4l seed-runtime-load spec (`2026-06-21-predictor-seed-runtime-load-design.md`)
shipped the Kit logic (`SeedStore.installIfNeeded` + `loadSeed`, Linux-tested) and
**explicitly deferred** the app-edge glue: *"the app edge that constructs `directory` and
`BundledSeed`; trivial glue, no test value."* That glue was never done; the next phase
(4m) moved to a different concern and nothing tracked it.

This spec is that missing glue, plus how the seed blob physically reaches the app bundle.

## Approach (locked decisions)

- **Commit the built seed blob to the repo** as a bundled resource; provide a rebuild
  script to refresh it on demand. No CI seed build (avoids adding a slow, network-dependent
  clone+release-build step to the macOS job). Refreshing the corpus is a deliberate,
  occasional maintenance action, exactly like the committed `.ttf` fonts.
- **One combined blob** (recommended; flag for veto at review): extend
  `semicolyn-seedbuild` to emit a single `seed_pinned`-format file so the app reads ONE
  bundle resource and the SeedStore's atomic single-file invariant is preserved end to end.
- **Pinned corpus refs** (recommended; flag for veto): the rebuild script hardcodes
  known-good `TLDR_REF` + `FIG_REF` defaults so the committed blob maps to an auditable
  corpus snapshot (required for the CC-BY attribution + provenance obligations).

## License obligations (from `plans/license-audit/REPORT.md`)

Both corpus sources are compatible with our GPL-3.0-only license; neither is a blocker.
Obligations that are REQUIRED deliverables of this spec:

- **tldr-pages** (`pages/`, **CC-BY-4.0**): attribution + indicate-changes. One-way
  compatible into GPLv3 (CC-documented). We ship a derived token-frequency fingerprint,
  not verbatim pages.
- **Fig autocomplete** (`src/`, **MIT**): include the copyright + permission notice.

## Components

### 1. `semicolyn-seedbuild` — add a combined-blob output

Today (`Sources/semicolyn-seedbuild/main.swift:112-113`) it writes two files:
`seed_unigram_v1.sketch` + `seed_bigram_v1.sketch`. Add a `--combined <file>` option that
writes ONE file in the exact `seed_pinned.sketch` on-disk format that `SeedStore` expects,
so the app can install it verbatim.

The combined format must match `SeedStore.combinedBlob` (`SeedStore.swift:107`):
`magic "GSED"(4) | formatVersion(1)=1 | contentVersion LE32 | len LE32 | unigramBlob | len LE32 | bigramBlob`.

To avoid duplicating that byte layout in two places, move the blob-assembly into a shared
`SeedKit` (or `SemicolynKit`) function that BOTH `SeedStore.installIfNeeded` (indirectly)
and `seedbuild --combined` call. Concretely: expose the existing packing as
`BundledSeed.combinedBlob() -> [UInt8]` on `BundledSeed` (Kit, Linux-tested), have
`seedbuild` construct a `BundledSeed(version:1, unigramBlob:, bigramBlob:)` and write
`bundledSeed.combinedBlob()`. `SeedStore` continues to write via its own path on install;
the shared function guarantees the two byte layouts can never drift.

`--out` (two-file) mode stays for backward compat and debugging. `--combined` is additive.

### 2. `scripts/build-seed.sh` → pinned refs + combined output + provenance

- Set known-good defaults: `TLDR_REF="${TLDR_REF:-<pin>}"`, `FIG_REF="${FIG_REF:-<pin>}"`
  (choose current stable tags at build time; the script already warns when unset — now it
  won't be unset by default). Overridable via env for a deliberate bump.
- Invoke seedbuild with `--combined` targeting the committed resource path:
  `App/Resources/predictor/seed_v1.sketch`.
- Emit `App/Resources/predictor/seed_v1.provenance.txt`: the resolved `TLDR_REF`/`FIG_REF`
  and the two `git rev-parse HEAD` SHAs the script already prints, plus the seed content
  version. This is the auditable corpus snapshot record.
- The script is the "rebuild it" tool: run it, commit the updated `seed_v1.sketch` +
  provenance. Bumping the content version (`seed_v2`) triggers `installIfNeeded`'s
  version-upgrade reinstall on the next app launch.

### 3. Bundle the resource (`project.yml`)

XcodeGen auto-classifies non-source files under `App/` as bundle resources (that is how
`App/Resources/Fonts/*.ttf` are bundled). Place the seed under `App/Resources/predictor/`
so it is bundled the same way. Exclude the `.provenance.txt` and any `.license` sidecar
from the RESOURCE copy (they are repo docs, not runtime assets) via the existing
resource-exclude pattern in `project.yml` (mirrors the `Resources/Fonts/*.license`
exclusion already present).

### 4. App-edge install (`App/AppStores.swift`)

The missing glue. Read the bundled resource, build a `BundledSeed`, call `installIfNeeded`
at launch BEFORE any `predictorSeed()` read.

- **Where:** at the end of `AppStores.init()` (after `baseDirectory` is set,
  `AppStores.swift:59`), a `try? installBundledSeedIfNeeded()` call. Use `try?` — a
  missing/corrupt bundle resource must NEVER break app launch (fail-soft to learned-only,
  matching `loadSeed`'s contract). Log the outcome via `DebugLog.shared.log(.seed, ...)`.
- **Reader:** a private helper `installBundledSeedIfNeeded()`:
  1. `Bundle.main.url(forResource: "seed_v1", withExtension: "sketch")` — return (no-op)
     if absent (dev builds without a committed seed still run).
  2. Read the bytes; parse the combined blob back into `(version, unigramBlob, bigramBlob)`
     using a Kit helper `BundledSeed(combinedBlob:) -> BundledSeed?` (the inverse of
     `combinedBlob()`, fail-soft nil on any malformed input — reuses the same magic/length
     checks `SeedStore.loadSeed` already implements, factored into Kit so the parse lives
     in one tested place).
  3. `try SeedStore(directory: baseDirectory.appendingPathComponent("predictor")).installIfNeeded(bundledSeed)`.
     Idempotent + self-healing (reinstalls on absent/newer/corrupt).
  4. `DebugLog.shared.log(.seed, "seed:install installed=\(didInstall) version=\(v)")`.

`installIfNeeded` is already atomic and version-aware; no change to `SeedStore`'s install
logic. `predictorSeed()` (unchanged) now finds an installed `seed_pinned.sketch` and returns
a non-nil `PredictorSeed`.

### 5. Attribution + REUSE

- `App/Resources/predictor/SEED_ATTRIBUTION.md` (committed): tldr-pages (CC-BY-4.0, license
  link, "derived: command-token frequencies; argument placeholders removed") + Fig (MIT,
  "© 2021 Hercules Labs Inc. (Fig)", full permission notice). Bundle it (or surface its
  content) so CC-BY attribution is user-reachable.
- REUSE: the committed binary `seed_v1.sketch` gets a `.license`/`REUSE.toml` entry. Its own
  SPDX is our GPL-3.0-only (it is our build output); the entry notes the upstream corpus
  licenses (CC-BY-4.0, MIT) it derives from.
- In-app: ensure a Settings → About/Acknowledgements surface reaches the CC-BY/MIT credits
  (CC-BY wants attribution visible to users, not only in-repo). If no such surface exists
  yet, that is a small follow-up, not a blocker for the fix — but the bundled attribution
  file must ship in this change.

## Testing

- **Kit (Linux, TDD):** `BundledSeed.combinedBlob()` round-trips with
  `BundledSeed(combinedBlob:)` — build a BundledSeed, serialize, parse back, assert
  version + both blobs are byte-identical. Boundary/negative: truncated blob, wrong magic,
  wrong formatVersion, trailing slack → parse returns nil (fail-soft). These share the
  format with `SeedStore` (already tested for the install/load path in `SeedStoreTests`),
  so the new tests specifically cover the combined-blob assembly/parse SEAM the app-edge
  and seedbuild both use.
- **seedbuild (Linux):** `--combined` over a small fixture corpus writes a file that
  `BundledSeed(combinedBlob:)` parses to the expected token set. Assert observable tokens
  (e.g. fixture with `git commit` → unigram contains `git`, `commit`), not just "file
  non-empty".
- **App-edge (macOS-CI + device):** the `AppStores` install path is App-tier (not
  Linux-testable). Validation is: macOS CI compile + a device retest showing
  `predictor:suggest results>0` for a common prefix (`gi` → `git`), `surface count>0`, and
  chips visible. The device trace is the end-to-end proof.

## Non-goals

- **The record/echo under-learning** (`predictor:record tokens=0/1`,
  `recordSuppressed echo=false`) is a SEPARATE, secondary issue. With a seed installed the
  predictor is useful immediately; the learning path can then be diagnosed against a working
  baseline. Explicitly out of scope here — do NOT conflate.
- **CI-built seed / cache-on-bump** — rejected in favor of commit-the-blob + rebuild script.
- **Full package-manifest license audit** (Rust/Swift/`extern/`) — a separate pass before
  release (noted in the audit report footer).
- **A new Acknowledgements screen** if none exists — the bundled attribution file ships now;
  the user-facing surface is a small follow-up if missing.
