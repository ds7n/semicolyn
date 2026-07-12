<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# ET (Eternal Terminal) transport — resume doc

**Written:** 2026-07-12. **Purpose:** a single place to resume the ET track cleanly, so a
fresh session doesn't re-research settled things or trip over stale memory.

> **Why ET matters here:** ET is the user's **primary/targeted connection mode** (over raw SSH
> or Mosh). It is the *only* transport that gives **native `tmux -CC` panes AND network roaming
> together** — Mosh structurally can't run `-CC` (it syncs a screen, not a byte stream); SSH has
> panes but drops on roam. So ET is prioritized ahead of the other transport tracks.

## The three transport tracks (roadmap context)

The roadmap exists because no single transport delivers panes + roaming today. Attack order was
originally "one at a time, T1 → T2 → T3", but **ET (T3) is now prioritized first** (below).

| Track | What | Status |
|---|---|---|
| **T1 (DEBUG)** | Fix SSH `tmux -CC` blank panes | not started |
| **T2 (SPEC+BUILD)** | Per-host "Startup command" field (prefilled `tmux -CC …`) | not started |
| **T3 (ET)** | ET transport mode — panes + roaming together | **library DONE; semicolyn side spec'd** |

## Current state (what's DONE vs. what's LEFT)

### DONE
- **`eternaltermlib`** — the portable C ET-transport library — is **built, tested,
  security-reviewed, CI-green, and pushed** to `ds7n/eternaltermlib` (Apache-2.0). ~679 LOC C++
  over vendored ET `src/base/` (submodule `dfc75d6`), behind a stable callback C ABI
  (`include/eternaltermlib.h`): `et_connect(&et_config,…)` / `et_send` / `et_set_window_size` /
  `et_close` + `on_bytes`/`on_state`/`on_end`. Unit + integration + roaming/replay tests vs a
  real `etserver` Docker fixture, under TSan/ASan. **This is no longer a gap** (earlier memory
  said "write its spec" — that work already happened).
- **Both semicolyn-side design docs exist and are current:**
  - **Spec:** `docs/superpowers/specs/2026-07-10-et-transport-design.md` (this branch,
    `docs/et-transport-spec`, UNMERGED). Component 1 synced to the shipped ABI; §5 updated for
    the no-Auto decision.
  - **Build plan:** `docs/superpowers/plans/2026-07-12-et-ios-xcframework-build.md` (branch
    `feat/et-ios-build`, commit `b263ca4`, 295 lines, build-only scope).

### LEFT (the actual ET work, in order)
1. **Build `ETerminal.xcframework`** (branch `feat/et-ios-build`, plan `b263ca4`). Tasks 0–4:
   Task 0 (vendor `eternaltermlib` + `swift-sodium` submodules) **DONE**; remaining = vendor the
   `leetal/ios-cmake` toolchain submodule → write `scripts/build-etios-xcframework.sh` → add the
   `ETerminal` `#if os(macOS)` binaryTarget to `Package.swift` (mirror `Mosh`) → extend the
   macOS CI job. **macOS-CI-only** (no local Mac; expect blind ~20-min CI iterations).
2. **`libetios` wrapper + Transport picker** (per the spec §2–§5). Needs the xcframework to
   exist first. Run `writing-plans` → implement.

## Locked decisions (do NOT re-litigate)

**Build framework — use maintained/standard builds, do NOT hand-roll** (the earlier hand-rolled
cross-compile attempt was "miserable"; the plan explicitly pivots away from it):
- **CMake iOS toolchain:** `leetal/ios-cmake` (widely-used, vendored submodule, pinned). Not
  hand-rolled.
- **libsodium:** consume the **prebuilt `Clibsodium.xcframework`** from `jedisct1/swift-sodium`
  (author-maintained). **NO self-build.** Feed ET's CMake explicit `-Dsodium_*` paths pointing
  at `Headers/Clibsodium` (where `sodium.h` lives), not `find_library` discovery.
- **protobuf-lite:** **reuse semicolyn's existing Mosh iOS protobuf cross-build**
  (`scripts/build-mosh-xcframework.sh` already produces host `protoc` + cross `libprotobuf-lite.a`
  @ 3.21.12). Do not build protobuf twice. (One open implementer choice: source a shared helper
  vs. duplicate ~40 lines — plan recommends sourcing.)
- **OpenSSL/zlib:** **eliminated** via `-DET_HTTP_TLS=OFF` (the one painful-to-cross-compile
  dep; the transport never calls cpp-httplib). Verified on Linux: builds/links with zero OpenSSL
  symbols, transport still works.
- **Artifact:** own `ETerminal.xcframework` (mirror `Mosh.xcframework`), built once + cached,
  kept off the Linux `swift test` job. Not compile-as-source.
- **`CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH`** (leetal sets this; verify) so host `protoc`
  resolves while target link libs come from the SDK/prefix; append iOS prefixes to
  `CMAKE_FIND_ROOT_PATH`, not just `CMAKE_PREFIX_PATH`.

**Transport selection — NO Auto mode (2026-07-12):**
- Per-host **Transport** is an **explicit, exclusive** choice: **SSH / Mosh / ET** (default
  **SSH**). First-class feature, not an afterthought.
- Dropping Auto removes the precedence-definition work AND ET's only dependency on Track 2.
- **Fallback ≠ Auto:** an explicit "ET" that can't connect still falls back to SSH + a banner
  (spec §4). Only up-front guessing is removed.
- **UI must show inline pros/cons per transport:** SSH = works everywhere + panes, no roaming;
  Mosh = roaming, no panes, needs UDP; ET = panes + roaming, needs `etserver` + TCP 2022.

**Architecture (unchanged, still sound):**
- Two-tier split: portable `eternaltermlib` (own repo) + thin `libetios` wrapper (in semicolyn,
  like `extern/mosh`). Mirrors semicolyn's ssh-core-vs-UniFFI-bridge philosophy.
- **Bootstrap via russh** (replaces ET's system-`ssh` shell-out): generate `id`(16)+`passkey`(32)
  client-side, run `echo '<id>/<passkey>_<TERM>' | etterminal …` over the existing russh session,
  then `et_connect` to TCP 2022. `eternaltermlib` takes the already-planted credential.
- ET's byte stream feeds the **existing** `ControlModeParser` / `TmuxRuntime` /
  `TmuxPaneContainer` unchanged — ET only replaces the transport.

## Wrapper (`libetios`) requirements the shipped ABI imposes (don't miss these)

- **Callbacks fire on the library's transport thread** → hop to the app's session queue/main
  actor before touching UI/Swift state; **copy the `on_bytes` buffer inside the callback** (valid
  only for that call).
- **Serialization contract:** `et_send` / `et_set_window_size` must NOT race `et_close` on the
  same handle → `ETSession` owns a **single serial point** (serial `DispatchQueue` or actor) for
  all three; tear down only after in-flight sends drain. `et_close` is idempotent for repeated
  *sequential* calls, not a live race.
- **`et_config` carries `TERM` (env map) + initial `cols/rows/width/height` + `keepalive_secs`**
  — set these when building the config, not only in the bootstrap string.
- **`on_end(reason)` is UNTRUSTED remote text** — sanitize before logging or rendering in a
  banner (no verbatim to structured logs, no markup).
- Failure model: `et_connect` returns NULL only on *synchronous* arg failure; async failures
  (bad passkey, connect/handshake) arrive via `on_end`. `et_send`/`et_set_window_size` return a
  negative `et_err` (`ET_ERR_CLOSED` / `ET_ERR_INVALID`).

## Still-open (implementation-phase, not blockers)

- protobuf build: shared helper vs. duplicate (plan recommends helper).
- xcframework size budget; ET jumphost relevance; roam/reconnect UX (reuse Mosh's banner).
- License gate: run the `license-audit` skill on the **combined iOS binary** before shipping
  (eternaltermlib = Apache-2.0, libsodium = ISC, protobuf = BSD-3, semicolyn = GPL-3.0 — all
  permissive, compatible direction).

## Key references

- Library repo: `ds7n/eternaltermlib` (`../eternaltermlib/`), esp. `include/eternaltermlib.h`,
  `docs/porting-ios.md` (the iOS build findings), `src/session.cpp`.
- Semicolyn spec: `docs/superpowers/specs/2026-07-10-et-transport-design.md` (branch
  `docs/et-transport-spec`).
- Build plan: `docs/superpowers/plans/2026-07-12-et-ios-xcframework-build.md` (branch
  `feat/et-ios-build`).
- Mosh precedent (the pattern ET mirrors): `scripts/build-mosh-xcframework.sh`,
  `App/Mosh/MoshSession.mm`, `Package.swift` (the `Mosh` binaryTarget block).
- Memory: `et-transport-brainstorm`, `et-ios-build-vendored`, `mosh-tmux-et-modes-roadmap`.
