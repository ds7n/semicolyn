#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 True Positive LLC
# SPDX-License-Identifier: GPL-3.0-only
#
# Fetch the pinned non-Google inputs for the English and command dictionaries into
# <work>/sources: SCOWL word lists, Wikipedia titles, wordfreq frequencies, tldr-pages and
# Fig autocomplete. Every step stamps <step>.done and is skipped on rerun. Pins, URLs,
# checksums and licences are appended to <work>/sources/manifest.txt for the provenance
# files. Needs curl, git, iconv, gzip, sha1sum/sha256sum and python3 plus uv (or a python3
# with venv/ensurepip) for the wordfreq export. The dev container has no python3, so run
# this on the host:
#
#   scripts/dict/fetch-sources.sh
set -euo pipefail

cd "$(dirname "$0")/../.."
# shellcheck source=scripts/dict/common.sh
source scripts/dict/common.sh

# Checksums of the default pins, verified after download.
SCOWL_DEFAULT="2020.12.07"
SCOWL_DEFAULT_SHA256="5587667caa20c4891390c2d42dbb4d5c4c3f41bee77af1457ece3ba23fb859cc"
WORDFREQ_DEFAULT="3.1.1"
WORDFREQ_DEFAULT_SHA256="4b1c6ecffc6198be3396d5cf871c4423ca71c907c231348d352dd54d62b97473"
MSGPACK_PIN="1.1.0"
# Latest complete enwiki dump on dumps.wikimedia.org when this was written (2026-10-18).
# Wikimedia keeps only recent dumps there; bump the date when it ages out.
WIKI_DEFAULT="20261001"

usage() {
  cat << EOF
usage: scripts/dict/fetch-sources.sh [options]

  -w, --work <dir>             work tree (default $DICT_WORK_DEFAULT); writes <work>/sources
  -s, --scowl-version <ver>    SCOWL release (default $SCOWL_DEFAULT)
  -d, --wiki-date <yyyymmdd>   enwiki dump date for all-titles-in-ns0 (default $WIKI_DEFAULT)
  -f, --wordfreq-version <v>   wordfreq wheel version (default $WORDFREQ_DEFAULT)
  -t, --tldr-ref <tag>         tldr-pages tag (default: the pin in scripts/dict/common.sh)
  -g, --fig-ref <sha>          Fig autocomplete commit (default: the pin in scripts/dict/common.sh)
  -h, --help                   show this help

Prints "SOURCES OK scowl=<n> titles=<n> wordfreq=<n> tldr=<ref> fig=<ref>" on success.
EOF
}

work="$DICT_WORK_DEFAULT" scowl_ver="$SCOWL_DEFAULT" wiki_date="$WIKI_DEFAULT"
wordfreq_ver="$WORDFREQ_DEFAULT" tldr_ref="" fig_ref=""
while [ $# -gt 0 ]; do
  case "$1" in
    -w | --work) work="${2:?}"; shift 2 ;;
    -s | --scowl-version) scowl_ver="${2:?}"; shift 2 ;;
    -d | --wiki-date) wiki_date="${2:?}"; shift 2 ;;
    -f | --wordfreq-version) wordfreq_ver="${2:?}"; shift 2 ;;
    -t | --tldr-ref) tldr_ref="${2:?}"; shift 2 ;;
    -g | --fig-ref) fig_ref="${2:?}"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done
[ -n "$tldr_ref" ] || tldr_ref="$(pinned_ref TLDR_REF)"
[ -n "$fig_ref" ] || fig_ref="$(pinned_ref FIG_REF)"
[[ "$wiki_date" =~ ^[0-9]{8}$ ]] || die "--wiki-date must be yyyymmdd, got $wiki_date"
need curl git gzip iconv sha1sum sha256sum tar python3

src="$work/sources"
mkdir -p "$src"
manifest="$src/manifest.txt"
touch "$manifest"

# record <key> <value>: replace-or-append one manifest line.
record() {
  local tmp="$manifest.tmp"
  grep -v "^$1=" "$manifest" > "$tmp" || true
  printf '%s=%s\n' "$1" "$2" >> "$tmp"
  mv "$tmp" "$manifest"
}

# verify_sha256 <file> <expected or empty>: print the digest; die on a mismatch.
verify_sha256() {
  local got
  got="$(sha256sum "$1" | cut -d' ' -f1)"
  if [ -n "$2" ] && [ "$got" != "$2" ]; then
    die "sha256 mismatch for $1: got $got, want $2"
  fi
  printf '%s\n' "$got"
}

# --- SCOWL: final/english-words.* and american-words.* at sizes 10..70, merged and folded.
fetch_scowl() {
  local dir="$src/scowl" url="https://downloads.sourceforge.net/project/wordlist/SCOWL/$scowl_ver/scowl-$scowl_ver.tar.gz"
  local want="" sha size file
  [ -f "$dir/.done" ] && { log "scowl: already done"; return; }
  mkdir -p "$dir"
  log "scowl: downloading $url"
  curl -fsSL "$url" -o "$dir/scowl.tar.gz"
  [ "$scowl_ver" = "$SCOWL_DEFAULT" ] && want="$SCOWL_DEFAULT_SHA256"
  sha="$(verify_sha256 "$dir/scowl.tar.gz" "$want")"
  tar -xzf "$dir/scowl.tar.gz" -C "$dir" "scowl-$scowl_ver/final" "scowl-$scowl_ver/Copyright"
  : > "$dir/merged.latin1"
  for size in 10 20 35 40 50 55 60 70; do
    for file in "$dir/scowl-$scowl_ver/final/english-words.$size" "$dir/scowl-$scowl_ver/final/american-words.$size"; do
      [ -f "$file" ] && cat "$file" >> "$dir/merged.latin1"
    done
  done
  # SCOWL lists are ISO-8859-1. Fold to lowercase; drop possessives (books tokenize 's apart).
  iconv -f ISO-8859-1 -t UTF-8 "$dir/merged.latin1" | tr -d '\r' | tr '[:upper:]' '[:lower:]' \
    | grep -v "'s\$" | grep -v '^$' | LC_ALL=C sort -u > "$src/scowl.txt"
  record scowl "SCOWL $scowl_ver, final/{english,american}-words.{10..70}, $url, sha256 $sha, licence: SCOWL copyright (permissive, see scowl-$scowl_ver/Copyright)"
  touch "$dir/.done"
  log "scowl: $(wc -l < "$src/scowl.txt" | tr -d ' ') folded words"
}

# --- Wikipedia titles: single-token, letters-only, 2..30 chars, case kept.
fetch_wiki() {
  local dir="$src/wiki" name="enwiki-$wiki_date-all-titles-in-ns0.gz"
  local base="https://dumps.wikimedia.org/enwiki/$wiki_date" want sha
  [ -f "$dir/.done" ] && { log "wiki: already done"; return; }
  mkdir -p "$dir"
  log "wiki: downloading $base/$name"
  curl -fsSL "$base/enwiki-$wiki_date-sha1sums.txt" -o "$dir/sha1sums.txt"
  want="$(grep " $name\$" "$dir/sha1sums.txt" | cut -d' ' -f1)"
  [ -n "$want" ] || die "wiki: $name not listed in $base/enwiki-$wiki_date-sha1sums.txt"
  curl -fsSL "$base/$name" -o "$dir/$name"
  sha="$(sha1sum "$dir/$name" | cut -d' ' -f1)"
  [ "$sha" = "$want" ] || die "sha1 mismatch for $name: got $sha, want $want"
  gzip -dc "$dir/$name" | LC_ALL=C grep -E '^[A-Za-z]{2,30}$' | LC_ALL=C sort -u > "$src/titles.txt"
  record wiki "Wikipedia enwiki $wiki_date all-titles-in-ns0, $base/$name, sha1 $sha, licence: CC BY-SA 4.0"
  touch "$dir/.done"
  log "wiki: $(wc -l < "$src/titles.txt" | tr -d ' ') titles kept"
}

# --- wordfreq: pinned wheel via pip download, large_en.msgpack.gz exported to TSV.
fetch_wordfreq() {
  local dir="$src/wordfreq" venv="$work/venv" wheel want="" sha member="wordfreq/data/large_en.msgpack.gz"
  [ -f "$dir/.done" ] && { log "wordfreq: already done"; return; }
  mkdir -p "$dir/wheel" "$dir/data"
  if [ ! -x "$venv/bin/pip" ]; then
    if command -v uv > /dev/null 2>&1; then
      uv venv --seed "$venv"
    else
      python3 -m venv "$venv"
    fi
  fi
  "$venv/bin/pip" install --quiet "msgpack==$MSGPACK_PIN"
  "$venv/bin/pip" download --quiet --no-deps --only-binary=:all: "wordfreq==$wordfreq_ver" -d "$dir/wheel"
  wheel="$dir/wheel/wordfreq-$wordfreq_ver-py3-none-any.whl"
  [ -f "$wheel" ] || die "wordfreq wheel not downloaded: $wheel"
  [ "$wordfreq_ver" = "$WORDFREQ_DEFAULT" ] && want="$WORDFREQ_DEFAULT_SHA256"
  sha="$(verify_sha256 "$wheel" "$want")"
  # Extract only the data member; nothing from the wheel is executed.
  python3 -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extract(sys.argv[2], sys.argv[3])' \
    "$wheel" "$member" "$dir/data"
  "$venv/bin/python3" -I scripts/dict/export_wordfreq.py -i "$dir/data/$member" -o "$src/wordfreq.tsv"
  record wordfreq "wordfreq $wordfreq_ver (rspeer), $member, https://pypi.org/project/wordfreq/$wordfreq_ver/, wheel sha256 $sha, licence: data CC BY-SA 4.0 (accepted exception: the English blend includes OpenSubtitles 2018, Reddit, Twitter and SUBTLEX counts with unclear upstream terms; the maintainer asserts the blend is redistributable under CC BY-SA 4.0 and SUBTLEX granted any-purpose permission)"
  touch "$dir/.done"
  log "wordfreq: $(wc -l < "$src/wordfreq.tsv" | tr -d ' ') words"
}

# clone_pinned <repo> <dest> <ref>: a tag/branch, or a full commit SHA via init + fetch.
clone_pinned() {
  local repo="$1" dest="$2" ref="$3"
  if printf '%s' "$ref" | grep -qE '^[0-9a-f]{40}$'; then
    git init -q "$dest"
    git -C "$dest" remote add origin "$repo"
    git -C "$dest" fetch -q --depth 1 origin "$ref"
    git -C "$dest" checkout -q FETCH_HEAD
  else
    git -c advice.detachedHead=false clone -q --depth 1 --branch "$ref" "$repo" "$dest"
  fi
}

# --- tldr-pages and Fig autocomplete at the scripts/dict/common.sh pins.
fetch_repo() {
  local key="$1" repo="$2" ref="$3" licence="$4" dest="$src/$1" head
  [ -f "$src/$key.done" ] && { log "$key: already done"; return; }
  [ -e "$dest" ] && die "$dest exists without $src/$key.done; move it aside and rerun"
  log "$key: cloning $repo @ $ref"
  clone_pinned "$repo" "$dest" "$ref"
  head="$(git -C "$dest" rev-parse HEAD)"
  record "$key" "$key $ref @ $head, $repo, licence: $licence"
  touch "$src/$key.done"
}

fetch_scowl
fetch_wiki
fetch_wordfreq
fetch_repo tldr "https://github.com/tldr-pages/tldr.git" "$tldr_ref" "CC BY 4.0"
fetch_repo fig "https://github.com/withfig/autocomplete.git" "$fig_ref" "MIT"

echo "SOURCES OK scowl=$(wc -l < "$src/scowl.txt" | tr -d ' ') titles=$(wc -l < "$src/titles.txt" | tr -d ' ') wordfreq=$(wc -l < "$src/wordfreq.tsv" | tr -d ' ') tldr=$tldr_ref fig=$fig_ref"
