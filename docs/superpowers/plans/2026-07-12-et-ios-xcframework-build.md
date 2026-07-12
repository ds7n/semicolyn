<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# eternaltermlib → iOS xcframework build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement
> this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `eternaltermlib` (vendored ET C client library) compile for iOS inside semicolyn's
GitHub CI and emit an `ETerminal.xcframework` (device arm64 + simulator arm64/x86_64), linked as a
`#if os(macOS)` binaryTarget in `Package.swift` — mirroring how `Mosh.xcframework` is done today.

**Scope (this plan ONLY):** the iOS *compile + package* step. Deliberately EXCLUDED (downstream, separate
plans): the Swift `libetios` wrapper over the C ABI, the SSH bootstrap that plants ET's `(id, passkey)`
credential, the `TmuxRuntime` drop-in, and the per-host Transport picker (Auto/SSH/Mosh/ET). The parent
design lives in `docs/superpowers/specs/2026-07-10-et-transport-design.md` (unmerged branch
`docs/et-transport-spec`). Success here = the xcframework builds green on macOS CI; nothing consumes it yet.

**Why this plan is execution, not design:** the hard technical calls were made (the miserable way) in the
eternaltermlib session and are captured in two docs vendored here: `extern/eternaltermlib/docs/porting-ios.md`
and the handoff (`HANDOFF-semicolyn-ios-ci.md`). This plan just wires them against semicolyn's real paths.

## Locked decisions (do NOT re-litigate)

- **Artifact:** own `ETerminal.xcframework` (mirror `Mosh.xcframework`), not compile-as-source. Keeps the
  C++/protobuf blob off the Linux `swift test` job; build once + cache.
- **Toolchain:** `leetal/ios-cmake` (vendored submodule). Avoids the `find_package`/`find_library`
  cross-compile traps that made the hand-rolled attempt miserable. Do NOT reuse the Mosh hand-rolled cross
  flags for ET's CMake — ET calls `find_package(Protobuf)` + `find_library(sodium)` which the Mosh script
  never did.
- **libsodium:** consume the **prebuilt `Clibsodium.xcframework`** from the vendored `jedisct1/swift-sodium`
  submodule (author-maintained, updated Jan 2026). NO self-build. Feed ET's CMake explicitly via
  `-Dsodium_LIBRARY_RELEASE=…/libsodium.a` + `-Dsodium_INCLUDE_DIR=…/Headers/Clibsodium` +
  `-Dsodium_USE_STATIC_LIBS=ON` (the upstream ET `build_static.sh` pattern) — bypassing fragile
  `find_library` discovery. This is why `sodium_INCLUDE_DIR` must point at `Headers/Clibsodium` (where
  `sodium.h` actually lives), NOT `Headers/`.
- **protobuf-lite:** reuse semicolyn's EXISTING iOS protobuf cross-build. `scripts/build-mosh-xcframework.sh`
  already builds host `protoc` + cross `libprotobuf.a` + `libprotobuf-lite.a` per iOS slice (3.21.12). ET's
  `find_package(Protobuf)` needs host protoc; the target link needs the cross `.a`. `ET_HTTP_TLS=OFF` means
  ET links protobuf-lite only, no OpenSSL/zlib.
- **`ET_HTTP_TLS=OFF`:** always. Drops OpenSSL + zlib (the one painful iOS cross-dep). Verified on Linux to
  build/link with zero OpenSSL symbols and a working transport.
- **xcframework assembly:** explode every `.a` to `.o` and combine the object list (Mosh script lines
  318-369) — do NOT `libtool -static a.a b.a …` (Apple libtool silently de-dups members across archives and
  drops whole object files). ET has THREE archives to fold in: `libet_base.a`, `libeternaltermlib.a`,
  `libprotobuf-lite.a`. libsodium stays SEPARATE (its own xcframework slice is linked at app-link time, not
  merged — matches how a prebuilt binary dep is normally consumed).

## Global constraints (from CLAUDE.md)

- **Two-tier rule:** the xcframework + `build-etios-xcframework.sh` + CI wiring are **Apple-only**, validated
  ONLY by the macOS CI job. They do NOT build on Linux and are invisible to `swift test`.
- **SPDX header** on every new file: semicolyn files = `GPL-3.0-only` © True Positive LLC. (ET's own headers
  stay Apache-2.0 — do not rewrite vendored headers.)
- **Conventional commits**; one feature branch `feat/et-ios-build` (already created).
- **macOS CI is the only gate.** Each run is ~20 min; batch changes, read logs before re-pushing — the whole
  point of the porting docs is to avoid blind iterations.
- **License:** libsodium = ISC, protobuf = BSD-3, ET + eternaltermlib = Apache-2.0 — all permissive,
  compatible with the app. A combined-binary license audit is owed before distribution (hygiene, not a
  blocker for CI). Preserve ET's `NOTICE`.

## Real paths (verified on disk 2026-07-12)

- ET C ABI header: `extern/eternaltermlib/include/eternaltermlib.h` (134 lines, entire public surface).
- ET CMake targets: `eternaltermlib` (STATIC, the shim: `src/shim.cpp` + `transport.cpp` + `session.cpp`)
  links `et_base` (STATIC, vendored ET + protobuf srcs). `project(eternaltermlib VERSION 0.0.1)`.
- ET sodium consumption: `find_library(SODIUM_LIB sodium REQUIRED)` (CMakeLists:32),
  `find_package(sodium REQUIRED)` in the vendored ET (`extern/eternalterminal/CMakeLists.txt:131`).
- libsodium prebuilt slices (from swift-sodium 0.11.0):
  - device: `extern/swift-sodium/Clibsodium.xcframework/ios-arm64_arm64e/{libsodium.a, Headers/Clibsodium/sodium.h}`
  - sim: `extern/swift-sodium/Clibsodium.xcframework/ios-arm64_arm64e_x86_64-simulator/{libsodium.a, Headers/Clibsodium/sodium.h}`
- Mosh xcframework precedent: `scripts/build-mosh-xcframework.sh` (host protoc + 3-slice cross + explode-and-combine + create-xcframework).
- `Package.swift` binaryTarget pattern: lines 23-32 (`#if os(macOS)` … `.binaryTarget(name: "Mosh", path: "Mosh.xcframework")`).

## File structure

**New:**
- `scripts/build-etios-xcframework.sh` — cross-build eternaltermlib per iOS slice (leetal toolchain,
  `ET_HTTP_TLS=OFF`, explicit sodium paths, reuse Mosh's protobuf), combine `.a`s, `-create-xcframework`.
- `docs/et-ios-build-notes.md` — durable capture of the porting findings + real paths (so the next session
  doesn't re-derive them). References the two vendored porting docs.

**Modified:**
- `.gitmodules` + `extern/eternaltermlib` + `extern/swift-sodium` — submodules (DONE in Task 0).
- `Package.swift` — add the `ETerminal` binaryTarget (`#if os(macOS)`), wired into the FFI target deps like `Mosh`.
- `.github/workflows/ci.yml` — extend the `macos` job (or add a step) to fetch leetal/ios-cmake, run
  `build-etios-xcframework.sh`, cache libsodium (already prebuilt → cache is cheap/optional).
- `README.md` / `docs/ARCHITECTURE.md` — one line noting ET is vendored + iOS-built like Mosh (optional, low priority).

---

## Task 0: Vendor submodules (DONE — verify only)

**Files:** `.gitmodules`, `extern/eternaltermlib`, `extern/swift-sodium`.

Already executed this session: `extern/eternaltermlib` pinned to `4852a6b` (nested ET submodules
init'd recursively), `extern/swift-sodium` pinned to tag `0.11.0`.

- [ ] **Step 1: Verify submodule state**

```bash
git submodule status | grep -E 'eternaltermlib|swift-sodium'
# expect: 4852a6b extern/eternaltermlib (…), <sha> extern/swift-sodium (0.11.0)
test -f extern/eternaltermlib/CMakeLists.txt || echo "FATAL: ET not checked out"
test -f extern/swift-sodium/Clibsodium.xcframework/ios-arm64_arm64e/libsodium.a || echo "FATAL: no ios sodium slice"
test -f extern/eternaltermlib/extern/eternalterminal/CMakeLists.txt || echo "FATAL: nested ET submodule not init'd"
```

- [ ] **Step 2: Commit the submodule additions**

```bash
git add .gitmodules extern/eternaltermlib extern/swift-sodium
git commit -m "build(et): vendor eternaltermlib + swift-sodium submodules for the iOS build"
```

---

## Task 1: Capture the porting findings durably (docs, no build)

**Files:** Create `docs/et-ios-build-notes.md`.

**Why:** the two source docs (`extern/eternaltermlib/docs/porting-ios.md` + the handoff) are the load-bearing
knowledge. Consolidate the semicolyn-specific version (real paths, the "reuse Mosh protobuf" + "prebuilt
sodium" decisions, the traps) so a fresh session can act without re-searching.

- [ ] **Step 1: Write `docs/et-ios-build-notes.md`** with SPDX header, covering:
  - The 5 locked decisions above (artifact / toolchain / sodium / protobuf / `ET_HTTP_TLS=OFF`).
  - The three traps (verbatim intent): `PACKAGE BOTH` not `ONLY` (host protoc must resolve);
    append iOS prefixes to `CMAKE_FIND_ROOT_PATH` not just `CMAKE_PREFIX_PATH`; explicit `-Dsodium_*`
    to bypass `find_library`.
  - The explode-and-combine `.a` rule (never `libtool -static a.a b.a`).
  - The verified real paths block from this plan.
  - Pointers to `extern/eternaltermlib/docs/porting-ios.md`, the parent spec, and `build-mosh-xcframework.sh`
    as the template.

- [ ] **Step 2: Commit**

```bash
git add docs/et-ios-build-notes.md
git commit -m "docs(et): iOS build notes — locked decisions, traps, verified paths"
```

---

## Task 2: `build-etios-xcframework.sh` — the cross-build script (macOS-CI-only)

> **Not Linux-runnable** (needs xcodebuild, xcrun, lipo, an iOS SDK). macOS CI is the gate.

**Files:** Create `scripts/build-etios-xcframework.sh`.

**Interfaces / behavior:**
- `set -euo pipefail`, passes shellcheck, colorized progress echoes (per CLAUDE.md CLI conventions).
- Reuses `build-mosh-xcframework.sh`'s host-protoc + cross-protobuf output if present (or invokes that
  script's protobuf functions / a shared helper); else builds host protoc + cross libprotobuf-lite the same
  way. **Decision point for the implementer:** factor the protobuf build into a sourced helper vs. duplicate
  ~40 lines. Prefer sourcing a shared snippet to avoid drift; if that's messy, duplicate with a comment
  pointing at the Mosh script as the source of truth.
- Per iOS slice (`ios-arm64` device, `ios-arm64-sim`, `ios-x86_64-sim`):
  1. `cmake -B build-<slice> -G Xcode -DCMAKE_TOOLCHAIN_FILE=<leetal>/ios.toolchain.cmake
     -DPLATFORM=<OS64|SIMULATORARM64|SIMULATOR64> -DET_HTTP_TLS=OFF`
     plus the explicit dep vars:
     `-Dsodium_LIBRARY_RELEASE=<slice>/libsodium.a -Dsodium_INCLUDE_DIR=<slice>/Headers/Clibsodium
      -Dsodium_USE_STATIC_LIBS=ON -DSODIUM_LIB=<slice>/libsodium.a`
     and protobuf: `-DProtobuf_PROTOC_EXECUTABLE=<host protoc> -DCMAKE_PREFIX_PATH=<ios-protobuf-prefix>`
     with the iOS prefixes ALSO appended to `-DCMAKE_FIND_ROOT_PATH` (trap #2).
     (Leetal sets `CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH` itself; verify — if a version regresses to
     `ONLY`, pass `-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH` explicitly.)
  2. `cmake --build build-<slice> --config Release` → yields `libet_base.a` + `libeternaltermlib.a`.
  3. Explode `libet_base.a`, `libeternaltermlib.a`, and the slice's `libprotobuf-lite.a` to objects;
     `libtool -static -o libETerminal-<slice>.a <all objects>` (combine object list, NOT archives — Mosh
     lines 318-369). Assert the combined `.a` contains ET symbols (`nm | grep et_connect`) as a
     dropped-member guard.
- `lipo -create` the two simulator `.a`s into one fat sim archive (device + sim NEVER lipo'd together).
- `xcodebuild -create-xcframework -library <device>.a -headers include/ -library <fat-sim>.a -headers include/
   -output ETerminal.xcframework`. `include/` = `extern/eternaltermlib/include` (the C ABI header).
- Idempotent per-slice caching (`test -f … && [cached]`), mirroring the Mosh script.

- [ ] **Step 1: Fetch/vendor the leetal/ios-cmake toolchain**

Decide: submodule (`extern/ios-cmake`, pinned) vs. CI-time `git clone --depth 1` of a pinned tag. **Recommend
a submodule** for reproducibility + offline builds (consistent with mosh/ET/sodium already being submodules).
Add it: `git submodule add https://github.com/leetal/ios-cmake extern/ios-cmake` and pin a release tag.

- [ ] **Step 2: Write the script** per the behavior above. SPDX `GPL-3.0-only` header.

- [ ] **Step 3: Static-check locally** (no build): `shellcheck scripts/build-etios-xcframework.sh` and
  `bash -n`. (The actual build only runs on macOS CI — do NOT attempt to run it on the Linux host.)

- [ ] **Step 4: Commit**

```bash
git add scripts/build-etios-xcframework.sh extern/ios-cmake .gitmodules
git commit -m "build(et): build-etios-xcframework.sh — cross-build eternaltermlib to ETerminal.xcframework"
```

---

## Task 3: Wire `ETerminal.xcframework` into `Package.swift` (macOS-CI-only)

**Files:** Modify `Package.swift`.

**Interfaces:** mirror the `Mosh` binaryTarget exactly (lines 23-32).

- [ ] **Step 1: Add the binaryTarget + dependency**

Inside the `#if os(macOS)` block, add alongside `Mosh`:
```swift
    .binaryTarget(name: "ETerminal", path: "ETerminal.xcframework"),
```
and add `"ETerminal"` to the `dependencies:` of the FFI target that already lists `"Mosh"`
(`SemicolynSSHCoreFFI` per line 25). **Nothing imports it yet** — this only makes it link. The Linux
`swift test` job is untouched (the whole block is `#if os(macOS)`).

- [ ] **Step 2: Verify** (macOS CI, via Task 4) — the package must still resolve on Linux (`swift build`
  ignores the macOS-only target). A quick Linux sanity: `docker compose run --rm dev swift build` should
  still succeed because the ET target is behind `#if os(macOS)`.

- [ ] **Step 3: Commit**

```bash
git add Package.swift
git commit -m "build(et): link ETerminal.xcframework as a macOS-only binaryTarget (mirrors Mosh)"
```

---

## Task 4: CI — build the xcframework on the macOS job (macOS-CI-only)

**Files:** Modify `.github/workflows/ci.yml`.

**Interfaces:** the existing `macos` job already runs `scripts/build-mosh-xcframework.sh` +
`scripts/build-xcframework.sh` + `xcodegen` before building. Add ET the same way.

- [ ] **Step 1: Add the ET build step** to the `macos` job, BEFORE the app/xcframework consumption:
  - Ensure `submodules: recursive` is set on the checkout (Mosh already needs it — confirm ET + sodium +
    ios-cmake are pulled).
  - `brew install cmake ninja` if not already present (protobuf/protoc handled by the Mosh script; reuse it).
  - Cache the ET build dir + (optional) libsodium slices by a key including the ET submodule sha +
    swift-sodium tag. libsodium is prebuilt so its "cache" is just the committed xcframework — no build to cache;
    the real cache target is the cross-protobuf output + per-slice ET `.a`s.
  - Run `scripts/build-etios-xcframework.sh`.
  - Assert `ETerminal.xcframework/ios-arm64/libETerminal.a` exists and `nm` shows `_et_connect` (fail loud).

- [ ] **Step 2: Push + read the macOS log** (the ONE expensive iteration). Fix in this order if it fails:
  1. Configure-time `find_package(Protobuf)`/`find_package(sodium)` not found → the `PACKAGE BOTH` /
     `CMAKE_FIND_ROOT_PATH` traps → apply the explicit `-D` vars.
  2. Link-time missing sodium/protobuf symbols → wrong slice `.a` path or protobuf-lite vs. full mismatch.
  3. `create-xcframework` "libraries with the same platform" → device + sim were lipo'd together (must not be).
  4. Empty/dropped ET symbols in the combined `.a` → used `libtool -static a.a b.a` instead of exploding to objects.

- [ ] **Step 3: Commit + iterate** (batch fixes; do not push one-liner guesses).

```bash
git add .github/workflows/ci.yml
git commit -m "ci(et): build ETerminal.xcframework on the macOS job"
```

---

## Task 5: PR + green macOS CI

**Files:** none.

- [ ] **Step 1:** `git push github feat/et-ios-build` + open a PR (findings-style body: what it vendors, that
  it's build-only, downstream = libetios wrapper/picker).
- [ ] **Step 2:** Gate on the `macos` job green (the only signal). The 3 fast jobs
  (`lint`/`linux-rust`/`linux-swift`) must stay green too — proving the `#if os(macOS)` block kept ET off the
  Linux surface.
- [ ] **Step 3:** Do NOT merge without user approval. On green, this leaves an iOS-buildable ET ready for the
  Swift `libetios` wrapper (next plan).

---

## Self-Review

**Scope coverage:**
- vendor ET + sodium + toolchain → Task 0 + Task 2 Step 1. ✓
- capture findings durably → Task 1. ✓
- cross-build per iOS slice with `ET_HTTP_TLS=OFF`, explicit sodium, reused protobuf, leetal toolchain → Task 2. ✓
- combine `.a`s correctly (explode-to-objects, not archive-merge) → Task 2 Step 2 + Task 4 guard. ✓
- package as xcframework + link like Mosh → Task 2 + Task 3. ✓
- build on CI, keep Linux surface clean → Task 4 + Task 5 Step 2. ✓

**Explicitly out of scope (named so nobody half-builds them here):** Swift `libetios` wrapper, SSH bootstrap
(ET credential planting), `TmuxRuntime` drop-in, Transport picker. All downstream of a green xcframework.

**Trap coverage (from the porting docs):** OpenSSL drop (`ET_HTTP_TLS=OFF`, every task) ✓ · `PACKAGE BOTH`
(Task 4 Step 2.1) ✓ · `CMAKE_FIND_ROOT_PATH` for sodium/protobuf (Task 2 Step 1 behavior) ✓ · explode-and-combine
`.a` (Task 2 Step 2, Task 4 guard) ✓ · libsodium prebuilt-not-self-built (locked decision + Task 0) ✓.

**Placeholder scan:** the two genuine implementer decision-points (protobuf helper: source-vs-duplicate;
toolchain: submodule-vs-clone) carry a stated recommendation + fallback — not vague TODOs. The remaining
"verify on macOS CI" notes are real "the only gate is CI" seams, not hand-waving.
