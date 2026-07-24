<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Predictor Seed Install Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install the bundled predictor seed dictionary at app launch so prediction works out of the box (fixes device issue #3).

**Architecture:** A pure Kit combined-blob codec (`BundledSeed.combinedBlob()` / `BundledSeed(combinedBlob:)`) shared by the build tool and the app so the on-disk format can't drift. The build tool gains a `--combined` output; the rebuild script pins corpus refs and writes a committed bundle resource + provenance; the app reads that resource at `AppStores.init` and calls the already-tested `SeedStore.installIfNeeded`.

**Tech Stack:** Swift 6 (SemicolynKit/SeedKit, Linux-tested XCTest), Swift 5 App tier (macOS-CI-only), bash (rebuild script), XcodeGen (resource bundling).

## Global Constraints

- SPDX header on every source file: `// SPDX-FileCopyrightText: 2026 True Positive LLC` then `// SPDX-License-Identifier: GPL-3.0-only` (shell: `#` comments).
- Kit code (`Sources/SemicolynKit/`, `Sources/SeedKit/`) is Swift 6 strict-concurrency, `Sendable`, `import Foundation` only — NO UIKit/SwiftUI/CryptoKit.
- Kit/SeedKit tests run ONLY in the `semicolyn-dev` Docker container: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <Suite>`. Docker needs `dangerouslyDisableSandbox: true` on the Bash call.
- App-tier (`App/`) does NOT compile on Linux; validated by the macOS CI job only.
- Combined-blob format is EXACTLY `SeedStore.combinedBlob` (`SeedStore.swift:107`): `magic "GSED"=[0x47,0x53,0x45,0x44](4) | formatVersion=1(1) | contentVersion LE32(4) | unigramLen LE32(4) | unigramBlob | bigramLen LE32(4) | bigramBlob`. `headerSize = 9`.
- Stage files EXPLICITLY by path (never `git add -A` — `extern/` submodules must stay untracked).
- Conventional commits. No em-dashes anywhere.
- License deliverables (from `plans/license-audit/REPORT.md`): tldr-pages CC-BY-4.0 (attribution + indicate-changes) and Fig MIT (copyright + permission notice) must ship as bundled attribution.

---

### Task 1: Kit combined-blob codec on `BundledSeed`

**Files:**
- Modify: `Sources/SemicolynKit/Predictor/SeedStore.swift` (add two methods to `BundledSeed`; refactor `SeedStore.combinedBlob`/`loadSeed` to reuse them)
- Test: `Tests/SemicolynKitTests/SeedStoreTests.swift` (add a round-trip + malformed suite)

**Interfaces:**
- Consumes: existing `BundledSeed { version: Int; unigramBlob: [UInt8]; bigramBlob: [UInt8] }`, `Vocabulary`, `BigramVocabulary`, the format constants (`magic`, `formatVersion`, `headerSize`) and the LE32/length-prefixed helpers already in `SeedStore.swift`.
- Produces:
  - `BundledSeed.combinedBlob() -> [UInt8]` (the `seed_pinned` byte layout for THIS seed)
  - `BundledSeed(combinedBlob bytes: [UInt8]) -> BundledSeed?` (fail-soft parse; nil on any malformed input) — a failable initializer.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/SemicolynKitTests/SeedStoreTests.swift` (new methods in the existing final class):

```swift
// Combined-blob codec: BundledSeed.combinedBlob() <-> BundledSeed(combinedBlob:).
// This is the seam the app-edge install and seedbuild both use; a drift here
// silently breaks seed install (device issue #3's exact failure).
func testCombinedBlobRoundTrips() {
    let seed = BundledSeed(version: 7, unigramBlob: [1, 2, 3, 4], bigramBlob: [9, 8])
    let blob = seed.combinedBlob()
    let parsed = BundledSeed(combinedBlob: blob)
    XCTAssertNotNil(parsed)
    XCTAssertEqual(parsed?.version, 7)
    XCTAssertEqual(parsed?.unigramBlob, [1, 2, 3, 4])
    XCTAssertEqual(parsed?.bigramBlob, [9, 8])
}

func testCombinedBlobRoundTripsEmptyBlobs() {
    let seed = BundledSeed(version: 1, unigramBlob: [], bigramBlob: [])
    let parsed = BundledSeed(combinedBlob: seed.combinedBlob())
    XCTAssertEqual(parsed?.version, 1)
    XCTAssertEqual(parsed?.unigramBlob, [])
    XCTAssertEqual(parsed?.bigramBlob, [])
}

func testParseRejectsTruncatedHeader() {
    XCTAssertNil(BundledSeed(combinedBlob: [0x47, 0x53]))   // < headerSize (9)
}

func testParseRejectsWrongMagic() {
    var blob = BundledSeed(version: 1, unigramBlob: [1], bigramBlob: [2]).combinedBlob()
    blob[0] = 0x00                                          // corrupt "GSED"
    XCTAssertNil(BundledSeed(combinedBlob: blob))
}

func testParseRejectsWrongFormatVersion() {
    var blob = BundledSeed(version: 1, unigramBlob: [1], bigramBlob: [2]).combinedBlob()
    blob[4] = 0x02                                          // formatVersion must be 1
    XCTAssertNil(BundledSeed(combinedBlob: blob))
}

func testParseRejectsTrailingSlack() {
    var blob = BundledSeed(version: 1, unigramBlob: [1], bigramBlob: [2]).combinedBlob()
    blob.append(0xFF)                                       // extra byte past the bigram
    XCTAssertNil(BundledSeed(combinedBlob: blob))
}

func testParseRejectsTruncatedBody() {
    let blob = BundledSeed(version: 1, unigramBlob: [1, 2, 3], bigramBlob: [4]).combinedBlob()
    XCTAssertNil(BundledSeed(combinedBlob: Array(blob.dropLast())))   // last body byte missing
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter SeedStoreTests` (Docker: `dangerouslyDisableSandbox: true`)
Expected: FAIL to compile — "value of type 'BundledSeed' has no member 'combinedBlob'" / "incorrect argument label ... 'combinedBlob:'".

- [ ] **Step 3: Add the codec to `BundledSeed`, refactor `SeedStore` to reuse it**

In `Sources/SemicolynKit/Predictor/SeedStore.swift`, the format constants + LE helpers currently live on `SeedStore` as `private static`. Make them reachable from `BundledSeed`'s codec. Simplest faithful refactor: move the format constants + the byte helpers to file-scope `private` free functions / a shared `enum SeedBlobFormat`, then implement the codec on `BundledSeed` and have `SeedStore.combinedBlob`/`loadSeed` call the shared code.

Add to `BundledSeed`:

```swift
extension BundledSeed {
    /// Serialize to the single `seed_pinned` on-disk layout:
    /// `magic | formatVersion | contentVersion | len|unigram | len|bigram`.
    /// Identical bytes to what `SeedStore` writes on install, so the build tool and
    /// the app-edge installer can never produce a layout `SeedStore.loadSeed` rejects.
    public func combinedBlob() -> [UInt8] {
        var out: [UInt8] = []
        out.append(contentsOf: SeedBlobFormat.magic)
        out.append(SeedBlobFormat.formatVersion)
        SeedBlobFormat.appendLE32(&out, UInt32(max(0, version)))
        SeedBlobFormat.appendLE32(&out, UInt32(unigramBlob.count))
        out.append(contentsOf: unigramBlob)
        SeedBlobFormat.appendLE32(&out, UInt32(bigramBlob.count))
        out.append(contentsOf: bigramBlob)
        return out
    }

    /// Parse the combined layout back into a `BundledSeed`. Fail-soft: nil on any
    /// malformed input (short/wrong-magic/wrong-format/truncated body/trailing slack),
    /// mirroring `SeedStore.loadSeed`'s never-throw contract.
    public init?(combinedBlob bytes: [UInt8]) {
        guard bytes.count >= SeedBlobFormat.headerSize,
              Array(bytes[0..<4]) == SeedBlobFormat.magic,
              bytes[4] == SeedBlobFormat.formatVersion,
              let contentVersion = SeedBlobFormat.readLE32(bytes, 5) else { return nil }
        var p = SeedBlobFormat.headerSize
        guard let uni = SeedBlobFormat.readLengthPrefixed(bytes, &p),
              let bi = SeedBlobFormat.readLengthPrefixed(bytes, &p),
              p == bytes.count else { return nil }
        self.init(version: Int(contentVersion), unigramBlob: uni, bigramBlob: bi)
    }
}
```

Introduce `SeedBlobFormat` (file-scope, in the same file) holding `magic`, `formatVersion`, `headerSize`, `appendLE32`, `readLE32`, `readLengthPrefixed` — moved verbatim from the existing `SeedStore` privates. Update `SeedStore.combinedBlob(_ bundled:)` to `return bundled.combinedBlob()` and keep `SeedStore.loadSeed` using `SeedBlobFormat`'s helpers (or, cleaner, `BundledSeed(combinedBlob:)` then hand its blobs to the `Vocabulary`/`BigramVocabulary` deserializers). Do NOT change the byte layout or any existing behavior — the existing `SeedStoreTests` install/load cases must still pass unchanged.

- [ ] **Step 4: Run the whole SeedStore suite to verify pass + no regression**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter SeedStoreTests` (Docker: `dangerouslyDisableSandbox: true`)
Expected: PASS — the 7 new codec tests AND every pre-existing SeedStore install/load test.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Predictor/SeedStore.swift Tests/SemicolynKitTests/SeedStoreTests.swift
git commit -m "feat(predictor): BundledSeed combined-blob codec (shared seed_pinned format)"
```

---

### Task 2: `semicolyn-seedbuild --combined` output

**Files:**
- Modify: `Sources/semicolyn-seedbuild/main.swift` (add `--combined` flag + write path)
- Test: `Tests/SeedKitTests/` — add an output-shape test if SeedKit exposes the builder; otherwise a focused unit test on the combined-write helper (see step 1).

**Interfaces:**
- Consumes: `BundledSeed.combinedBlob()` (Task 1); the existing `builder.blobs()` → `(unigram: [UInt8], bigram: [UInt8])` (`main.swift:108`).
- Produces: a CLI that writes one `seed_pinned`-format file at `--combined <path>`.

> **Note:** `main.swift` is an executable entry point (top-level code), awkward to unit-test directly. Put the assembly in a tiny testable helper in `SeedKit` and have `main.swift` call it.

- [ ] **Step 1: Write the failing test**

Add `Tests/SeedKitTests/CombinedSeedWriteTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SeedKit
import SemicolynKit

final class CombinedSeedWriteTests: XCTestCase {
    // The build tool must assemble the two blobs into a seed_pinned-format blob that
    // the app's BundledSeed(combinedBlob:) parses back to the same content.
    func testCombinedBlobFromBuilderBlobsParsesBack() {
        let combined = combinedSeedBlob(version: 1, unigram: [10, 20], bigram: [30])
        let parsed = BundledSeed(combinedBlob: combined)
        XCTAssertEqual(parsed?.version, 1)
        XCTAssertEqual(parsed?.unigramBlob, [10, 20])
        XCTAssertEqual(parsed?.bigramBlob, [30])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter CombinedSeedWriteTests` (Docker: `dangerouslyDisableSandbox: true`)
Expected: FAIL — "cannot find 'combinedSeedBlob' in scope".

- [ ] **Step 3: Add the helper + wire `--combined` in main.swift**

Add to `SeedKit` (e.g. `Sources/SeedKit/CombinedSeed.swift`):

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SemicolynKit

/// Assemble the two serialized blobs into the single seed_pinned-format blob the app
/// installs. Thin wrapper over `BundledSeed.combinedBlob()` so `main.swift` stays glue.
public func combinedSeedBlob(version: Int, unigram: [UInt8], bigram: [UInt8]) -> [UInt8] {
    BundledSeed(version: version, unigramBlob: unigram, bigramBlob: bigram).combinedBlob()
}
```

In `Sources/semicolyn-seedbuild/main.swift`: add `--combined` to `knownFlags` (`main.swift:25`) and, after `let blobs = builder.blobs()` (`main.swift:108`), when `options["--combined"]` is set, write the combined blob:

```swift
if let combinedPath = options["--combined"] {
    let combined = combinedSeedBlob(version: 1, unigram: blobs.unigram, bigram: blobs.bigram)
    let url = URL(fileURLWithPath: combinedPath)
    do {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(combined).write(to: url)
    } catch { fail("combined write failed: \(error)") }
    print("  combined seed: \(combined.count) bytes → \(url.path)")
}
```

Keep the existing two-file `--out` write. Update the usage string + doc comment to mention `--combined <file>`.

- [ ] **Step 4: Run to verify pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter CombinedSeedWriteTests` (Docker: `dangerouslyDisableSandbox: true`)
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SeedKit/CombinedSeed.swift Sources/semicolyn-seedbuild/main.swift Tests/SeedKitTests/CombinedSeedWriteTests.swift
git commit -m "feat(seedbuild): --combined output writes seed_pinned-format blob"
```

---

### Task 3: rebuild script (pinned refs, combined output, provenance) + build the committed seed

**Files:**
- Modify: `scripts/build-seed.sh` (pinned ref defaults, `--combined` target, provenance write)
- Create (build output, committed): `App/Resources/predictor/seed_v1.sketch`, `App/Resources/predictor/seed_v1.provenance.txt`
- Modify: `.gitignore` (the seed resource must NOT be ignored; today `/seeds/` is ignored — that stays, but the new `App/Resources/predictor/` path is outside it)

**Interfaces:**
- Consumes: `semicolyn-seedbuild --combined` (Task 2).
- Produces: a committed bundle resource the app reads (Task 5) and XcodeGen bundles (Task 4).

> **Note:** running the script clones tldr + Fig (network) and runs a release Swift build. This is a build-tooling + artifact task; the "test" is that the produced blob parses and contains expected tokens.

- [ ] **Step 1: Add pinned defaults + combined target + provenance to build-seed.sh**

Edit `scripts/build-seed.sh`:
- Set pinned defaults near the repo vars (choose current stable tags at run time):
  `: "${TLDR_REF:=v2.3}"` and `: "${FIG_REF:=<current-stable-sha-or-tag>}"` (resolve the actual current values when running; record them). Keep the env-override behavior.
- Change the default `OUT_DIR` handling so the combined seed targets the committed resource. After the existing `swift run ... semicolyn-seedbuild` call, add `--combined "App/Resources/predictor/seed_v1.sketch"` to the invocation (create the dir first).
- After the build, write provenance:

```bash
PROV="App/Resources/predictor/seed_v1.provenance.txt"
{
  echo "seed content version: 1"
  echo "built: $(git rev-parse HEAD) (semicolyn)"
  echo "tldr-pages: $TLDR_REF @ $(git -C "$WORK/tldr" rev-parse HEAD) (CC-BY-4.0)"
  echo "fig autocomplete: $FIG_REF @ $(git -C "$WORK/fig" rev-parse HEAD) (MIT)"
} > "$PROV"
echo "wrote $PROV"
```

(Do NOT hardcode a fake commit SHA in the script — it reads the real one from the clone. The `git rev-parse HEAD (semicolyn)` line must not fail the script if run in a dirty tree; it is provenance only.)

- [ ] **Step 2: Run the script to build the committed seed**

Run (network + release build; may take a few minutes): `bash scripts/build-seed.sh` (Docker/sandbox: this needs network to clone; run with `dangerouslyDisableSandbox: true` if the clone is blocked).
Expected: `App/Resources/predictor/seed_v1.sketch` exists and is non-trivially sized (hundreds of KB), and `seed_v1.provenance.txt` records the two resolved SHAs.

- [ ] **Step 3: Verify the built blob parses and has real content**

Write a throwaway check (a temp Swift test or a `swift run` snippet) that loads `App/Resources/predictor/seed_v1.sketch` via `BundledSeed(combinedBlob:)` and asserts `version == 1`, non-empty unigram/bigram, and that deserializing the unigram yields a `Vocabulary` containing a common command (e.g. `git`). Do not commit the throwaway; it is a gate.
Expected: parses; `git` present.

- [ ] **Step 4: Commit the script + the built seed + provenance**

```bash
git add scripts/build-seed.sh App/Resources/predictor/seed_v1.sketch App/Resources/predictor/seed_v1.provenance.txt
git commit -m "feat(predictor): build + commit bundled seed_v1 (pinned tldr+fig) + provenance"
```

---

### Task 4: Bundle the seed resource + ship attribution (`project.yml`, REUSE, attribution file)

**Files:**
- Modify: `project.yml` (exclude the provenance/attribution/license sidecars from the bundled RESOURCE copy, mirroring the fonts `.license` exclude)
- Create: `App/Resources/predictor/SEED_ATTRIBUTION.md` (committed; bundled so CC-BY attribution ships)
- Create: `App/Resources/predictor/seed_v1.sketch.license` (REUSE sidecar) — and/or a `REUSE.toml` entry

**Interfaces:**
- Consumes: the committed `seed_v1.sketch` (Task 3).
- Produces: a bundled app resource (`seed_v1.sketch`) reachable via `Bundle.main.url(forResource:"seed_v1", withExtension:"sketch")` in Task 5.

> **Note:** App-tier / build config — validated by the macOS CI job (does the app bundle build with the resource) + confirming the resource is in the built `.app`.

- [ ] **Step 1: Write the attribution file**

Create `App/Resources/predictor/SEED_ATTRIBUTION.md`:

```markdown
<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Predictor seed attribution

The bundled command-prediction seed (`seed_v1.sketch`) is a derived token-frequency
fingerprint built from two open corpora. It contains extracted CLI command tokens and
their frequencies, not verbatim source text; argument placeholders are removed.

## tldr-pages (https://github.com/tldr-pages/tldr) — CC-BY-4.0
Licensed under the Creative Commons Attribution 4.0 International License
(https://creativecommons.org/licenses/by/4.0/). Changes were made: command-token
sequences were extracted from the example pages and reduced to frequency counts.

## Fig autocomplete (https://github.com/withfig/autocomplete) — MIT
The MIT License. Copyright (c) 2021 Hercules Labs Inc. (Fig).
Permission is hereby granted, free of charge, to any person obtaining a copy of this
software and associated documentation files (the "Software"), to deal in the Software
without restriction [...] THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
```

- [ ] **Step 2: Add the REUSE sidecar for the binary blob**

Create `App/Resources/predictor/seed_v1.sketch.license`:

```
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only

This build artifact is derived from tldr-pages (CC-BY-4.0) and Fig autocomplete (MIT);
see SEED_ATTRIBUTION.md and seed_v1.provenance.txt.
```

- [ ] **Step 3: Exclude sidecars from the bundled resource copy in project.yml**

In `project.yml` under the `App` source's `excludes` (currently `Resources/Fonts/*.license`), add the predictor sidecars so only `seed_v1.sketch` ships as a runtime resource (the `.md`/`.txt`/`.license` are repo docs). The `SEED_ATTRIBUTION.md` may be bundled if you want it readable in-app; per the spec, bundling it is fine — exclude only the `.license` sidecar and `.provenance.txt`:

```yaml
        excludes:
          - "Resources/Fonts/*.license"
          - "Resources/predictor/*.license"
          - "Resources/predictor/*.provenance.txt"
```

(Leave `seed_v1.sketch` and `SEED_ATTRIBUTION.md` bundled.)

- [ ] **Step 4: Commit**

```bash
git add project.yml App/Resources/predictor/SEED_ATTRIBUTION.md App/Resources/predictor/seed_v1.sketch.license
git commit -m "feat(predictor): bundle seed resource + tldr/fig attribution + REUSE sidecar"
```

---

### Task 5: App-edge install at launch (`AppStores.init`)

**Files:**
- Modify: `App/AppStores.swift` (call an installer at the end of `init()`; add the private helper)

**Interfaces:**
- Consumes: `BundledSeed(combinedBlob:)` (Task 1); `SeedStore.installIfNeeded(_:)` (existing); the bundled `seed_v1.sketch` resource (Task 4); `baseDirectory` (`AppStores.swift:59`); `DebugLog.shared.log(.seed, ...)`.
- Produces: an installed `seed_pinned.sketch` so `predictorSeed()` returns non-nil (terminal task — closes issue #3).

> **Note:** App-tier, NOT Linux-buildable. Validation = macOS CI compile + device trace. No local red/green.

- [ ] **Step 1: Add the installer call + helper**

In `App/AppStores.swift`, at the END of `init()` (after `self.identities = ...`, `AppStores.swift:84`), add:

```swift
        // Install the bundled predictor seed on first launch / version upgrade so
        // prediction works out of the box. Fail-soft: a missing/corrupt resource must
        // never break launch (degrades to learned-only, matching loadSeed's contract).
        // This is the app-edge glue Phase 4l deferred; its absence was device issue #3.
        installBundledSeedIfNeeded()
```

Add the private helper (same file, in the predictor section):

```swift
    /// Read the bundled combined seed resource and install it via SeedStore
    /// (idempotent + self-healing). No-op if the resource is absent (dev builds
    /// without a committed seed) or unparseable. Never throws into launch.
    private func installBundledSeedIfNeeded() {
        guard let url = Bundle.main.url(forResource: "seed_v1", withExtension: "sketch"),
              let data = try? Data(contentsOf: url) else {
            DebugLog.shared.log(.seed, "seed:install skipped=no-resource")
            return
        }
        guard let bundled = BundledSeed(combinedBlob: [UInt8](data)) else {
            DebugLog.shared.log(.seed, "seed:install skipped=unparseable bytes=\(data.count)")
            return
        }
        let store = SeedStore(directory: baseDirectory.appendingPathComponent("predictor", isDirectory: true))
        do {
            let didInstall = try store.installIfNeeded(bundled)
            DebugLog.shared.log(.seed, "seed:install installed=\(didInstall) version=\(bundled.version)")
        } catch {
            DebugLog.shared.log(.seed, "seed:install failed error=\(error)")
        }
    }
```

Confirm `SeedStore` + `BundledSeed` are visible here (they are `public` in `SemicolynKit`, already imported by `AppStores.swift` — verify the import; add `import SemicolynKit` if missing).

- [ ] **Step 2: Push + validate on macOS CI**

No local build for App-tier. Commit, push, watch the macos job compile.

```bash
git add App/AppStores.swift
git commit -m "fix(predictor): install bundled seed at launch (fixes prediction issue #3)"
git push github feat/finger-drag-window-transition
```

Watch: `gh run list --repo ds7n/semicolyn --branch feat/finger-drag-window-transition --limit 1`
Expected: `macos` job passes.

- [ ] **Step 3: Gate TestFlight on macOS-green, then device-verify**

Once macos is green, trigger TestFlight and device-verify the FIX:
- Settings → Diagnostics: enable `predictor`, `input`, `keybar`.
- Attach a tmux pane; type `gi` (no prior history). A `git` chip should appear.
- Pull syslog; confirm `seed:install installed=... version=1`, then `predictor:suggest prefixLen>=2 results>0` and `predictor:surface count>0`.

```bash
gh workflow run "Release to TestFlight" --repo ds7n/semicolyn --ref feat/finger-drag-window-transition
```

Expected: chips appear from the seed alone (no re-typing needed). This is the end-to-end proof that issue #3 is fixed.

---

## Self-Review

**Spec coverage:**
- Combined-blob codec shared to prevent drift → Task 1. ✓
- seedbuild `--combined` output → Task 2. ✓
- Rebuild script pinned refs + combined target + provenance → Task 3. ✓
- Commit the built blob as a bundle resource → Task 3 (build) + Task 4 (bundle config). ✓
- `installIfNeeded` at `AppStores.init`, fail-soft → Task 5. ✓
- Attribution (tldr CC-BY-4.0 + Fig MIT) + REUSE sidecar → Task 4. ✓
- Device verification (`results>0`, chips from seed) → Task 5 Step 3. ✓
- Non-goal (under-learning) NOT implemented → correct, deferred. ✓

**Placeholder scan:** `<current-stable-sha-or-tag>` for FIG_REF and the TLDR_REF pin are resolve-at-runtime values (the script reads the real SHA into provenance); flagged as a deliberate implementation-time choice, not a lazy TODO. All code steps show full code. ✓

**Type consistency:** `BundledSeed.combinedBlob() -> [UInt8]` and `BundledSeed(combinedBlob:) -> BundledSeed?` (Task 1) are consumed with those exact signatures in Tasks 2 and 5. `combinedSeedBlob(version:unigram:bigram:)` (Task 2) matches its test. `SeedStore.installIfNeeded(_:) throws -> Bool` matches existing. ✓
