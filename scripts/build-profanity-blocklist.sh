#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 True Positive LLC
# SPDX-License-Identifier: GPL-3.0-only
#
# Vendor a profanity blocklist from words/cuss (MIT). Emits single-word entries with
# a sureness rating >= CUSS_THRESHOLD (default 2 = clear profanity/slurs), so mild or
# ambiguous shell-legit words (kill, hell, damn) are NOT blocked. Exact-token match is
# done at use time (see TokenFilter.blocklist), so no substring/Scunthorpe risk.
#
# Usage:   scripts/build-profanity-blocklist.sh
# Tune:    CUSS_THRESHOLD=1 scripts/build-profanity-blocklist.sh   (broader net)
set -euo pipefail

SRC="https://raw.githubusercontent.com/words/cuss/main/index.js"
OUT="App/Resources/predictor/profanity_blocklist.txt"
PROV="App/Resources/predictor/profanity_blocklist.provenance.txt"
# A hand-curated extra set merged on top of the cuss list: identity slurs cuss
# under-rates at sureness 1, plus common acronym-profanity cuss omits (wtf, stfu, ...),
# minus any word with a common innocent terminal/English meaning (kept suggestable).
# See the provenance file for the curation rationale.
CURATED="App/Resources/predictor/blocklist_extra.txt"
: "${CUSS_THRESHOLD:=2}"

raw="$(curl -fsSL "$SRC")"

# cuss entries look like:  word: 2,   or  'multi word phrase': 2,
# Keep single-token (letters only, no spaces) entries whose rating >= threshold,
# then merge the curated slur set. Final list is sorted-unique, lowercased.
{
  printf '%s\n' "$raw" \
    | grep -oE "^[[:space:]]*'?[a-zA-Z]+'?: [0-9]," \
    | sed -E "s/^[[:space:]]*'?//; s/'?: ([0-9]),$/ \1/" \
    | awk -v t="$CUSS_THRESHOLD" '$2 >= t { print tolower($1) }'
  [ -f "$CURATED" ] && tr '[:upper:]' '[:lower:]' < "$CURATED"
} | grep -E '^[a-z]+$' | sort -u > "$OUT"

count="$(wc -l < "$OUT" | tr -d ' ')"
{
  echo "profanity_blocklist provenance"
  echo "source: words/cuss (MIT license), $SRC"
  echo "policy: single-token cuss entries with sureness >= $CUSS_THRESHOLD, PLUS a"
  echo "  hand-curated identity-slur set ($CURATED) covering slurs cuss under-rates at"
  echo "  sureness 1, minus words with a common innocent terminal/English meaning"
  echo "  (cracker, spade, guinea, paddy, queer, mick, etc. kept suggestable)."
  echo "match: exact-token, case-insensitive (no substring; no Scunthorpe)."
  echo "count: $count words"
} > "$PROV"

echo "wrote $OUT ($count words) + $PROV"
