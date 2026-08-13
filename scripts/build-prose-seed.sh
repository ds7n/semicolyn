#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 True Positive LLC
# SPDX-License-Identifier: GPL-3.0-only
#
# Build the bundled PROSE predictor seed (prose_en_v1.sketch) from the committed
# corpora in corpora/prose/ (dev + AI-prompt = our own generated text; tech = cleaned
# IETF RFC prose), blending the three register layers via LayeredSeedBuilder and
# dropping any profanity/slur token via the vendored blocklist. Only derived token
# frequencies ship, not the corpus text.
#
# Prereq: run scripts/build-profanity-blocklist.sh first (produces the blocklist).
# Usage:  scripts/build-prose-seed.sh
set -euo pipefail

CORPUS_DIR="corpora/prose"
BLOCKLIST="App/Resources/predictor/profanity_blocklist.txt"
COMBINED_OUT="App/Resources/predictor/prose_en_v1.sketch"
PROVENANCE_OUT="App/Resources/predictor/prose_en_v1.provenance.txt"

[ -f "$BLOCKLIST" ] || { echo "missing $BLOCKLIST (run build-profanity-blocklist.sh first)" >&2; exit 1; }

# The seedbuild tool reads one directory of .txt per layer. It runs INSIDE the docker
# dev container, which mounts the repo at /work, so the staging dirs must live under
# the repo (a /tmp path on the host is invisible to the container). Stage under a
# gitignored ./.prose-build/ and pass repo-relative paths.
WORK=".prose-build"
trap 'rm -rf "$WORK"' EXIT
rm -rf "$WORK"
mkdir -p "$WORK/dev" "$WORK/tech" "$WORK/prompt" "$WORK/out"
cp "$CORPUS_DIR/dev_v1.txt"      "$WORK/dev/"
cp "$CORPUS_DIR/tech_rfc_v1.txt" "$WORK/tech/"
cp "$CORPUS_DIR/prompt_v1.txt"   "$WORK/prompt/"

HOST_UID="$(id -u)" HOST_GID="$(id -g)" docker compose run --rm dev \
  swift run -c release semicolyn-seedbuild \
    --out "$WORK/out" \
    --dev "$WORK/dev" --tech "$WORK/tech" --prompt "$WORK/prompt" \
    --blocklist "$BLOCKLIST" \
    --prose-combined "$COMBINED_OUT"

size="$(wc -c < "$COMBINED_OUT" | tr -d ' ')"
{
  echo "prose_en_v1 provenance"
  echo "layers (LayeredSeedBuilder, normalize-per-layer then weight):"
  echo "  dev    (weight 1.5): corpora/prose/dev_v1.txt    (our own generated dev prose)"
  echo "  tech   (weight 1.5): corpora/prose/tech_rfc_v1.txt (cleaned IETF RFC prose, PD)"
  echo "  prompt (weight 2.0): corpora/prose/prompt_v1.txt  (our own generated AI-prompt prose)"
  echo "profanity: blocklist ($BLOCKLIST) applied at build; blocked tokens + their bigrams dropped."
  echo "hygiene: per-layer bigram cap 500, rare-bigram floor 2."
  echo "shipped: derived token frequencies only (this .sketch), NOT the corpus text."
  echo "size: $size bytes"
} > "$PROVENANCE_OUT"
echo "wrote $COMBINED_OUT ($size bytes) + $PROVENANCE_OUT"
