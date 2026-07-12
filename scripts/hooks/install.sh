#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 True Positive LLC
# SPDX-License-Identifier: GPL-3.0-only
#
# Enable this repo's tracked git hooks (scripts/hooks/) and, optionally, seed a
# local-only personal-identifier overlay. Run once per fresh clone:
#   ./scripts/hooks/install.sh
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

git config core.hooksPath scripts/hooks
printf '\033[32m✓ core.hooksPath → scripts/hooks (pre-commit junk-path guard active)\033[0m\n'

# Seed the local overlay from the tracked template if the user doesn't have one.
# Use the real .git dir (NOT --git-path hooks/…, which follows core.hooksPath).
overlay="$(git rev-parse --git-dir)/hooks/pre-commit.local"
template="scripts/hooks/pre-commit.local.template"
if [[ ! -e "$overlay" && -e "$template" ]]; then
    cp "$template" "$overlay"
    chmod +x "$overlay"
    printf '\033[33m→ seeded %s (edit its `terms` list with your own name/paths)\033[0m\n' "$overlay"
else
    printf '   (local overlay already present or no template — skipping)\n'
fi
