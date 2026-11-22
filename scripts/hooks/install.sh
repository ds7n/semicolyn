#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 True Positive LLC
# SPDX-License-Identifier: GPL-3.0-only
#
# Enable this repo's tracked pre-commit guard (scripts/hooks/pre-commit) and,
# optionally, seed a local-only personal-identifier overlay. Run once per fresh clone:
#   ./scripts/hooks/install.sh
#
# Installs a small shim at .git/hooks/pre-commit that runs the tracked script. It does
# NOT set core.hooksPath: pointing git at a tracked (writable) directory would let any
# hook added there (e.g. pre-push) run on push/fetch/pull, not just on commit.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
# The common dir is shared by all worktrees, so one shim covers every checkout.
hooks_dir="$(git rev-parse --git-common-dir)/hooks"
mkdir -p "$hooks_dir"

# Undo the old setup (core.hooksPath → scripts/hooks) if it is still configured.
if [[ "$(git config --local --get core.hooksPath || true)" == "scripts/hooks" ]]; then
    git config --local --unset core.hooksPath
    printf '\033[32m✓ removed core.hooksPath (old setup)\033[0m\n'
fi

shim="$hooks_dir/pre-commit"
marker="# semicolyn pre-commit shim"
if [[ -e "$shim" ]] && ! grep -qF "$marker" "$shim"; then
    printf '\033[31m✗ %s exists and is not our shim; leaving it alone\033[0m\n' "$shim" >&2
    exit 1
fi
# shellcheck disable=SC2016  # the $(...) is written literally into the shim
printf '#!/usr/bin/env bash\n%s (installed by scripts/hooks/install.sh)\nexec "$(git rev-parse --show-toplevel)/scripts/hooks/pre-commit" "$@"\n' \
    "$marker" > "$shim"
chmod +x "$shim"
printf '\033[32m✓ %s → scripts/hooks/pre-commit (junk-path guard active)\033[0m\n' "$shim"

# Seed the local overlay from the tracked template if the user doesn't have one.
overlay="$hooks_dir/pre-commit.local"
template="scripts/hooks/pre-commit.local.template"
if [[ ! -e "$overlay" && -e "$template" ]]; then
    cp "$template" "$overlay"
    chmod +x "$overlay"
    printf '\033[33m→ seeded %s (edit its `terms` list with your own name/paths)\033[0m\n' "$overlay"
else
    printf '   (local overlay already present or no template, skipping)\n'
fi
