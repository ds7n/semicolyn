#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 True Positive LLC
# SPDX-License-Identifier: GPL-3.0-only
#
# Build the shipped command dictionary (commands_v2.bin, GCMT) from the Fig autocomplete
# specs (structure) and tldr-pages examples (ranking), plus <name>.provenance.txt and REUSE
# sidecars. Prerequisite: scripts/dict/fetch-sources.sh (host) has cloned tldr and Fig into
# <sources>. Run inside the dev container:
#
#   docker compose run --rm dev scripts/build-command-dict.sh
#
# The provenance records the semicolyn commit it was built from (git inside the container, or
# SEMICOLYN_COMMIT when git cannot resolve it, e.g. in a worktree whose .git points outside the
# mount) and whether the builder sources were dirty.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/dict/common.sh
source scripts/dict/common.sh

usage() {
  cat << EOF
usage: scripts/build-command-dict.sh [options]

  -w, --work <dir>      work tree (default $DICT_WORK_DEFAULT)
  -s, --sources <dir>   fetch-sources.sh output (default <work>/sources)
  -o, --out <file>      output blob (default App/Resources/predictor/commands_v2.bin)
  -h, --help            show this help

Prints "BUILD OK commands tools=<n> nodes=<n> bytes=<n> gzip=<n>" on success.
EOF
}

work="$DICT_WORK_DEFAULT" sources="" out="App/Resources/predictor/commands_v2.bin"
while [ $# -gt 0 ]; do
  case "$1" in
    -w | --work) work="${2:?}"; shift 2 ;;
    -s | --sources) sources="${2:?}"; shift 2 ;;
    -o | --out) out="${2:?}"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done
[ -n "$sources" ] || sources="$work/sources"
for f in tldr.done fig.done manifest.txt; do
  [ -f "$sources/$f" ] || die "missing $sources/$f; run scripts/dict/fetch-sources.sh first"
done
case "$out" in *.bin) ;; *) die "--out must end in .bin: $out" ;; esac
need gzip
mkdir -p "$work/logs" "$(dirname "$out")"

self_sha="${SEMICOLYN_COMMIT:-$(git rev-parse HEAD 2> /dev/null || true)}"
[ -n "$self_sha" ] || die "cannot resolve the semicolyn commit; set SEMICOLYN_COMMIT=<sha>"
dirty="$(git status --porcelain -- Sources scripts Package.swift Package.resolved 2> /dev/null || true)"
if [ -n "$dirty" ]; then
  self_state="dirty builder sources: $(printf '%s' "$dirty" | awk '{print $2}' | tr '\n' ' ')"
else
  self_state="clean builder sources"
fi

tool="$(dictbuild_bin)"
"$tool" commands --tldr "$sources/tldr/pages" --fig "$sources/fig/src" -o "$out" \
  2>&1 | tee "$work/logs/commands-build.log"

tools="$(sed -n 's/^tools kept: //p' "$work/logs/commands-build.log")"
nodes="$(sed -n 's/^total nodes: //p' "$work/logs/commands-build.log")"
bytes="$(file_bytes "$out")"
gz="$(gzip_bytes "$out")"
base="${out%.bin}"
{
  echo "commands_v2 provenance (GCMT v1, built by scripts/build-command-dict.sh)"
  echo "built from semicolyn: $self_sha ($self_state)"
  echo "built at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "sources:"
  grep -E '^(tldr|fig)=' "$sources/manifest.txt" | sed 's/^/  /'
  echo "  tldr: pages/{common,linux,osx}; held-out eval pages give their tool name only, examples skipped (TldrHoldout)"
  echo "  fig: top-level src/*.ts specs"
  echo "build output:"
  sed 's/^/  /' "$work/logs/commands-build.log"
  echo "changes: reduced to a scored command, subcommand and flag tree"
  echo "size: $bytes bytes raw, $gz bytes gzip -9"
} > "$base.provenance.txt"

fig_license="$(find "$sources/fig" -maxdepth 1 -name 'LICENSE*' | head -n 1)"
[ -n "$fig_license" ] || die "no LICENSE file in $sources/fig"
{
  cat << 'EOF'
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-FileCopyrightText: tldr-pages contributors, CC BY 4.0
SPDX-FileCopyrightText: Copyright (c) 2021 Hercules Labs Inc. (Fig), MIT License
SPDX-License-Identifier: CC-BY-4.0 AND MIT

Derived command, subcommand and flag scores (GCMT): structure from Fig autocomplete specs
(MIT), ranking from tldr-pages examples (CC BY 4.0). Changes were made: reduced to command,
subcommand and flag frequency scores. See commands_v2.provenance.txt and SEED_ATTRIBUTION.md.

Fig autocomplete licence notice:

EOF
  cat "$fig_license"
} > "$out.license"
cat > "$base.provenance.txt.license" << 'EOF'
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only

Provenance record for the derived command dictionary; see SEED_ATTRIBUTION.md.
EOF

echo "BUILD OK commands tools=$tools nodes=$nodes bytes=$bytes gzip=$gz"
