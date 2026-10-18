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

# Pinned source refs for the command dictionary: the tldr-pages tag and the Fig
# autocomplete commit (the same pins the retired legacy seed used, so the evaluation text
# and the shipped dictionary come from one tldr snapshot).
DICT_TLDR_REF_PIN="v2.3"
DICT_FIG_REF_PIN="aef52acff84c45edde61ae610cc2c964802b9a38"

# pinned_ref <TLDR_REF|FIG_REF>: the default ref pinned above.
pinned_ref() {
  case "$1" in
    TLDR_REF) printf '%s\n' "$DICT_TLDR_REF_PIN" ;;
    FIG_REF) printf '%s\n' "$DICT_FIG_REF_PIN" ;;
    *) die "unknown pin: $1" ;;
  esac
}

# file_bytes <file>: size in bytes.
file_bytes() {
  wc -c < "$1" | tr -d ' '
}

# gzip_bytes <file>: size in bytes after gzip -9 (the app-download size estimate).
gzip_bytes() {
  gzip -9 -c "$1" | wc -c | tr -d ' '
}
