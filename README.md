# Semicolyn

[![CI](https://github.com/ds7n/semicolyn/actions/workflows/ci.yml/badge.svg)](https://github.com/ds7n/semicolyn/actions/workflows/ci.yml)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0--only-blue.svg)](LICENSE)
![Platform: iOS / iPadOS](https://img.shields.io/badge/platform-iOS%20%7C%20iPadOS-lightgrey.svg)

**An iOS SSH / mosh terminal client built for touch.** Semicolyn's wager is that
terminal work can feel native on a phone: a context-aware key bar, a smart
snippet launcher, gestures that drive plain tmux windows and panes on every
transport, an on-device predictor that learns your vocabulary, and security-first
credential handling with end-to-end-encrypted sync.

> The name **semicolyn** is a respell of *semicolon*, the `;` that chains one
> shell command into the next. The everyday punctuation of the command line,
> reimagined for touch.

**Status:** design complete; a connect-and-get-a-shell MVP (SSH + mosh, password
and publickey auth) builds for the iOS Simulator and is now **on TestFlight**,
the macOS CI runner archives, signs, and uploads a device-installable build. The
protocol + logic tiers are built and Linux-tested; the app shell is built and
validated by macOS CI.
→ **Architecture:** [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

## What makes it different

- **Touch-native terminal UX**, context-aware key bar (locked-left + scroll,
  fused Esc pill, arrow Pad, sticky/lockable modifiers), iOS-native selection and
  a delta-drag cursor halo instead of a joystick.
- **Gesture-driven tmux**: plain tmux on SSH, Mosh and Eternal Terminal, driven
  by swipes, taps, long-presses and hardware-keyboard shortcuts through private
  key bindings (your own tmux keys stay untouched), with a raw-shell fallback
  when tmux is missing or turned off.
- **On-device predictor**, learns your command vocabulary with Count-Min Sketch
  + Bloom filters (a lossy frequency fingerprint, never recoverable text),
  ranks it with bundled English and command dictionaries, and harvests just-seen
  tokens from command output. Write-time privacy filter keeps secrets out of the model.
- **Security-first, zero-telemetry**, no analytics, crash reporting, ads, or
  third-party SDKs. Keys live in iCloud Keychain or Secure Enclave; CloudKit
  records are client-side AES-256-GCM so Apple sees only ciphertext.
- **Post-quantum SSH**, `mlkem768x25519` PQC key exchange in the Tier-1 allowlist.
- **Open-source + one-time Pro**, GPL-3.0; Pro is cosmetic-only (no feature paywall).

## Architecture

A Rust SSH core (`crates/semicolyn-ssh-core`, russh) is exposed to Swift through a
UniFFI XCFramework. The Swift splits into a **platform-agnostic, Linux-tested**
tier (`Sources/SemicolynKit/`: model, storage, tmux launch and gestures, predictor) and
a **thin Apple-gated** tier (`App/`, SwiftUI, SwiftTerm, Keychain/SE, CloudKit),
so the maximum surface stays testable off-Mac. Full diagram, rationale, repo
layout, and the spec/plan map: **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**.

## Quickstart

The platform-agnostic tier runs in a Docker dev image (Swift 6.1 + Rust), no
Mac required:

```bash
docker compose build dev
docker compose run --rm dev swift test                 # SemicolynKit + SeedKit
docker compose up -d sshd sshd-legacy                   # SSH fixtures for integration tests
docker compose run --rm dev cargo test -p semicolyn-ssh-core
```

The Apple-gated tier (XCFramework + iOS app) needs macOS + Xcode and is also run
in CI on macOS runners; see [docs/mvp-app-testing.md](docs/mvp-app-testing.md) to build and run the app.

## Contributing

Early-stage solo project with a locked, spec-driven design. To get oriented:
read this README, then [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and
[docs/brainstorming-decisions.md](docs/brainstorming-decisions.md) before any code. The platform-agnostic tier (`crates/`,
`Sources/SemicolynKit/`) is fully buildable and testable on Linux via the
quickstart above, start there. Please open an issue before a large PR so it can be
checked against the locked design.

## License

[GPL-3.0-only](LICENSE), copyright **True Positive LLC**, plus an
[`LICENSE.IOS`](LICENSE.IOS) App Store covenant (the open-source-plus-paid-Pro
model, following Blink's precedent). Source files carry SPDX headers and the
project is REUSE-compliant.
