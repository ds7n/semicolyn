#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 True Positive LLC
# SPDX-License-Identifier: GPL-3.0-only
#
# Check out the submodules the Apple build needs, and only those.
#
# A recursive checkout also clones every nested submodule of Eternal Terminal,
# including sentry-native (whose crashpad/lss submodule lives on
# chromium.googlesource.com and often returns 503) and vcpkg. The iOS ET build
# compiles only the client transport, which needs the eight dependencies below
# (see extern/eternaltermlib/CMakeLists.txt). Run from the repo root after a
# non-recursive `submodules: true` checkout.
set -euo pipefail

ET_DEPS=(
  external/easyloggingpp
  external/PlatformFolders
  external/UniversalStacktrace
  external/json
  external/base64
  external/cpp-httplib
  external/ThreadPool
  external/sole
)

git submodule update --init extern/mosh extern/swift-sodium extern/ios-cmake extern/eternaltermlib
git -C extern/eternaltermlib submodule update --init extern/eternalterminal
git -C extern/eternaltermlib/extern/eternalterminal submodule update --init --depth 1 "${ET_DEPS[@]}"
git submodule status --recursive
