#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 True Positive LLC
# SPDX-License-Identifier: GPL-3.0-only
#
# Build the bundled predictor seed from live CLI corpora.
#
# Fetches tldr-pages (example invocations) and the Fig autocomplete spec corpus
# (structured subcommands/flags), then runs the semicolyn-seedbuild Swift tool over
# both, emitting seed_unigram_v1.sketch and seed_bigram_v1.sketch. The fetch lives
# here, not in the Swift tool, so the tool stays pure file-I/O and unit-testable
# against fixture directories.
#
# Usage:   scripts/build-seed.sh [out-dir]
# Refresh: run this, then commit the updated App/Resources/predictor/seed_v1.sketch +
#          seed_v1.provenance.txt. Bump the content version in semicolyn-seedbuild to
#          force a reinstall on the next app launch.
# Pin via: TLDR_REF=<tag> FIG_REF=<sha-or-tag> scripts/build-seed.sh  (defaults below)
set -euo pipefail

OUT_DIR="${1:-seeds}"                    # gitignored two-file debug artifacts (/seeds/)
TLDR_REPO="https://github.com/tldr-pages/tldr.git"
FIG_REPO="https://github.com/withfig/autocomplete.git"

# Pinned corpus refs so the committed seed maps to an auditable snapshot (required for
# the CC-BY attribution + provenance obligations; see plans/license-audit/REPORT.md).
# Override via env for a deliberate bump. tldr uses release tags; fig pins a commit.
: "${TLDR_REF:=v2.3}"
: "${FIG_REF:=aef52acff84c45edde61ae610cc2c964802b9a38}"

# The committed bundle resource the app installs at launch (XcodeGen bundles it).
COMBINED_OUT="App/Resources/predictor/seed_v1.sketch"
PROVENANCE_OUT="App/Resources/predictor/seed_v1.provenance.txt"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# clone_pinned <repo> <dest> <ref-env-name> <ref-value>
# Pin the ref for reproducible release seeds. `ref` may be a tag/branch OR a full
# commit SHA (fig has no clean release tags, so it pins a commit). Unset → default
# branch (dev only). The exact source commit is always recorded for traceability.
clone_pinned() {
  local repo="$1" dest="$2" name="$3" ref="$4"
  if [ -z "$ref" ]; then
    echo "WARNING: $name unset — cloning default branch of $repo (NOT reproducible)." >&2
    git clone --depth 1 "$repo" "$dest"
  elif printf '%s' "$ref" | grep -qE '^[0-9a-f]{40}$'; then
    # Full commit SHA: --branch doesn't accept a SHA, so init + fetch the exact commit.
    echo "fetching $repo @ commit $ref ..."
    git init -q "$dest"
    git -C "$dest" remote add origin "$repo"
    git -C "$dest" fetch -q --depth 1 origin "$ref"
    git -C "$dest" checkout -q FETCH_HEAD
  else
    echo "cloning $repo @ $ref ..."
    git clone --depth 1 --branch "$ref" "$repo" "$dest"
  fi
  echo "$name commit: $(git -C "$dest" rev-parse HEAD)"
}

clone_pinned "$TLDR_REPO" "$WORK/tldr" "TLDR_REF" "$TLDR_REF"
clone_pinned "$FIG_REPO" "$WORK/fig" "FIG_REF" "$FIG_REF"

# tldr: English pages only (pages.<lang>/ hold other languages).
# fig:  spec sources live under src/.
# Release build: ingesting ~15k pages + ~600 specs in debug is needlessly slow.
# Emits the two-file debug artifacts (--out) AND the single combined seed_pinned-format
# blob (--combined) the app installs.
mkdir -p "$(dirname "$COMBINED_OUT")"
swift run -c release semicolyn-seedbuild \
  --out "$OUT_DIR" \
  --tldr "$WORK/tldr/pages" \
  --fig "$WORK/fig/src" \
  --combined "$COMBINED_OUT"

# Provenance: the resolved refs + exact source commits (auditable snapshot) + licenses.
TLDR_SHA="$(git -C "$WORK/tldr" rev-parse HEAD)"
FIG_SHA="$(git -C "$WORK/fig" rev-parse HEAD)"
SELF_SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
{
  echo "seed content version: 1"
  echo "built from semicolyn: $SELF_SHA"
  echo "tldr-pages: $TLDR_REF @ $TLDR_SHA (CC-BY-4.0)"
  echo "fig autocomplete: $FIG_REF @ $FIG_SHA (MIT)"
} > "$PROVENANCE_OUT"
echo "wrote $COMBINED_OUT + $PROVENANCE_OUT"
