#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 True Positive LLC
# SPDX-License-Identifier: GPL-3.0-only
#
# Build the shipped English dictionary (english_v2.bin, GDIC) from Google Books Ngram v3,
# wordfreq, Wikipedia titles and SCOWL.
#
#   1. 1-grams (min count, years >= min year) via scripts/dict/fetch-google-ngrams.sh
#   2. vocabulary pass: the folded forms of the admitted words (semicolyn-dictbuild english --vocab-out)
#   3. 2-grams filtered by that vocabulary (same min count)
#   4. semicolyn-dictbuild english -> <out>, plus <name>.provenance.txt and REUSE sidecars
#
# Prerequisite: scripts/dict/fetch-sources.sh (host) has filled <sources>. Run inside the dev
# container; resumable (finished shards are skipped):
#
#   docker compose run --rm dev scripts/build-english-dict.sh -j 4
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/dict/common.sh
source scripts/dict/common.sh

usage() {
  cat << EOF
usage: scripts/build-english-dict.sh [options]

  -w, --work <dir>             work tree (default $DICT_WORK_DEFAULT)
  -s, --sources <dir>          fetch-sources.sh output (default <work>/sources)
  -o, --out <file>             output blob (default App/Resources/predictor/english_v2.bin)
  -j, --jobs <n>               parallel shard streams (default 4)
  -c, --min-count <n>          n-gram min summed count (default 40)
  -y, --min-year <year>        first year summed (default 1990)
  -b, --blocklist <file>       folded blocklist (default App/Resources/predictor/profanity_blocklist.txt)
  -l, --limit-shards <n>       debug: only n evenly spaced shards per order (use a separate --work)
      --max-words <n>          dictionary word cap (builder default 150000)
      --successor-words <n>    previous words that get successors (builder default 40000)
      --successors-per-word <n> successors kept per word (builder default 24)
  -h, --help                   show this help

Prints "BUILD OK english words=<n> bytes=<n> gzip=<n>" on success.
EOF
}

work="$DICT_WORK_DEFAULT" sources="" out="App/Resources/predictor/english_v2.bin" jobs=4
min_count=40 min_year=1990 blocklist="App/Resources/predictor/profanity_blocklist.txt" limit=0
config=()
while [ $# -gt 0 ]; do
  case "$1" in
    -w | --work) work="${2:?}"; shift 2 ;;
    -s | --sources) sources="${2:?}"; shift 2 ;;
    -o | --out) out="${2:?}"; shift 2 ;;
    -j | --jobs) jobs="${2:?}"; shift 2 ;;
    -c | --min-count) min_count="${2:?}"; shift 2 ;;
    -y | --min-year) min_year="${2:?}"; shift 2 ;;
    -b | --blocklist) blocklist="${2:?}"; shift 2 ;;
    -l | --limit-shards) limit="${2:?}"; shift 2 ;;
    --max-words | --successor-words | --successors-per-word) config+=("$1" "${2:?}"); shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done
[ -n "$sources" ] || sources="$work/sources"
for f in scowl.txt titles.txt wordfreq.tsv manifest.txt; do
  [ -s "$sources/$f" ] || die "missing $sources/$f; run scripts/dict/fetch-sources.sh first"
done
[ -s "$blocklist" ] || die "missing blocklist: $blocklist"
case "$out" in *.bin) ;; *) die "--out must end in .bin: $out" ;; esac
need gzip sha256sum
mkdir -p "$work/logs" "$(dirname "$out")"

tool="$(dictbuild_bin)"
fetch=(scripts/dict/fetch-google-ngrams.sh -t "$tool" -j "$jobs" -c "$min_count" -y "$min_year" -l "$limit")
side=(-w "$sources/wordfreq.tsv" -s "$sources/scowl.txt" -t "$sources/titles.txt" -l "$blocklist")

log "english: step 1/4 unigrams"
"${fetch[@]}" -n 1 -o "$work/ngrams/1" | tee "$work/logs/fetch-1.summary"

log "english: step 2/4 vocabulary"
"$tool" english --vocab-out "$work/vocab.txt" -u "$work/ngrams/1" "${side[@]}" ${config[@]+"${config[@]}"} \
  2>&1 | tee "$work/logs/vocab.log"

log "english: step 3/4 bigrams"
"${fetch[@]}" -n 2 -o "$work/ngrams/2" -v "$work/vocab.txt" | tee "$work/logs/fetch-2.summary"

log "english: step 4/4 build"
"$tool" english -u "$work/ngrams/1" -b "$work/ngrams/2" "${side[@]}" ${config[@]+"${config[@]}"} -o "$out" \
  2>&1 | tee "$work/logs/english-build.log"

words="$(sed -n 's/^words: //p' "$work/logs/english-build.log")"
bytes="$(file_bytes "$out")"
gz="$(gzip_bytes "$out")"
base="${out%.bin}"
shards1="$(sed -n 's/.*FETCH OK order=1 shards=\([0-9]*\).*/\1/p' "$work/logs/fetch-1.summary")"
shards2="$(sed -n 's/.*FETCH OK order=2 shards=\([0-9]*\).*/\1/p' "$work/logs/fetch-2.summary")"
{
  echo "english_v2 provenance (GDIC v1, built by scripts/build-english-dict.sh)"
  echo "built from semicolyn: $(git rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "built at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "sources:"
  echo "  google books ngram v3 eng 20200217 (CC BY 3.0), https://storage.googleapis.com/books/ngrams/books/20200217/eng/"
  echo "    1-grams: $shards1 shards ($(cat "$work/ngrams/1/filter.conf"))"
  echo "    2-grams: $shards2 shards ($(cat "$work/ngrams/2/filter.conf"))"
  [ "$limit" -gt 0 ] && echo "    DEBUG PARTIAL BUILD: --limit-shards $limit (not for shipping)"
  grep -E '^(wordfreq|wiki|scowl)=' "$sources/manifest.txt" | sed 's/^/  /'
  echo "  blocklist: $blocklist (sha256 $(sha256sum "$blocklist" | cut -d' ' -f1))"
  echo "config: min_year=$min_year min_count=$min_count ${config[*]:-builder defaults (max-words 150000, successor-words 40000, successors-per-word 24)}"
  echo "vocabulary: $(sed -n 's/^vocab: //p' "$work/logs/vocab.log") folded words (sha256 $(sha256sum "$work/vocab.txt" | cut -d' ' -f1))"
  echo "build output:"
  grep -E '^(unigrams|wordfreq|bigrams|side files|words|pairs|successor keys):' "$work/logs/english-build.log" | sed 's/^/  /'
  echo "changes: reduced to word and word-pair frequency scores"
  echo "size: $bytes bytes raw, $gz bytes gzip -9"
} > "$base.provenance.txt"

cat > "$out.license" << 'EOF'
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-FileCopyrightText: Google Books Ngram Viewer data (Google LLC), CC BY 3.0
SPDX-FileCopyrightText: wordfreq data (Robyn Speer and contributors), CC BY-SA 4.0
SPDX-FileCopyrightText: Wikipedia contributors (enwiki page titles), CC BY-SA 4.0
SPDX-FileCopyrightText: SCOWL (Kevin Atkinson and contributors), SCOWL copyright notice
SPDX-License-Identifier: CC-BY-SA-4.0

Derived English word and word-pair frequency scores (GDIC). Changes were made: reduced to
word and word-pair frequency scores. See english_v2.provenance.txt and SEED_ATTRIBUTION.md.
EOF
cat > "$base.provenance.txt.license" << 'EOF'
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only

Provenance record for the derived English dictionary; see SEED_ATTRIBUTION.md.
EOF

echo "BUILD OK english words=$words bytes=$bytes gzip=$gz"
