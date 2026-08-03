<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# ET → iOS xcframework build notes

Durable capture of the load-bearing knowledge for cross-compiling `eternaltermlib`
(the vendored ET C client library) into `ETerminal.xcframework` for iOS. Written so a
fresh session can act without re-deriving the painful bits.

**Source docs** (the load-bearing knowledge this consolidates):
- `extern/eternaltermlib/docs/porting-ios.md` — the iOS porting findings, verified on Linux.
- The execution plan: `docs/superpowers/plans/2026-07-12-et-ios-xcframework-build.md`.
- The template to mirror: `scripts/build-mosh-xcframework.sh` (host protoc + per-slice cross +
  explode-and-combine + create-xcframework).
- Parent design: `docs/superpowers/specs/2026-07-10-et-transport-design.md` (branch
  `docs/et-transport-spec`).

## Scope

The iOS **compile + package** step ONLY: make `eternaltermlib` build for iOS in semicolyn's
macOS CI and emit `ETerminal.xcframework` (device arm64 + simulator arm64/x86_64), linked as a
`#if os(macOS)` binaryTarget in `Package.swift` like `Mosh.xcframework`. Nothing consumes it
yet — the Swift `libetios` wrapper, SSH bootstrap, `TmuxRuntime` drop-in, and Transport picker
are downstream (separate plans).

## The 5 locked decisions (do NOT re-litigate)

1. **Artifact:** own `ETerminal.xcframework` (mirror `Mosh.xcframework`), not compile-as-source.
   Keeps the C++/protobuf blob off the Linux `swift test` job; build once + cache.
2. **Toolchain:** `leetal/ios-cmake` (vendored submodule `extern/ios-cmake`). ET uses CMake and
   calls `find_package(Protobuf)` + `find_library(sodium)`, which the Mosh autotools cross-flags
   never handled — so a mature CMake iOS toolchain, NOT the hand-rolled cross flags. (The
   hand-rolled attempt was miserable; this is the pivot away from it.)
3. **libsodium:** consume the **prebuilt `Clibsodium.xcframework`** from `jedisct1/swift-sodium`
   (`extern/swift-sodium`, tag 0.11.0, author-maintained). **NO self-build.** Feed ET's CMake
   explicitly (bypass fragile `find_library`):
   `-Dsodium_LIBRARY_RELEASE=<slice>/libsodium.a -Dsodium_INCLUDE_DIR=<slice>/Headers/Clibsodium
   -Dsodium_USE_STATIC_LIBS=ON -DSODIUM_LIB=<slice>/libsodium.a`.
   `sodium_INCLUDE_DIR` MUST point at `Headers/Clibsodium` (where `sodium.h` actually lives),
   NOT `Headers/`.
4. **protobuf-lite:** reuse semicolyn's EXISTING iOS protobuf cross-build.
   `scripts/build-mosh-xcframework.sh` already builds host `protoc` (`build_host_protoc`) + a
   per-slice cross `libprotobuf.a`/`libprotobuf-lite.a` @ 3.21.12 (`build_protobuf_target`). ET's
   `find_package(Protobuf)` needs the host protoc; the target link needs the cross `.a`. Do not
   build protobuf twice.
5. **`ET_HTTP_TLS=OFF`:** always. Drops OpenSSL + zlib (the one painful iOS cross-dep). ET's
   `Headers.hpp` pulls cpp-httplib w/ TLS which drags OpenSSL; the transport never calls it, so
   `ET_HTTP_TLS=OFF` suppresses the whole header (no vendored edit). Verified on Linux: builds +
   links with zero OpenSSL symbols and a working transport (handshake/stream/roam).

## The 3 traps (learned the hard way — from porting-ios.md)

1. **`CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH`, not `ONLY`.** ET calls `find_package(Protobuf)`
   for the **host** protoc + codegen wiring; `ONLY` restricts package search to the iOS SDK and
   configure fails because the host Protobuf is invisible. `BOTH` lets host packages resolve
   while target link libs still come from the SDK/prefix. leetal sets this itself — verify; if a
   version regresses, pass `-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH` explicitly.
2. **Append the iOS libsodium/protobuf prefixes to `CMAKE_FIND_ROOT_PATH`, not just
   `CMAKE_PREFIX_PATH`.** Under the `ONLY` library-search mode, prefixes only in
   `CMAKE_PREFIX_PATH` are invisible to the iOS-SDK-scoped `find_library`.
3. **Explicit `-Dsodium_*` to bypass `find_library` discovery** (decision 3). Discovery is
   fragile across the xcframework's non-standard layout; hand it the exact `.a` + include dir.

## The explode-and-combine `.a` rule (never `libtool -static a.a b.a`)

Apple `libtool -static <a.a> <b.a> …` **de-dups members ACROSS input archives by bare
basename** (keeping the first), so a basename collision silently DROPS whole object files (this
exact bug ate `locale_utils.o` in the Mosh gate). Instead, for each slice:

1. Explode every source archive into its OWN isolated scratch dir (`ar x` in a subshell so CWD
   stays put), renaming extracted objects with a per-archive numeric prefix so identical
   basenames from different archives can't clobber.
2. `libtool -static -o libETerminal-<slice>.a <all the exploded .o files>` — objects carry no
   basename-dedup semantics, so nothing is dropped, and libtool writes a proper Mach-O symbol
   table.
3. **Guard:** assert the combined `.a` exports `_et_connect` via `nm`. Capture `nm` into a var
   and grep WITHOUT `-q` (a `nm | grep -q` on a large archive closes the pipe on first match →
   SIGPIPE → false-fails under `set -o pipefail`; the exact bug that hit the Mosh M1 gate).

ET has **THREE** archives to fold in: `libet_base.a` (vendored ET + protobuf srcs),
`libeternaltermlib.a` (the shim), and the slice's `libprotobuf-lite.a`. **libsodium stays
SEPARATE** — its own xcframework slice is linked at app-link time, not merged (that's how a
prebuilt binary dep is normally consumed).

## Slice / xcframework assembly (mirror Mosh)

- Three build slices: `ios-arm64` (device, leetal `PLATFORM=OS64`), `ios-arm64-sim`
  (`PLATFORM=SIMULATORARM64`), `ios-x86_64-sim` (`PLATFORM=SIMULATOR64`).
- `lipo -create` the two **simulator** `.a`s into one fat sim archive. **Device + simulator are
  NEVER lipo'd together** (an xcframework static-lib slice is one arch per platform-variant:
  device = arm64 single; sim = arm64+x86_64 fat).
- `xcodebuild -create-xcframework -library <device>.a -headers <include> -library <fat-sim>.a
  -headers <include> -output ETerminal.xcframework`, where `<include>` =
  `extern/eternaltermlib/include` (the C ABI header, the entire public surface).

## Verified real paths (2026-07-12)

- ET C ABI header: `extern/eternaltermlib/include/eternaltermlib.h` (134 lines).
- ET CMake targets: `eternaltermlib` (STATIC shim: `src/shim.cpp` + `transport.cpp` +
  `session.cpp`) links `et_base` (STATIC: vendored ET + protobuf srcs).
  `project(eternaltermlib VERSION 0.0.1)`.
- ET sodium consumption: `find_library(SODIUM_LIB sodium REQUIRED)` (`CMakeLists.txt:32`);
  `find_package(sodium REQUIRED)` in the vendored ET (`extern/eternalterminal/CMakeLists.txt:131`).
- libsodium prebuilt slices (swift-sodium 0.11.0):
  - device: `extern/swift-sodium/Clibsodium.xcframework/ios-arm64_arm64e/{libsodium.a,
    Headers/Clibsodium/sodium.h}`
  - sim: `extern/swift-sodium/Clibsodium.xcframework/ios-arm64_arm64e_x86_64-simulator/{libsodium.a,
    Headers/Clibsodium/sodium.h}`
- Mosh precedent: `scripts/build-mosh-xcframework.sh` — `build_host_protoc` (native protoc once),
  `build_protobuf_target <prefix>` (per-slice cross libprotobuf), the explode-and-combine block
  (the `merge-objs` loop + `libtool -static` + the SIGPIPE-safe `nm` guard), the sim `lipo`, and
  the `xcodebuild -create-xcframework` tail.
- `Package.swift`: the `Mosh` binaryTarget is at line 32 (`.binaryTarget(name: "Mosh", path:
  "Mosh.xcframework")`), inside the `#if os(macOS)` block; `SemicolynSSHCoreFFI` (line 25) lists
  `"Mosh"` in its deps.

## Two implementer decision-points (with recommendations)

- **protobuf build: source a shared helper vs. duplicate ~40 lines.** Prefer sourcing the Mosh
  script's protobuf functions (or a shared snippet) to avoid version drift; if sourcing is messy
  (the Mosh script has autotools/ncurses concerns ET doesn't share), duplicate the protobuf-only
  functions with a comment pointing at the Mosh script as the source of truth.
- **leetal toolchain: submodule vs. CI-time clone.** Recommend a **submodule**
  (`extern/ios-cmake`, pinned tag) for reproducibility + offline builds, consistent with mosh/ET/
  sodium already being submodules.

## Licensing

libsodium = ISC, protobuf = BSD-3, ET + eternaltermlib = Apache-2.0 — all permissive, compatible
with semicolyn (GPL-3.0-only). Preserve ET's `NOTICE`. A combined-binary **license audit is owed
before distribution** (hygiene, not a CI blocker).
