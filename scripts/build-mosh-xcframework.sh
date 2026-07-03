#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 True Positive LLC
# SPDX-License-Identifier: GPL-3.0-only
#
# build-mosh-xcframework.sh — cross-compile the vendored blinksh/mosh C++ into
# Mosh.xcframework for iOS (arm64 device + arm64/x86_64 simulator).
#
# This is macOS-only build engineering: it drives Xcode's clang, autotools,
# lipo, and xcodebuild. It CANNOT run on Linux. It is verified by the macOS CI
# job (Task 7), which also wires the resulting Mosh.xcframework into
# Package.swift as an `#if os(macOS)` binaryTarget.
#
# Pipeline per iOS slice (arm64-device, arm64-sim, x86_64-sim):
#   1. Cross-build Mosh's four REQUIRED native deps as iOS static libs:
#        OpenSSL, Nettle, ncurses (tinfo), protobuf (runtime lib).
#      `protoc` (the codegen compiler) is built ONCE for the build host so it
#      can run natively — we never cross-run protoc.
#   2. autogen + configure + make the Mosh iOS controller library, pointing its
#      pkg-config / CPPFLAGS / LDFLAGS at the per-slice dep prefix. The product
#      is src/frontend/libmoshiosclient.a (which contains `mosh_main`).
# Then:
#   3. lipo the two simulator slices into one fat archive.
#   4. xcodebuild -create-xcframework (device slice + fat sim slice).
#   5. M1 SUCCESS GATE: nm the device slice for the `mosh_main` bridge symbol.
#
# A maintainer bumps a dependency by editing the pinned versions below, or a
# slice by editing the SLICES table. Each dep is built by its own function so a
# CI failure points at exactly one dependency.

set -euo pipefail

# --------------------------------------------------------------------------- #
# Pinned dependency versions (bump here; keep the URLs in the fetch helpers).  #
# --------------------------------------------------------------------------- #
# Crypto = Apple CommonCrypto (iOS SDK header, no cross-build) → no OpenSSL/Nettle.
NCURSES_VERSION="6.5"            # https://ftp.gnu.org/gnu/ncurses/
# protobuf 3.21.x is the last "classic" C++ protobuf BEFORE the Abseil dependency
# (landed in 22.x). Mosh (2016-era) uses the classic generated `.pb.h` API and only
# needs 4 tiny .proto files compiled, so 3.21.12 is self-contained (no Abseil, no
# utf8_range/upb), builds fast, and avoids 27.x's protoc-backend explosion + link
# hang. Its source archive unpacks to protobuf-3.21.12/ with a top-level CMakeLists.
PROTOBUF_VERSION="3.21.12"       # https://github.com/protocolbuffers/protobuf/releases

# Minimum iOS deployment target (matches build-xcframework.sh / project.yml).
IOS_MIN="17.0"

# --------------------------------------------------------------------------- #
# Paths.                                                                       #
# --------------------------------------------------------------------------- #
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MOSH_SRC="$REPO_ROOT/extern/mosh"          # vendored blinksh/mosh (read-only)
BUILD_ROOT="$REPO_ROOT/target/mosh-xcframework"
DL_DIR="$BUILD_ROOT/downloads"             # dependency source tarballs
HOST_DIR="$BUILD_ROOT/host"                # native protoc for the build host
OUT="$REPO_ROOT/Mosh.xcframework"          # final artifact (repo root, like SSHCore)

LIB_NAME="libmoshiosclient.a"              # Mosh iOS controller static lib
BRIDGE_HEADER="$MOSH_SRC/src/frontend/moshiosbridge.h"
BRIDGE_SYMBOL="mosh_main"                  # M1 gate symbol (extern "C")

# --------------------------------------------------------------------------- #
# Slice table. Each entry: NAME|ARCH|SDK|HOST_TRIPLE|MIN_FLAG                  #
#   NAME        logical slice id (build subdir)                               #
#   ARCH        -arch value for clang                                         #
#   SDK         xcrun SDK (iphoneos | iphonesimulator)                        #
#   HOST_TRIPLE autotools --host= value                                       #
#   MIN_FLAG    deployment-target flag (device vs simulator differ)           #
# The two arm64 slices share the aarch64 host triple; the SDK + min-version   #
# flags are what actually distinguish device from simulator.                  #
# --------------------------------------------------------------------------- #
SLICES=(
  "ios-arm64|arm64|iphoneos|aarch64-apple-darwin|-mios-version-min=${IOS_MIN}"
  "ios-arm64-sim|arm64|iphonesimulator|aarch64-apple-darwin|-mios-simulator-version-min=${IOS_MIN}"
  "ios-x86_64-sim|x86_64|iphonesimulator|x86_64-apple-darwin|-mios-simulator-version-min=${IOS_MIN}"
)

# --------------------------------------------------------------------------- #
# Small utilities.                                                            #
# --------------------------------------------------------------------------- #

# fetch <url> <dest-tarball> — download a source tarball once (idempotent).
fetch() {
  local url="$1" dest="$2"
  if [[ -f "$dest" ]]; then
    echo "  [cached] $(basename "$dest")"
    return
  fi
  echo "  [fetch]  $url"
  curl -fsSL "$url" -o "$dest"
}

# extract <tarball> <parent-dir> — untar into parent-dir, echoing the top dir.
extract() {
  local tarball="$1" parent="$2"
  mkdir -p "$parent"
  tar -xzf "$tarball" -C "$parent"
}

# --------------------------------------------------------------------------- #
# Host protoc: build the protobuf compiler natively so we can run it during    #
# the Mosh cross-compile. protoc must NOT be cross-compiled (we'd be unable to #
# execute it); only libprotobuf is cross-built per slice below.                #
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
  rm -rf "$src"
  mkdir -p "$src"
  tar -xzf "$tarball" -C "$src" --strip-components=1

  # Native (host) build of protoc + libprotobuf via CMake. 3.21.x is self-contained
  # (no Abseil), so no ABSL provider / C++ standard override is needed.
  cmake -S "$src" -B "$src/build-host" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$HOST_DIR" \
    -Dprotobuf_BUILD_TESTS=OFF \
    -Dprotobuf_BUILD_PROTOC_BINARIES=ON
  # Build the full default target set (protoc + libprotobuf + libprotobuf-lite),
  # not just --target protoc: `cmake --install` installs ALL targets and errors on
  # a missing libprotobuf-lite.a otherwise. These host libs are small (3.21.x).
  cmake --build "$src/build-host" --parallel
  cmake --install "$src/build-host"
  test -x "$HOST_DIR/bin/protoc" || { echo "FATAL: host protoc not built"; exit 1; }
}

# --------------------------------------------------------------------------- #
# Per-dependency cross builds. Each takes (arch, sdk, host_triple, min_flag,   #
# prefix) and installs an iOS static lib + headers + a .pc file under prefix.  #
# CC/CXX/CFLAGS/CXXFLAGS/LDFLAGS are exported by build_slice before calling.   #
# --------------------------------------------------------------------------- #

# build_ncurses <prefix> — ncurses provides the tinfo library Mosh requires
# (the iOS SDK ships no curses). We build the tinfo half only.
build_ncurses() {
  local prefix="$1"
  echo "  --> ncurses $NCURSES_VERSION"
  if [[ -f "$prefix/lib/libncursesw.a" ]]; then echo "     [cached]"; return; fi
  # Ensure a modern host tic is available for the fallback-terminfo step (macOS's
  # system tic is ncurses 5.7 and errors on ncurses 6.5's terminfo.src). Idempotent.
  if command -v brew >/dev/null 2>&1; then
    brew list ncurses >/dev/null 2>&1 || brew install ncurses || true
  fi
  local tarball="$DL_DIR/ncurses-${NCURSES_VERSION}.tar.gz"
  fetch "https://ftp.gnu.org/gnu/ncurses/ncurses-${NCURSES_VERSION}.tar.gz" "$tarball"
  local src="$prefix/src/ncurses"
  rm -rf "$src"; mkdir -p "$src"
  tar -xzf "$tarball" -C "$src" --strip-components=1

  # The fallback-terminfo step runs the HOST tic/infocmp over ncurses 6.5's
  # terminfo.src. macOS's system /usr/bin/tic is ancient (ncurses 5.7) and errors
  # ("error writing … mintty") on the modern source. Prefer Homebrew's current
  # ncurses tic/infocmp when available so MKfallback.sh succeeds.
  local brew_ncurses; brew_ncurses="$(brew --prefix ncurses 2>/dev/null || true)"
  local tic_path="/usr/bin"
  if [[ -n "$brew_ncurses" && -x "$brew_ncurses/bin/tic" ]]; then
    tic_path="$brew_ncurses/bin"
  fi

  ( cd "$src"
    # ncurses cross-compiles need a native tic/build compiler for the terminfo
    # DB generation; --with-build-cc points at the host clang. The exported CFLAGS/
    # CPPFLAGS carry iOS cross flags (-arch arm64 -isysroot <iOS SDK>), which would
    # poison ncurses' "does the build compiler work?" probe (it can't produce a
    # runnable host binary), yielding "Cross-build requires two compilers". Give the
    # BUILD compiler clean host flags via --with-build-c*flags so the probe passes.
    # Put a modern tic first on PATH for MKfallback.sh.
    # --with-ospeed=int: with the default (short), ncurses sets NCURSES_OSPEED_COMPAT=1,
    # and lib_baudrate.c then does `#include <sys/ttydev.h>` on __APPLE__ — a header the
    # iOS SDK doesn't ship (macOS does), so the cross-build fails "file not found". A
    # non-short ospeed type sets the compat macro to 0 and drops the include entirely.
    local host_sdk; host_sdk="$(xcrun --sdk macosx --show-sdk-path)"
    PATH="$tic_path:$PATH" ./configure \
      --host="${HOST_TRIPLE}" \
      --prefix="$prefix" \
      --with-build-cc="$(xcrun --sdk macosx --find clang)" \
      --with-build-cflags="-isysroot $host_sdk" \
      --with-build-cppflags="-isysroot $host_sdk" \
      --with-build-ldflags="-isysroot $host_sdk" \
      --with-ospeed=int \
      --without-shared --without-debug --without-ada --without-cxx-binding \
      --without-manpages --without-progs --without-tests \
      --enable-termcap --disable-database --with-fallbacks=xterm-256color,vt100,linux
    PATH="$tic_path:$PATH" make -j"$(sysctl -n hw.ncpu)"
    make install
  )
  # ncurses 6.5 builds the wide-char variant: libncursesw.a + ncursesw.pc. Mosh's
  # configure probes pkg-config `tinfo` then `ncurses` (unsuffixed) and links
  # -lncurses/-ltinfo, so alias the lib and .pc names it expects to the w variant.
  test -f "$prefix/lib/libncursesw.a" || { echo "FATAL: ncurses libncursesw.a missing"; exit 1; }
  local libdir="$prefix/lib" pcdir="$prefix/lib/pkgconfig"
  cp -f "$libdir/libncursesw.a" "$libdir/libncurses.a"
  cp -f "$libdir/libncursesw.a" "$libdir/libtinfo.a"
  local base_pc=""
  [[ -f "$pcdir/ncursesw.pc" ]] && base_pc="$pcdir/ncursesw.pc"
  [[ -z "$base_pc" && -f "$pcdir/ncurses.pc" ]] && base_pc="$pcdir/ncurses.pc"
  if [[ -n "$base_pc" ]]; then
    for name in ncurses tinfo; do
      [[ -f "$pcdir/$name.pc" ]] || cp "$base_pc" "$pcdir/$name.pc"
    done
  fi
}

# build_protobuf_target <prefix> — cross-build libprotobuf (runtime) for the
# iOS slice. protoc is NOT built here (we use the host protoc from build_host_protoc).
build_protobuf_target() {
  local prefix="$1"
  echo "  --> protobuf (runtime lib) $PROTOBUF_VERSION"
  if [[ -f "$prefix/lib/libprotobuf.a" ]]; then echo "     [cached]"; return; fi
  local tarball="$DL_DIR/protobuf-${PROTOBUF_VERSION}.tar.gz"
  fetch "https://github.com/protocolbuffers/protobuf/archive/refs/tags/v${PROTOBUF_VERSION}.tar.gz" "$tarball"
  local src="$prefix/src/protobuf"
  rm -rf "$src"; mkdir -p "$src"
  tar -xzf "$tarball" -C "$src" --strip-components=1

  local sysroot; sysroot="$(xcrun --sdk "$SDK" --show-sdk-path)"
  # CMake cross-build of libprotobuf ONLY. protobuf_BUILD_PROTOC_BINARIES=OFF so
  # we don't try to build/run protoc for the target arch. Point at the host
  # protoc via protobuf_PROTOC_EXE for any codegen protobuf itself needs. 3.21.x
  # is self-contained (no Abseil) so no ABSL provider / C++ standard override.
  cmake -S "$src" -B "$src/build-$ARCH-$SDK" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -Dprotobuf_BUILD_TESTS=OFF \
    -Dprotobuf_BUILD_PROTOC_BINARIES=OFF \
    -Dprotobuf_BUILD_SHARED_LIBS=OFF \
    -Dprotobuf_PROTOC_EXE="$HOST_DIR/bin/protoc"
  cmake --build "$src/build-$ARCH-$SDK" --parallel
  cmake --install "$src/build-$ARCH-$SDK"
  test -f "$prefix/lib/libprotobuf.a" || { echo "FATAL: protobuf libprotobuf.a missing"; exit 1; }
}

# --------------------------------------------------------------------------- #
# Cross-compile Mosh for a single slice. Produces                              #
#   $BUILD_ROOT/<name>/libmoshiosclient.a                                      #
# --------------------------------------------------------------------------- #
build_slice() {
  local name="$1" arch="$2" sdk="$3" host_triple="$4" min_flag="$5"

  echo "==> Slice: $name  (arch=$arch sdk=$sdk host=$host_triple)"
  local prefix="$BUILD_ROOT/$name/deps"     # per-slice dependency install prefix
  local workdir="$BUILD_ROOT/$name"
  mkdir -p "$prefix/lib/pkgconfig"

  # Toolchain for this slice.
  local clang clangxx sysroot
  clang="$(xcrun --sdk "$sdk" --find clang)"
  clangxx="$(xcrun --sdk "$sdk" --find clang++)"
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"

  # Export the slice toolchain so the dep build functions inherit it.
  export ARCH="$arch" SDK="$sdk" HOST_TRIPLE="$host_triple" MIN_FLAG="$min_flag"
  export CC="$clang" CXX="$clangxx"
  # No -fembed-bitcode-marker: bitcode is deprecated (App Store dropped it) and
  # Xcode 16 removed the flag, which breaks autotools' link-executable probe.
  export CFLAGS="-arch $arch -isysroot $sysroot $min_flag -O2"
  export CXXFLAGS="$CFLAGS -std=c++17"
  export CPPFLAGS="-arch $arch -isysroot $sysroot $min_flag -I$prefix/include"
  export LDFLAGS="-arch $arch -isysroot $sysroot $min_flag -L$prefix/lib"
  # Force pkg-config to resolve ONLY against our cross prefix (never host libs).
  export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
  export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
  # Host protoc on PATH so Mosh's AC_PATH_PROG([PROTOC]) finds the runnable one.
  export PATH="$HOST_DIR/bin:$PATH"

  # 1. Native deps for this slice. Crypto is Apple CommonCrypto (an iOS SDK
  # header, nothing to cross-build), so only ncurses (tinfo) + protobuf remain.
  build_ncurses "$prefix"
  build_protobuf_target "$prefix"

  # 2. Configure + build the Mosh iOS controller library.
  #    We build in a per-slice copy of the tree so we never mutate extern/mosh
  #    and so each slice gets its own config.h / Makefiles.
  local build_tree="$workdir/mosh"
  rm -rf "$build_tree"
  cp -R "$MOSH_SRC" "$build_tree"
  ( cd "$build_tree"
    ./autogen.sh                              # autoreconf -fi (needs autotools)
    # Deployment-target vars help Xcode clang stamp the right platform on
    # objects even where our explicit -m*-version-min flag is not threaded.
    ./configure \
      --host="$host_triple" \
      --enable-ios-controller \
      --disable-server \
      --disable-client \
      --with-crypto-library=apple-common-crypto \
      --disable-hardening \
      PROTOC="$HOST_DIR/bin/protoc" \
      CC="$CC" CXX="$CXX" \
      CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS" \
      CPPFLAGS="$CPPFLAGS" LDFLAGS="$LDFLAGS"
    # Only the iOS controller lib is needed; build the frontend dir (it depends
    # on the sibling libmosh*.a, which make builds transitively).
    make -j"$(sysctl -n hw.ncpu)"
  )

  local produced="$build_tree/src/frontend/$LIB_NAME"
  test -f "$produced" || { echo "FATAL: $name did not produce $LIB_NAME"; exit 1; }

  # `libmoshiosclient.a` (frontend: moshiosbridge.o + iosclient.o + terminaloverlay.o)
  # is NOT self-contained — it references the sibling Mosh static libs (util defines
  # is_utf8_locale/set_native_locale/freeze_timestamp/LocaleVar::str, plus network/
  # crypto/terminal/statesync/protobuf) exactly as the frontend Makefile.am LDADD lists.
  # A normal Mosh build links those into the final executable; shipping the frontend .a
  # alone leaves those symbols Undefined at the app link step. Apple CommonCrypto is
  # header-only in the SDK (no archive to merge).
  #
  # DO NOT merge with `libtool -static <a.a> <b.a> …`: Apple libtool de-dups members
  # ACROSS input archives by bare basename (keeping the first), so a basename collision
  # with the autotools-built libprotobuf.a / libncurses.a silently drops whole Mosh
  # members — this exact bug ate locale_utils.o's definitions (they stayed `U` in the
  # output). Instead explode every archive into its OWN scratch dir (identical basenames
  # from different archives can't clobber) and re-archive the resulting OBJECT files —
  # objects carry no basename-dedup semantics, so nothing is dropped.
  local -a src_archives=(
    "$produced"
    "$build_tree/src/util/libmoshutil.a"
    "$build_tree/src/network/libmoshnetwork.a"
    "$build_tree/src/crypto/libmoshcrypto.a"
    "$build_tree/src/terminal/libmoshterminal.a"
    "$build_tree/src/statesync/libmoshstatesync.a"
    "$build_tree/src/protobufs/libmoshprotos.a"
    "$prefix/lib/libprotobuf.a"        # protobuf runtime (target slice)
    "$prefix/lib/libncurses.a"         # tinfo/ncurses (aliased from libncursesw.a)
  )
  local a
  for a in "${src_archives[@]}"; do
    test -f "$a" || { echo "FATAL: $name missing archive to merge: $a"; exit 1; }
  done

  # Explode each archive into an isolated numbered dir so same-basename members from
  # different archives (e.g. protobuf/ncurses vs Mosh) never overwrite one another.
  local objdir="$workdir/merge-objs"
  rm -rf "$objdir"; mkdir -p "$objdir"
  local ar_tool; ar_tool="$(xcrun --sdk "$sdk" --find ar)"
  local -a all_objs=()
  local idx=0
  for a in "${src_archives[@]}"; do
    local sub="$objdir/$idx"
    mkdir -p "$sub"
    ( cd "$sub" && "$ar_tool" x "$a" )   # `ar x` writes to CWD; subshell keeps ours put
    local o
    while IFS= read -r -d '' o; do
      local dest="$objdir/$(printf '%02d' "$idx")-$(basename "$o")"
      mv "$o" "$dest"
      all_objs+=("$dest")
    done < <(find "$sub" -maxdepth 1 -name '*.o' -print0)
    idx=$((idx + 1))
  done
  test "${#all_objs[@]}" -gt 0 || { echo "FATAL: $name extracted no objects to merge"; exit 1; }

  # Re-archive the plain OBJECTS (not archives): no cross-archive basename dedup, so
  # every definition is preserved; libtool also writes a proper Mach-O symbol table and
  # tolerates empty objects like iOS's pty_compat.o (-no_warning_for_no_symbol is cosmetic).
  rm -f "$workdir/$LIB_NAME"
  libtool -static -no_warning_for_no_symbol -o "$workdir/$LIB_NAME" "${all_objs[@]}"

  # Regression guard for THIS bug: the util definition the old archive-merge silently
  # dropped must now be a DEFINED text symbol (T), not undefined (U). Mangled C++ name
  # (Itanium ABI, identical across all three slices).
  if ! nm -arch "$arch" "$workdir/$LIB_NAME" 2>/dev/null | grep -q 'T __Z17set_native_localev'; then
    echo "FATAL: $name $LIB_NAME is missing the set_native_locale DEFINITION (T) —" \
         "the object merge dropped util objects again" >&2
    exit 1
  fi
  rm -rf "$objdir"
  echo "    built self-contained $workdir/$LIB_NAME (${#src_archives[@]} archives, ${#all_objs[@]} objects)"
}

# --------------------------------------------------------------------------- #
# Main.                                                                        #
# --------------------------------------------------------------------------- #
main() {
  test -d "$MOSH_SRC" || { echo "FATAL: vendored mosh missing at $MOSH_SRC"; exit 1; }
  test -f "$BRIDGE_HEADER" || { echo "FATAL: bridge header missing at $BRIDGE_HEADER"; exit 1; }

  # Mosh's autogen.sh runs `autoreconf -fi`; macOS runners don't ship autotools.
  # Install them (+ pkg-config for the PKG_CHECK_MODULES m4 macros). Idempotent.
  if command -v brew >/dev/null 2>&1; then
    for f in autoconf automake libtool pkg-config; do
      brew list "$f" >/dev/null 2>&1 || brew install "$f" || true
    done
  fi
  command -v autoreconf >/dev/null 2>&1 || {
    echo "FATAL: autoreconf not found and could not be installed (need autotools)"; exit 1;
  }

  # Clean output + build dirs for a reproducible run; keep the downloads cache.
  rm -rf "$OUT"
  mkdir -p "$DL_DIR"

  # Host codegen compiler (built once, arch-independent).
  build_host_protoc

  # Build every slice.
  for entry in "${SLICES[@]}"; do
    IFS='|' read -r name arch sdk host_triple min_flag <<< "$entry"
    build_slice "$name" "$arch" "$sdk" "$host_triple" "$min_flag"
  done

  # lipo the two simulator slices (arm64-sim + x86_64-sim) into one fat archive.
  # An xcframework static-lib slice must be ONE arch per platform-variant, so:
  #   device  = single arch (arm64)
  #   sim     = fat (arm64 + x86_64)  -- these two share the simulator variant.
  # Device and simulator are NEVER lipo'd together.
  local sim_fat="$BUILD_ROOT/ios-sim-fat/$LIB_NAME"
  mkdir -p "$(dirname "$sim_fat")"
  lipo -create \
    "$BUILD_ROOT/ios-arm64-sim/$LIB_NAME" \
    "$BUILD_ROOT/ios-x86_64-sim/$LIB_NAME" \
    -output "$sim_fat"

  # Headers dir for the xcframework (single public bridge header).
  local hdrs="$BUILD_ROOT/Headers"
  rm -rf "$hdrs"; mkdir -p "$hdrs"
  cp "$BRIDGE_HEADER" "$hdrs/"

  # Assemble: device slice + fat simulator slice.
  xcodebuild -create-xcframework \
    -library "$BUILD_ROOT/ios-arm64/$LIB_NAME"  -headers "$hdrs" \
    -library "$sim_fat"                          -headers "$hdrs" \
    -output "$OUT"

  # ----------------------------------------------------------------------- #
  # M1 SUCCESS GATE: the built device slice must export the `mosh_main`      #
  # bridge symbol. This is the line that proves M1 in CI.                    #
  # ----------------------------------------------------------------------- #
  # The device-only slice dir is literally `ios-arm64`; the simulator dir is
  # `ios-arm64_x86_64-simulator` (also contains the substring "ios-arm64"), so
  # exclude any path containing "simulator" to avoid matching the fat sim lib.
  local device_lib
  device_lib="$(find "$OUT" -name "$LIB_NAME" -path '*ios-arm64*' -not -path '*simulator*' | head -n1)"
  test -n "$device_lib" || { echo "GATE FAIL: no device $LIB_NAME inside $OUT"; exit 1; }

  # Match `mosh_main` as an exported (T) text symbol. Use `-arch arm64` so nm reads
  # the right slice, and match with/without the Mach-O leading underscore. Dump the
  # mosh-related symbols on failure so a naming mismatch is diagnosable in one run.
  echo "==> M1 gate: nm -arch arm64 '$device_lib' | grep ' T _${BRIDGE_SYMBOL}'"
  local nm_out
  nm_out="$(nm -arch arm64 "$device_lib" 2>/dev/null || nm "$device_lib" 2>/dev/null)"

  # NB: grep the captured string into a variable (NOT `grep -q` in a pipe). The merged
  # archive is large, so `grep -q` closes the pipe on the first match while the feeding
  # `printf` is still writing → SIGPIPE/"Broken pipe" → under `set -o pipefail` the
  # pipeline exits non-zero and the gate false-fails even though the symbol is present.
  # `grep ... || true` consumes the whole stream and never early-closes.
  local mosh_hit sentinel_hit
  mosh_hit="$(printf '%s\n' "$nm_out" | grep -E "[[:space:]]T[[:space:]]+_?${BRIDGE_SYMBOL}$" || true)"
  if [[ -n "$mosh_hit" ]]; then
    echo "OK: bridge symbol '${BRIDGE_SYMBOL}' present in device slice."
  else
    echo "GATE FAIL: bridge symbol '${BRIDGE_SYMBOL}' NOT found (as an exported T symbol) in $device_lib" >&2
    echo "  --- mosh-related symbols present (for diagnosis): ---" >&2
    printf '%s\n' "$nm_out" | grep -Ei "mosh|_main" | head -30 >&2 || echo "  (none matched mosh|_main)" >&2
    exit 1
  fi

  # SELF-CONTAINMENT GATE on the FINAL packaged device slice (belt-and-suspenders over
  # build_slice's per-slice guard): exporting mosh_main is necessary but NOT sufficient —
  # the frontend lib references sibling helpers (set_native_locale in libmoshutil) that
  # must be merged in, or the app link fails with "Undefined symbols". Match the MANGLED
  # C++ name (`__Z17set_native_localev`) — it is C++-linkage, not extern "C" like
  # mosh_main, so it never appears unmangled. Assert it's DEFINED (T), not undefined (U).
  local sentinel_hit
  sentinel_hit="$(printf '%s\n' "$nm_out" | grep -E "[[:space:]]T[[:space:]]+_?__Z17set_native_localev$" || true)"
  if [[ -n "$sentinel_hit" ]]; then
    echo "OK: set_native_locale is DEFINED (T) in the packaged device slice — self-contained."
    echo "SUCCESS: built $OUT"
  else
    echo "GATE FAIL: set_native_locale is not a defined (T) symbol in $device_lib — the sibling" >&2
    echo "  Mosh objects were not merged in; the app will fail to link. Check build_slice's object merge." >&2
    printf '%s\n' "$nm_out" | grep -Ei "locale|native" | head -20 >&2 || true
    exit 1
  fi
}

main "$@"
