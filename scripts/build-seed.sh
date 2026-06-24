#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 True Positive LLC
# SPDX-License-Identifier: GPL-3.0-only
#
# Build the bundled predictor seed from live CLI corpora.
#
# Fetches tldr-pages (example invocations) and the Fig autocomplete spec corpus
# (structured subcommands/flags), then runs the neotilde-seedbuild Swift tool over
# both, emitting seed_unigram_v1.sketch and seed_bigram_v1.sketch. The fetch lives
# here, not in the Swift tool, so the tool stays pure file-I/O and unit-testable
# against fixture directories.
#
# Usage:   scripts/build-seed.sh [out-dir]
# Pin via: TLDR_REF=v2.3 FIG_REF=<sha-or-tag> scripts/build-seed.sh
set -euo pipefail

OUT_DIR="${1:-seeds}"                    # gitignored build artifacts (bundled in a later slice)
TLDR_REPO="https://github.com/tldr-pages/tldr.git"
FIG_REPO="https://github.com/withfig/autocomplete.git"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# clone_pinned <repo> <dest> <ref-env-name> <ref-value>
# Pin the ref for reproducible release seeds; unset → default branch (dev only).
# The exact source commit is always recorded for traceability.
clone_pinned() {
  local repo="$1" dest="$2" name="$3" ref="$4"
  if [ -n "$ref" ]; then
    echo "cloning $repo @ $ref ..."
    git clone --depth 1 --branch "$ref" "$repo" "$dest"
  else
    echo "WARNING: $name unset — cloning default branch of $repo (NOT reproducible)." >&2
    git clone --depth 1 "$repo" "$dest"
  fi
  echo "$name commit: $(git -C "$dest" rev-parse HEAD)"
}

clone_pinned "$TLDR_REPO" "$WORK/tldr" "TLDR_REF" "${TLDR_REF:-}"
clone_pinned "$FIG_REPO" "$WORK/fig" "FIG_REF" "${FIG_REF:-}"

# tldr: English pages only (pages.<lang>/ hold other languages).
# fig:  spec sources live under src/.
# Release build: ingesting ~15k pages + ~600 specs in debug is needlessly slow.
swift run -c release neotilde-seedbuild \
  --out "$OUT_DIR" \
  --tldr "$WORK/tldr/pages" \
  --fig "$WORK/fig/src"
