#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 True Positive LLC
# SPDX-License-Identifier: GPL-3.0-only
#
# build-etios-xcframework.sh, cross-compile the vendored eternaltermlib (the
# portable C Eternal Terminal client) into ETerminal.xcframework for iOS
# (arm64 device + arm64/x86_64 simulator).
#
# This is macOS-only build engineering: it drives CMake + Xcode's clang, lipo,
# and xcodebuild. It CANNOT run on Linux. It is verified by the macOS CI job,
# which also wires the resulting ETerminal.xcframework into Package.swift as an
# `#if os(macOS)` binaryTarget (mirroring Mosh.xcframework).
#
# Pipeline (two iOS slices, device + fat simulator):
#   1. Build host protoc ONCE (natively). eternaltermlib's CMake calls
#      find_package(Protobuf) + protobuf_generate_cpp(); protoc must run on the
#      build host, never cross-run.
#   2. Cross-build the protobuf-lite RUNTIME per slice (the .proto use
#      optimize_for=LITE_RUNTIME, so the generated code only needs libprotobuf-lite).
#   3. CMake-configure + build eternaltermlib per slice via the leetal/ios-cmake
#      toolchain with ET_HTTP_TLS=OFF (drops OpenSSL+zlib, the one painful iOS
#      cross-dep), pointing at the prebuilt libsodium slice and the host protoc.
#      Produces libet_base.a + libeternaltermlib.a per slice.
#   4. Explode-and-combine those two + libprotobuf-lite.a into one self-contained
#      per-slice lib. libsodium stays SEPARATE (linked at app-link time). Slices are
#      single-arch: `ar x` refuses a fat archive, so we never explode a multi-arch one.
#   5. lipo the two simulator slices into one fat sim archive; xcodebuild
#      -create-xcframework (device slice + fat sim slice).
#   6. SUCCESS GATE: nm the device slice for the `et_connect` C-ABI symbol.
#
# WHY NOT the Mosh autotools cross-flags: eternaltermlib is CMake and calls
# find_package(Protobuf)/find_library(sodium), which the Mosh autotools path
# never handled. We use a mature CMake iOS toolchain (leetal) instead, see
# docs/et-ios-build-notes.md and extern/eternaltermlib/docs/porting-ios.md.

set -euo pipefail

# --------------------------------------------------------------------------- #
# Pinned dependency versions.                                                  #
# --------------------------------------------------------------------------- #
# Reuse the exact protobuf the Mosh build already pins (3.21.12: last "classic"
# C++ protobuf before the Abseil dependency; self-contained, fast, no upb).
PROTOBUF_VERSION="3.21.12"       # https://github.com/protocolbuffers/protobuf/releases

# Minimum iOS deployment target (matches build-xcframework.sh / project.yml / Mosh).
IOS_MIN="17.0"

# --------------------------------------------------------------------------- #
# Paths.                                                                       #
# --------------------------------------------------------------------------- #
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ET_SRC="$REPO_ROOT/extern/eternaltermlib"                       # vendored ET C lib (read-only)
SODIUM_XCFW="$REPO_ROOT/extern/swift-sodium/Clibsodium.xcframework"
TOOLCHAIN="$REPO_ROOT/extern/ios-cmake/ios.toolchain.cmake"     # leetal/ios-cmake (pinned 4.5.0)
BUILD_ROOT="$REPO_ROOT/target/et-xcframework"
DL_DIR="$BUILD_ROOT/downloads"                                  # dependency source tarballs
HOST_DIR="$BUILD_ROOT/host"                                     # native protoc for the build host
OUT="$REPO_ROOT/ETerminal.xcframework"                          # final artifact (repo root, like Mosh)

ET_INCLUDE="$ET_SRC/include"                                    # the C ABI header (entire public surface)
LIB_NAME="libETerminal.a"                                       # combined per-slice static lib
GATE_SYMBOL="et_connect"                                        # success-gate symbol (extern "C")

# --------------------------------------------------------------------------- #
# Slice table. Each entry: NAME|PLATFORM|ARCHS|SODIUM_SLICE                    #
#   NAME          logical slice id (build subdir + per-slice library)          #
#   PLATFORM      leetal/ios-cmake 4.5.0 PLATFORM value                        #
#   ARCHS         leetal ARCHS, a SINGLE arch per slice (see why below)       #
#   SODIUM_SLICE  the prebuilt Clibsodium.xcframework slice dir for this target #
# THREE THIN slices, NOT a fat sim in one shot. The explode-and-combine step    #
# runs `ar x` per source archive, and `ar x` REFUSES a fat (multi-arch) archive #
# ("is a fat file ... Inappropriate file type or format"). So each slice must   #
# be single-arch; the two simulator slices are lipo'd into one fat sim archive  #
# AFTER they are each combined. Device and simulator are NEVER lipo'd together. #
# (The prebuilt libsodium slice IS fat, but it is linked separately, never      #
# exploded, so its fatness is fine.)                                            #
# --------------------------------------------------------------------------- #
SLICES=(
  "ios-arm64|OS|arm64|ios-arm64_arm64e"
  "ios-arm64-sim|SIMULATOR|arm64|ios-arm64_arm64e_x86_64-simulator"
  "ios-x86_64-sim|SIMULATOR|x86_64|ios-arm64_arm64e_x86_64-simulator"
)

# --------------------------------------------------------------------------- #
# Small utilities.                                                            #
# --------------------------------------------------------------------------- #

# fetch <url> <dest-tarball>, download a source tarball once (idempotent).
fetch() {
  local url="$1" dest="$2"
  if [[ -f "$dest" ]]; then
    echo "  [cached] $(basename "$dest")"
    return
  fi
  echo "  [fetch]  $url"
  curl -fsSL "$url" -o "$dest"
}

# --------------------------------------------------------------------------- #
# Host protoc: build the protobuf compiler natively so protobuf_generate_cpp   #
# can run it during the ET cross-compile. protoc must NOT be cross-compiled.    #
# (Mirrors build-mosh-xcframework.sh:build_host_protoc, same version + shape,  #
# kept as a small local copy so this script is self-contained; the Mosh script  #
# remains the source of truth for the pattern.)                                 #
# --------------------------------------------------------------------------- #
build_host_protoc() {
  echo "==> Building host protoc (protobuf $PROTOBUF_VERSION)"
  if [[ -x "$HOST_DIR/bin/protoc" ]]; then
    echo "  [cached] host protoc"
    return
  fi
  local tarball="$DL_DIR/protobuf-${PROTOBUF_VERSION}.tar.gz"
  fetch "https://github.com/protocolbuffers/protobuf/archive/refs/tags/v${PROTOBUF_VERSION}.tar.gz" "$tarball"
  local src="$BUILD_ROOT/src/protobuf-host"
  rm -rf "$src"; mkdir -p "$src"
  tar -xzf "$tarball" -C "$src" --strip-components=1

  cmake -S "$src" -B "$src/build-host" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$HOST_DIR" \
    -Dprotobuf_BUILD_TESTS=OFF \
    -Dprotobuf_BUILD_PROTOC_BINARIES=ON
  cmake --build "$src/build-host" --parallel
  cmake --install "$src/build-host"
  test -x "$HOST_DIR/bin/protoc" || { echo "FATAL: host protoc not built"; exit 1; }
}

# --------------------------------------------------------------------------- #
# build_protobuf_target <prefix> <platform> <archs>, cross-build              #
# libprotobuf-lite (runtime) for one iOS slice via the leetal toolchain.        #
# protoc is NOT built here (we use the host protoc). The .proto are LITE_RUNTIME #
# so libprotobuf-lite.a is what the generated code links.                        #
# --------------------------------------------------------------------------- #
build_protobuf_target() {
  local prefix="$1" platform="$2" archs="$3"
  echo "  --> protobuf-lite (runtime) $PROTOBUF_VERSION [$platform $archs]"
  if [[ -f "$prefix/lib/libprotobuf-lite.a" ]]; then echo "     [cached]"; return; fi
  local tarball="$DL_DIR/protobuf-${PROTOBUF_VERSION}.tar.gz"
  fetch "https://github.com/protocolbuffers/protobuf/archive/refs/tags/v${PROTOBUF_VERSION}.tar.gz" "$tarball"
  local src="$prefix/src/protobuf"
  rm -rf "$src"; mkdir -p "$src"
  tar -xzf "$tarball" -C "$src" --strip-components=1

  # Cross-build libprotobuf(+lite) ONLY via the SAME leetal toolchain used for
  # ET, so the ABI/arch/deployment-target match exactly. protoc binaries OFF
  # (we never run a cross protoc); hand it the host protoc for any self-codegen.
  cmake -S "$src" -B "$src/build" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DPLATFORM="$platform" \
    -DARCHS="$archs" \
    -DDEPLOYMENT_TARGET="$IOS_MIN" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -Dprotobuf_BUILD_TESTS=OFF \
    -Dprotobuf_BUILD_PROTOC_BINARIES=OFF \
    -Dprotobuf_BUILD_SHARED_LIBS=OFF \
    -Dprotobuf_PROTOC_EXE="$HOST_DIR/bin/protoc"
  cmake --build "$src/build" --config Release --parallel
  cmake --install "$src/build" --config Release
  test -f "$prefix/lib/libprotobuf-lite.a" || { echo "FATAL: protobuf libprotobuf-lite.a missing for $platform"; exit 1; }
}

# --------------------------------------------------------------------------- #
# Cross-compile eternaltermlib for a single slice. Produces the combined       #
#   $BUILD_ROOT/<name>/$LIB_NAME                                               #
# (libet_base.a + libeternaltermlib.a + libprotobuf-lite.a, exploded+merged).  #
# --------------------------------------------------------------------------- #
build_slice() {
  local name="$1" platform="$2" archs="$3" sodium_slice="$4"

  echo "==> Slice: $name  (platform=$platform archs=$archs)"
  local workdir="$BUILD_ROOT/$name"
  local prefix="$workdir/deps"                 # per-slice dependency install prefix
  mkdir -p "$prefix/lib"

  # 1. protobuf-lite runtime for this slice.
  build_protobuf_target "$prefix" "$platform" "$archs"

  # 2. The prebuilt libsodium slice (NO self-build). find_library(SODIUM_LIB sodium)
  #    is what ET's top-level CMake uses, so we pre-seed the SODIUM_LIB cache var
  #    with the exact archive and add sodium's header dir to the compile flags.
  #    (The plan's -Dsodium_LIBRARY_RELEASE/-Dsodium_USE_STATIC_LIBS flags target
  #    find_package(sodium), which the top-level lib does NOT use, corrected here.)
  local sodium_lib="$SODIUM_XCFW/$sodium_slice/libsodium.a"
  local sodium_inc="$SODIUM_XCFW/$sodium_slice/Headers/Clibsodium"
  test -f "$sodium_lib" || { echo "FATAL: sodium slice missing: $sodium_lib"; exit 1; }
  test -f "$sodium_inc/sodium.h" || { echo "FATAL: sodium.h missing at $sodium_inc"; exit 1; }

  # 3. CMake-configure + build eternaltermlib (static libs only). ET_BUILD_TESTS=OFF
  #    skips the test subdir AT CONFIGURE time, otherwise its FetchContent(googletest)
  #    would clone + configure gtest under the iOS cross toolchain (wasteful, can fail).
  #    We build only the eternaltermlib target, which pulls et_base transitively.
  local cmbuild="$workdir/build"
  rm -rf "$cmbuild"
  cmake -S "$ET_SRC" -B "$cmbuild" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DPLATFORM="$platform" \
    -DARCHS="$archs" \
    -DDEPLOYMENT_TARGET="$IOS_MIN" \
    -DENABLE_BITCODE=OFF \
    -DCMAKE_BUILD_TYPE=Release \
    -DET_HTTP_TLS=OFF \
    -DET_BUILD_TESTS=OFF \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
    -DCMAKE_FIND_ROOT_PATH="$prefix" \
    -DCMAKE_PREFIX_PATH="$prefix" \
    -DProtobuf_PROTOC_EXECUTABLE="$HOST_DIR/bin/protoc" \
    -DSODIUM_LIB="$sodium_lib" \
    -DCMAKE_C_FLAGS="-I$sodium_inc" \
    -DCMAKE_CXX_FLAGS="-I$sodium_inc"
  # Build only the eternaltermlib target (+ its et_base dependency); do NOT build
  # the test subdir (needs gtest fetch + a runnable target, irrelevant for iOS).
  cmake --build "$cmbuild" --config Release --target eternaltermlib --parallel

  # Locate the two produced archives (Xcode generator nests them under Release/;
  # the Makefiles/Ninja generators do not, search to be generator-agnostic).
  local base_a shim_a
  base_a="$(find "$cmbuild" -name 'libet_base.a' | head -n1)"
  shim_a="$(find "$cmbuild" -name 'libeternaltermlib.a' | head -n1)"
  test -f "$base_a"  || { echo "FATAL: $name did not produce libet_base.a"; exit 1; }
  test -f "$shim_a"  || { echo "FATAL: $name did not produce libeternaltermlib.a"; exit 1; }

  # 4. Explode-and-combine the three archives into ONE self-contained slice lib.
  #    NEVER `libtool -static a.a b.a …`: Apple libtool de-dups members ACROSS
  #    input archives by bare basename, silently dropping whole object files on a
  #    collision (the bug that ate locale_utils.o in the Mosh gate). Explode each
  #    archive into its OWN numbered scratch dir and re-archive the OBJECTS, no
  #    cross-archive basename dedup, nothing dropped. libsodium is NOT merged in
  #    (its own xcframework slice links at app-link time).
  local -a src_archives=(
    "$shim_a"
    "$base_a"
    "$prefix/lib/libprotobuf-lite.a"
  )
  local a
  for a in "${src_archives[@]}"; do
    test -f "$a" || { echo "FATAL: $name missing archive to merge: $a"; exit 1; }
  done

  local objdir="$workdir/merge-objs"
  rm -rf "$objdir"; mkdir -p "$objdir"
  local ar_tool; ar_tool="$(xcrun --find ar)"
  local -a all_objs=()
  local idx=0
  for a in "${src_archives[@]}"; do
    local sub="$objdir/$idx"
    mkdir -p "$sub"
    ( cd "$sub" && "$ar_tool" x "$a" )   # `ar x` writes to CWD; subshell keeps ours put
    local o dest
    while IFS= read -r -d '' o; do
      dest="$objdir/$(printf '%02d' "$idx")-$(basename "$o")"
      mv "$o" "$dest"
      all_objs+=("$dest")
    done < <(find "$sub" -maxdepth 1 -name '*.o' -print0)
    idx=$((idx + 1))
  done
  test "${#all_objs[@]}" -gt 0 || { echo "FATAL: $name extracted no objects to merge"; exit 1; }

  rm -f "$workdir/$LIB_NAME"
  echo "    re-archiving ${#all_objs[@]} objects from ${#src_archives[@]} archives"
  libtool -static -o "$workdir/$LIB_NAME" "${all_objs[@]}"

  # Guard: the combined slice must export the et_connect C-ABI symbol (proves
  # the shim objects were merged). Capture nm into a var and grep WITHOUT -q, on
  # a large archive `nm | grep -q` closes the pipe on first match → SIGPIPE →
  # false-fail under `set -o pipefail` (the exact bug that hit the Mosh M1 gate).
  local slice_nm gate_def
  slice_nm="$(nm "$workdir/$LIB_NAME" 2>/dev/null || true)"
  gate_def="$(printf '%s\n' "$slice_nm" | grep -E "[[:space:]]T[[:space:]]+_?${GATE_SYMBOL}$" || true)"
  if [[ -z "$gate_def" ]]; then
    echo "FATAL: $name $LIB_NAME is missing the ${GATE_SYMBOL} DEFINITION (T)," \
         "the object merge dropped the shim objects." >&2
    printf '%s\n' "$slice_nm" | grep -Ei "et_connect|et_send|et_close" | head -20 >&2 \
      || echo "  (no et_* symbols AT ALL, the shim archive was not merged)" >&2
    exit 1
  fi
  rm -rf "$objdir"
  echo "    built self-contained $workdir/$LIB_NAME (${#src_archives[@]} archives, ${#all_objs[@]} objects)"
}

# --------------------------------------------------------------------------- #
# Main.                                                                        #
# --------------------------------------------------------------------------- #
main() {
  test -d "$ET_SRC" || { echo "FATAL: vendored eternaltermlib missing at $ET_SRC"; exit 1; }
  test -f "$ET_INCLUDE/eternaltermlib.h" || { echo "FATAL: C ABI header missing at $ET_INCLUDE"; exit 1; }
  test -f "$TOOLCHAIN" || { echo "FATAL: leetal toolchain missing at $TOOLCHAIN (submodule not init'd?)"; exit 1; }
  test -d "$SODIUM_XCFW" || { echo "FATAL: Clibsodium.xcframework missing at $SODIUM_XCFW (submodule not init'd?)"; exit 1; }

  command -v cmake >/dev/null 2>&1 || { echo "FATAL: cmake not found (brew install cmake)"; exit 1; }

  # Clean output for a reproducible run; keep the downloads cache.
  rm -rf "$OUT"
  mkdir -p "$DL_DIR"

  # Host codegen compiler (built once, arch-independent).
  build_host_protoc

  # Build every slice.
  local entry
  for entry in "${SLICES[@]}"; do
    IFS='|' read -r name platform archs sodium_slice <<< "$entry"
    build_slice "$name" "$platform" "$archs" "$sodium_slice"
  done

  # lipo the two thin simulator combos (arm64-sim + x86_64-sim) into ONE fat sim
  # archive. An xcframework static-lib slice is one arch per platform-variant:
  #   device = arm64 single; simulator = arm64+x86_64 fat.
  # Device and simulator are NEVER lipo'd together. (Each sim combo is already the
  # exploded+merged ET lib for its single arch, so lipo just fuses the two.)
  local sim_fat="$BUILD_ROOT/ios-sim-fat/$LIB_NAME"
  mkdir -p "$(dirname "$sim_fat")"
  lipo -create \
    "$BUILD_ROOT/ios-arm64-sim/$LIB_NAME" \
    "$BUILD_ROOT/ios-x86_64-sim/$LIB_NAME" \
    -output "$sim_fat"

  # Headers dir for the xcframework (the single public C ABI header).
  local hdrs="$BUILD_ROOT/Headers"
  rm -rf "$hdrs"; mkdir -p "$hdrs"
  cp "$ET_INCLUDE/eternaltermlib.h" "$hdrs/"

  # Assemble: device slice + fat simulator slice.
  xcodebuild -create-xcframework \
    -library "$BUILD_ROOT/ios-arm64/$LIB_NAME" -headers "$hdrs" \
    -library "$sim_fat"                        -headers "$hdrs" \
    -output "$OUT"

  # ----------------------------------------------------------------------- #
  # SUCCESS GATE: the built device slice must export the `et_connect` C-ABI  #
  # symbol. Proves the iOS cross-build produced a usable transport library.  #
  # ----------------------------------------------------------------------- #
  # The device-only slice dir is `ios-arm64`; the simulator dir contains
  # "simulator", exclude it so we nm the real device slice.
  local device_lib
  device_lib="$(find "$OUT" -name "$LIB_NAME" -path '*ios-arm64*' -not -path '*simulator*' | head -n1)"
  test -n "$device_lib" || { echo "GATE FAIL: no device $LIB_NAME inside $OUT"; exit 1; }

  echo "==> gate: nm -arch arm64 '$device_lib' | grep ' T _${GATE_SYMBOL}'"
  local nm_out gate_hit
  nm_out="$(nm -arch arm64 "$device_lib" 2>/dev/null || nm "$device_lib" 2>/dev/null || true)"
  # grep into a var (NOT `grep -q` in a pipe), see the SIGPIPE note above.
  gate_hit="$(printf '%s\n' "$nm_out" | grep -E "[[:space:]]T[[:space:]]+_?${GATE_SYMBOL}$" || true)"
  if [[ -n "$gate_hit" ]]; then
    echo "OK: C-ABI symbol '${GATE_SYMBOL}' present in device slice."
    echo "SUCCESS: built $OUT"
  else
    echo "GATE FAIL: C-ABI symbol '${GATE_SYMBOL}' NOT found (as an exported T symbol) in $device_lib" >&2
    printf '%s\n' "$nm_out" | grep -Ei "et_connect|et_send|et_close" | head -30 >&2 || echo "  (none matched et_*)" >&2
    exit 1
  fi
}

main "$@"
