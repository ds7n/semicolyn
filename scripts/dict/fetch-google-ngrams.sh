#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 True Positive LLC
# SPDX-License-Identifier: GPL-3.0-only
#
# Stream-filter the Google Books Ngram v3 English export (20200217) for one n-gram order.
#
# The shard list is read from the export index page (no hardcoded shard count). Each shard
# is streamed `curl | gzip -dc | semicolyn-dictbuild ngram-filter` into <shard>.tsv.part,
# renamed to <shard>.tsv and stamped <shard>.done on success. The raw download is never
# stored. Shards with a .done stamp are skipped, so an interrupted run resumes by rerunning
# the same command. Per-shard logs: <out>/logs/<shard>.log. Run inside the dev container:
#
#   docker compose run --rm dev scripts/dict/fetch-google-ngrams.sh -n 1 -o data/dict-build/ngrams/1
set -euo pipefail

self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/../.."
# shellcheck source=scripts/dict/common.sh
source scripts/dict/common.sh

INDEX_BASE="https://storage.googleapis.com/books/ngrams/books/20200217/eng"

usage() {
  cat << 'EOF'
usage: scripts/dict/fetch-google-ngrams.sh -n|--order 1|2 -o|--out <dir> [options]

  -n, --order 1|2        n-gram order to fetch (eng-<order>-ngrams export)
  -o, --out <dir>        output directory for <shard>.tsv / <shard>.done
  -j, --jobs <n>         parallel shard streams (default 4)
  -c, --min-count <n>    drop n-grams whose summed count is below n (default 40)
  -y, --min-year <year>  first year summed (default 1990)
  -v, --vocab <file>     keep only n-grams whose every lowercased token is listed
  -t, --tool <path>      semicolyn-dictbuild binary (default: build it with swift)
  -l, --limit-shards <n> debug: fetch only n shards, evenly spaced across the index
  -h, --help             show this help

Prints "FETCH OK order=<n> shards=<n> lines=<n> bytes=<n>" when every shard is done.
EOF
}

# --shard <url> is the internal per-shard worker (called through xargs); its configuration
# arrives through the exported NGRAM_* variables.
if [ "${1:-}" = "--shard" ]; then
  url="$2"
  name="$(basename "$url" .gz)"
  out="$NGRAM_OUT"
  [ -f "$out/$name.done" ] && exit 0
  filter=("$NGRAM_TOOL" ngram-filter -y "$NGRAM_MIN_YEAR" -c "$NGRAM_MIN_COUNT")
  [ -n "$NGRAM_VOCAB" ] && filter+=(-v "$NGRAM_VOCAB")
  for attempt in 1 2 3; do
    log "shard $name: start (attempt $attempt)"
    # --speed-limit/--speed-time abort a stalled stream; curl --retry is deliberately not
    # used because a mid-stream retry cannot rewind a pipe. The whole shard retries instead.
    if curl -fsSL --connect-timeout 30 --speed-limit 10240 --speed-time 120 "$url" \
      | gzip -dc | "${filter[@]}" > "$out/$name.tsv.part" 2>> "$out/logs/$name.log"; then
      mv "$out/$name.tsv.part" "$out/$name.tsv"
      touch "$out/$name.done"
      log "shard $name: done ($(wc -l < "$out/$name.tsv" | tr -d ' ') lines)"
      exit 0
    fi
    log "shard $name: attempt $attempt failed (see $out/logs/$name.log)"
    sleep $((attempt * 30))
  done
  log "shard $name: FAILED after 3 attempts"
  exit 1
fi

order="" out="" jobs=4 min_count=40 min_year=1990 vocab="" tool="" limit=0
while [ $# -gt 0 ]; do
  case "$1" in
    -n | --order) order="${2:?}"; shift 2 ;;
    -o | --out) out="${2:?}"; shift 2 ;;
    -j | --jobs) jobs="${2:?}"; shift 2 ;;
    -c | --min-count) min_count="${2:?}"; shift 2 ;;
    -y | --min-year) min_year="${2:?}"; shift 2 ;;
    -v | --vocab) vocab="${2:?}"; shift 2 ;;
    -t | --tool) tool="${2:?}"; shift 2 ;;
    -l | --limit-shards) limit="${2:?}"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done
case "$order" in 1 | 2) ;; *) usage >&2; die "--order must be 1 or 2" ;; esac
[ -n "$out" ] || { usage >&2; die "--out is required"; }
for n in "$jobs" "$min_count" "$min_year" "$limit"; do
  [[ "$n" =~ ^[0-9]+$ ]] || die "not a non-negative integer: $n"
done
[ "$jobs" -ge 1 ] || die "--jobs must be at least 1"
need curl gzip sha256sum xargs
if [ -n "$vocab" ]; then
  [ -s "$vocab" ] || die "vocab file missing or empty: $vocab"
  vocab="$(cd "$(dirname "$vocab")" && pwd)/$(basename "$vocab")"
fi
[ -n "$tool" ] || tool="$(dictbuild_bin)"
mkdir -p "$out/logs"

# Filter settings are stamped on the first run; resuming with different settings would mix
# incompatible shards, so it is refused.
vocab_sha="none"
[ -n "$vocab" ] && vocab_sha="$(sha256sum "$vocab" | cut -d' ' -f1)"
conf="order=$order min_year=$min_year min_count=$min_count vocab_sha256=$vocab_sha"
if [ -f "$out/filter.conf" ]; then
  [ "$(cat "$out/filter.conf")" = "$conf" ] \
    || die "$out was filtered with '$(cat "$out/filter.conf")', not '$conf'; use a fresh --out"
else
  printf '%s\n' "$conf" > "$out/filter.conf"
fi

index_url="$INDEX_BASE/eng-$order-ngrams_exports.html"
curl -fsSL "$index_url" -o "$out/index.html"
# Shard links look like http://storage.googleapis.com/.../eng/2-00000-of-00589.gz; fetch over https.
grep -oE "https?://storage\.googleapis\.com/books/ngrams/books/20200217/eng/$order-[0-9]{5}-of-[0-9]{5}\.gz" \
  "$out/index.html" | sed 's|^http://|https://|' | sort -u > "$out/shards.txt"
listed="$(wc -l < "$out/shards.txt" | tr -d ' ')"
[ "$listed" -gt 0 ] || die "no shard URLs found in $index_url"
expected="$(sed -E 's/.*-of-0*([0-9]+)\.gz$/\1/' "$out/shards.txt" | sort -u)"
[ "$expected" = "$listed" ] || die "index lists $listed shards but names say of-$expected"
if [ "$limit" -gt 0 ]; then
  # Shards are sorted by n-gram text (the first ones hold digits and punctuation), so a
  # debug subset takes the midpoints of n equal slices of the index instead of the head.
  [ "$limit" -le "$listed" ] || die "--limit-shards $limit exceeds the $listed listed shards"
  awk -v n="$limit" -v total="$listed" \
    'BEGIN { for (k = 0; k < n; k++) want[int((2 * k + 1) * total / (2 * n)) + 1] = 1 } want[NR]' \
    "$out/shards.txt" > "$out/shards.todo"
else
  cp "$out/shards.txt" "$out/shards.todo"
fi
wanted="$(wc -l < "$out/shards.todo" | tr -d ' ')"
already="$(find "$out" -maxdepth 1 -name '*.done' | wc -l | tr -d ' ')"
log "order $order: $wanted of $listed shards wanted, $already already done, jobs=$jobs -> $out"

export NGRAM_OUT="$out" NGRAM_TOOL="$tool" NGRAM_MIN_COUNT="$min_count" \
  NGRAM_MIN_YEAR="$min_year" NGRAM_VOCAB="$vocab"
status=0
xargs -P "$jobs" -n 1 "$self" --shard < "$out/shards.todo" || status=$?

done_count=0
while read -r url; do
  [ -f "$out/$(basename "$url" .gz).done" ] && done_count=$((done_count + 1))
done < "$out/shards.todo"
if [ "$status" -ne 0 ] || [ "$done_count" -ne "$wanted" ]; then
  log "FETCH INCOMPLETE order=$order done=$done_count/$wanted; rerun the same command to resume"
  exit 1
fi
lines="$(cat "$out"/*.tsv | wc -l | tr -d ' ')"
bytes="$(cat "$out"/*.tsv | wc -c | tr -d ' ')"
echo "FETCH OK order=$order shards=$done_count lines=$lines bytes=$bytes"
