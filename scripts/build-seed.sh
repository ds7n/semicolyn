#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 True Positive LLC
# SPDX-License-Identifier: GPL-3.0-only
#
# Build the bundled predictor seed from live tldr-pages.
#
# Fetches tldr-pages at a PINNED tag (reproducible) and runs the glymr-seedbuild
# Swift tool over the English pages, emitting seed_unigram_v1.sketch and
# seed_bigram_v1.sketch. The fetch lives here, not in the Swift tool, so the tool
# stays pure file-I/O and unit-testable against a fixture directory.
#
# Usage:   scripts/build-seed.sh [out-dir]
# Pin via: TLDR_REF=v2.2 scripts/build-seed.sh
set -euo pipefail

OUT_DIR="${1:-seeds}"                    # gitignored build artifacts (bundled in a later slice)
REPO="https://github.com/tldr-pages/tldr.git"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Pin TLDR_REF=<tag> for reproducible release seeds. Unset → default branch, which
# is fine for dev but NOT reproducible; we still record the exact commit below.
if [ -n "${TLDR_REF:-}" ]; then
  echo "cloning tldr-pages @ ${TLDR_REF} ..."
  git clone --depth 1 --branch "$TLDR_REF" "$REPO" "$WORK/tldr"
else
  echo "WARNING: TLDR_REF unset — cloning default branch (NOT reproducible)." >&2
  echo "         pin a tag for release builds, e.g. TLDR_REF=v2.3 $0" >&2
  git clone --depth 1 "$REPO" "$WORK/tldr"
fi

# Record the exact source commit so a build artifact is always traceable.
echo "tldr-pages commit: $(git -C "$WORK/tldr" rev-parse HEAD)"

# English pages only — non-English vocabularies live under pages.<lang>/.
# Release build: ingesting ~15k pages in debug is needlessly slow.
swift run -c release glymr-seedbuild "$WORK/tldr/pages" "$OUT_DIR"
