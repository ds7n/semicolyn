# shellcheck shell=bash
# SPDX-FileCopyrightText: 2026 True Positive LLC
# SPDX-License-Identifier: GPL-3.0-only
#
# Shared helpers for the dictionary scripts (sourced, never run). Callers set -euo pipefail
# and cd to the repo root before sourcing.

# Default work tree for every dictionary build input and intermediate (gitignored data/).
# shellcheck disable=SC2034 # read by the scripts that source this file
DICT_WORK_DEFAULT="data/dict-build"

# log <message...>: timestamped line on stderr.
log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

# die <message...>: log an error and exit 1.
die() {
  log "error: $*"
  exit 1
}

# need <command...>: die unless every command is on PATH.
need() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" > /dev/null 2>&1 || die "required command not found: $cmd"
  done
}

# dictbuild_bin: build the release semicolyn-dictbuild tool (inside the dev container) and
# print its absolute path on stdout. Build chatter goes to stderr.
dictbuild_bin() {
  need swift
  swift build -c release --product semicolyn-dictbuild >&2
  local bin
  bin="$(swift build -c release --show-bin-path)/semicolyn-dictbuild"
  [ -x "$bin" ] || die "semicolyn-dictbuild not built at $bin"
  printf '%s\n' "$bin"
}

# pinned_ref <TLDR_REF|FIG_REF>: the default ref pinned in scripts/build-seed.sh, so the
# command dictionary and the legacy seed cannot drift apart.
pinned_ref() {
  local name="$1" value
  value="$(sed -n "s/^: \"\${${name}:=\(.*\)}\"\$/\1/p" scripts/build-seed.sh)"
  [ -n "$value" ] || die "cannot read the $name pin from scripts/build-seed.sh"
  printf '%s\n' "$value"
}

# file_bytes <file>: size in bytes.
file_bytes() {
  wc -c < "$1" | tr -d ' '
}

# gzip_bytes <file>: size in bytes after gzip -9 (the app-download size estimate).
gzip_bytes() {
  gzip -9 -c "$1" | wc -c | tr -d ' '
}
