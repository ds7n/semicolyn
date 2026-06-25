<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# CLAUDE.md — working in this repo

neotilde is an **iOS SSH/mosh terminal client**. Rust SSH core (`crates/neotilde-ssh-core`, russh) → UniFFI XCFramework → Swift. The Swift splits into a **platform-agnostic, Linux-tested** tier (`Sources/NeotildeKit/`) and a **thin Apple/UI** tier (`App/`, SwiftUI + SwiftTerm).

> Orientation: **what/why** → [README.md](README.md) · **architecture + the spec/plan map** → [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) · **status + what's next** → [TODO.md](TODO.md) · **every locked decision** → [docs/brainstorming-decisions.md](docs/brainstorming-decisions.md).

## The one rule that explains most gotchas

**Two tiers, two test surfaces:**
- **`Sources/NeotildeKit/` + `crates/` = pure logic, Linux-tested.** Swift 6 strict-concurrency, `Sendable`, **no `import UIKit`/`SwiftUI`/`CryptoKit`** (crypto goes through swift-crypto on Linux / CryptoKit on Apple behind `#if canImport(CryptoKit)`). This is where decision logic lives, mirroring the `tmuxLaunchDecision`-pure pattern.
- **`App/` + anything `#if canImport(SwiftUI)` (e.g. `ThemeEnvironment.swift`) + the UniFFI bridge + xcframework + xcodegen = Apple-only, macOS-CI-verified.** **They do NOT compile on Linux and are invisible to `swift test`.** App-target compile errors only surface on the macOS CI job. So: put logic in NeotildeKit with XCTest; keep App code a thin wiring layer; expect to validate App changes via CI, not locally.

## Build & test (there is NO Swift toolchain on the host)

Linux Swift + Rust run in the **Docker dev image `neotilde-dev`** (Swift 6.1 + Rust). Pass the host UID/GID so lockfiles stay editable:

```bash
docker compose build dev
HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test            # NeotildeKit + SeedKit
docker compose up -d sshd sshd-legacy                                                  # SSH fixtures
HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p neotilde-ssh-core
# focused: ... swift test --filter ThemeTests
```

- **`cargo` IS on the host**, but `target/` is root-owned (written by the container) → on the host use `CARGO_TARGET_DIR=/tmp/neotilde-target cargo test -p neotilde-ssh-core --lib` (lib/unit tests need no sshd). Integration tests need the `sshd`/`sshd-legacy` containers + the `NEOTILDE_TEST_SSHD*` env (set in `docker-compose.yml`).
- **Apple tier** (xcframework, app, BridgeTests) needs macOS + Xcode → only the **macOS CI job** validates it locally-unbuildable code. `scripts/build-xcframework.sh` (Rust → all iOS triples → UniFFI), `xcodegen generate` (`project.yml` → `.xcodeproj`).

## Remotes & CI

- **`github`** → `https://github.com/ds7n/neotilde` (**public**) runs CI on **push to `main` or any PR**. **`origin`** → Forgejo mirror (`forgejo:gitadmin/neotilde.git`, SSH alias, local-only).
- The **`macos` CI job (~15–18 min, the iOS `aws-lc-rs` compile)** is the **only** build/test signal for Apple-gated code. `linux-swift`/`linux-rust`/`lint` are the fast loop.
- **`linux-rust` occasionally flakes** with `sshd fixtures not reachable after 30s` (a compose-DNS readiness race, hardened but not eliminated) — it's not a real failure on a non-Rust change; **just rerun the failed job** (`gh run rerun <id> --failed`).

## Conventions

- **Specs are locked.** Read the relevant `docs/superpowers/specs/*-design.md` before touching a subsystem; the decision log is `docs/brainstorming-decisions.md`. Index: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
- **Tests must be real** — `docs/superpowers/specs/2026-06-18-testing-standards-design.md`: equivalence-partitioning + boundary values, assert observable values (no tautologies), a negative test asserts the *specific* failure.
- **Every source file carries an SPDX header** (`GPL-3.0-only`, © True Positive LLC); the repo is REUSE-compliant.
- **Conventional commits** (`feat:`/`fix:`/`refactor:`/`docs:`/…); feature branch per phase; **squash-merge** to `main`.
- `data/` and `.env` are gitignored; never commit secrets. `/.superpowers/` (agent scratch) is gitignored.
