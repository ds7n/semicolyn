#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 True Positive LLC
# SPDX-License-Identifier: GPL-3.0-only
#
# Regenerate App/Resources/Licenses/Rust-libraries.txt: every crate linked into the
# iOS build of crates/semicolyn-ssh-core, with its version, licence and full licence
# text. Shown on About > Acknowledgements > "Rust libraries".
#
# Needs cargo-about (`cargo install cargo-about --locked --features cli`) and network
# access (crates.io, plus GitHub for crates that ship no licence file). Targets,
# accepted licences and ignores live in about.toml at the repo root.
#
# Run after any Cargo.lock change and commit the result.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${repo_root}/App/Resources/Licenses/Rust-libraries.txt"

if ! cargo about --version >/dev/null 2>&1; then
    echo "error: cargo-about not found; install it with: cargo install cargo-about --locked --features cli" >&2
    exit 1
fi

# target/ in the repo is written by the dev container (root-owned); keep any build
# output cargo metadata needs out of it.
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-${TMPDIR:-/tmp}/semicolyn-target}"

cargo about generate \
    --config "${repo_root}/about.toml" \
    --manifest-path "${repo_root}/Cargo.toml" \
    --locked \
    --output-file "${out}" \
    "${repo_root}/scripts/rust-licences.hbs"

echo "wrote ${out}"
