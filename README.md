# Glymr

[![CI](https://github.com/ds7n/glymr/actions/workflows/ci.yml/badge.svg)](https://github.com/ds7n/glymr/actions/workflows/ci.yml)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0--only-blue.svg)](LICENSE)
![Platform: iOS / iPadOS](https://img.shields.io/badge/platform-iOS%20%7C%20iPadOS-lightgrey.svg)

**An iOS SSH / mosh terminal client built for touch.** Glymr's wager is that
terminal work can feel native on a phone: a context-aware key bar, a smart
snippet launcher, tmux control mode driving persistent native tabs and panes,
an on-device predictor that learns your vocabulary, and security-first
credential handling with end-to-end-encrypted sync.

> The name **Glymr** is Old Norse for *"echo, resonance, ringing sound"* — what
> the predictor does (echoes your vocabulary back) and what a remote command
> does (rings across distance to another shell).

---

## Status

**Design complete; implementation underway. A connect-and-get-a-shell MVP now
builds for the iOS Simulator** (not yet installable on a device — that needs an
Apple Developer account for signing). The protocol and logic layers — the parts
that are hard to get right — are built and tested on a Linux fast loop; the app
shell (iOS target, UniFFI bridge wiring, terminal rendering, UI) is now started
and validated by macOS CI. See [docs/mvp-app-testing.md](docs/mvp-app-testing.md)
to build and run it.

| Phase | Scope | State |
|---|---|---|
| **0 — Foundations** | Cargo + SwiftPM workspace, UniFFI bridge proof, design tokens, data model, AES-256-GCM record envelope | ✅ Done |
| **1 — SSH core** | russh behind UniFFI: handshake, host-key TOFU, auth (password / publickey / keyboard-interactive), OpenSSH cert auth, PTY shell, local/remote/dynamic forwards, ProxyJump, 4-tier algorithm allowlist | ✅ Done¹ |
| **2a — Storage core** | Full host/identity schema + resolution table; `BlobStore`→`EncryptedRecordStore`, `SecretStore`, `HostKeyStore`; repository invariants; sync taxonomy | ✅ Done |
| **2b-i — Key minting** | ed25519 key generation + OpenSSH-key import in the Rust core; `IdentityService` (mint→Keychain→metadata); `CoreIdentityMinter` bridge; publickey connect from a stored identity | ✅ Done (iCloud-Keychain flavor) |
| **2b-ii — Sync + SE** | CloudKit Private DB + sync engine, Secure-Enclave flavor (`SecAccessControl` + russh→SE signing bridge) | ⏳ enrollment-gated |
| **3 — Terminal + tmux** | `tmux -CC` parser, session/pane model, command encoder, controller, Rust transport (all done²); **Plans A+B done**: `tmux -V` probe → attach `tmux -CC`, render the window's **native pane layout** (one SwiftTerm view per leaf pane, active-pane bronze border), **switch windows** via a tab strip, resize via `refresh-client -C`; else degrade to raw PTY with an amber banner. UX polish — bell/mouse/font/URL/OSC (C), context-SM + crash banner (D) — pending | ◐ Multi-pane + multi-window live; UX polish pending |
| **4 — Keybar, input & predictor** | On-device predictor: CMS + Bloom vocabulary, prefix + bigram ranking, daily rollover, seed deference, write-time privacy filter, output harvesting, engine facade (all done); keybar UI + app-edge wiring | ◐ Engine done, UI macOS-gated |
| **MVP app shell** | iOS app target (XcodeGen) + SwiftTerm wired to the Rust core via UniFFI: connect → password auth → raw-PTY shell, with real host-key TOFU trust (Keychain-backed). Password / keyboard-interactive / **publickey** auth (from a minted or imported iCloud-Keychain identity); cert connect + Secure-Enclave signing pending 2b-ii | ✅ Builds for Simulator |
| **5–7 — UI & ship** | Host CRUD UI — saved-host library (empty state + list), single-form host editor (full OpenSSH + Glymr config, save-time validation), Defaults editor, inline identity picker (pick-existing + **create/import** half-sheet), connect-from-saved (done); standalone Identities & Keys management, connection-management UI, settings, IAP, App Store polish (pending) | ◐ Host CRUD + identity create/import done, rest macOS-gated |

¹ The `ssh-ed25519-cert-v01@openssh.com` *host* certificate variant is deferred —
blocked on russh 0.61, which verifies the server host key only as a plain
`PublicKey` (no CA / principal / validity path). A guard test prevents
advertising it until upstream support lands.
² The control-mode stack is verified against real `tmux` in the `sshd` fixture,
including the DCS-wrapped (`ESC P1000p … ESC \`) live `-CC` stream.

**Tests green:** 9 Rust unit + 34 Rust integration (vs containerized `sshd`) +
459 Swift (GlymrKit + SeedKit). All run on the Linux fast loop.

## What makes it different

- **Touch-native terminal UX** — context-aware key bar (locked-left + scroll,
  fused Esc pill, arrow Pad, sticky/lockable modifiers), iOS-native selection and
  a delta-drag cursor halo instead of a joystick.
- **tmux control mode as the session engine** — `tmux -CC` gives real native
  tabs and panes (not a screen-scraped TUI), with a raw-PTY degraded fallback.
- **On-device predictor** — learns your command vocabulary with Count-Min Sketch
  + Bloom filters (a lossy frequency fingerprint, never recoverable text),
  defers to a bundled seed per-prefix, and harvests just-seen tokens from command
  output. Write-time privacy filter keeps secrets out of the model.
- **Security-first, zero-telemetry** — no analytics, crash reporting, ads, or
  third-party SDKs. Keys live in iCloud Keychain or Secure Enclave; CloudKit
  records are client-side AES-256-GCM so Apple sees only ciphertext.
- **Post-quantum SSH** — `mlkem768x25519` PQC key exchange in the Tier-1 allowlist.
- **Open-source + one-time Pro** — GPL-3.0; Pro is cosmetic-only (no feature paywall).

## Architecture

```
┌─ Swift (GlymrKit) ─ platform-agnostic, Linux-tested ─┐   ┌─ Apple-only (macOS-gated) ─┐
│  model · resolution · storage stack · tmux -CC       │   │  SwiftUI · SwiftTerm        │
│  parser/model/encoder/controller · predictor engine  │   │  Keychain/SE · CloudKit     │
└───────────────────────────┬──────────────────────────┘   └──────────────┬─────────────┘
                            UniFFI XCFramework bridge ───────────────────────┘
┌───────────────────────────┴──────────────────────────┐
│  Rust (crates/glymr-ssh-core) — russh, aws-lc-rs      │
│  handshake · auth · PTY · forwards · ProxyJump        │
└───────────────────────────────────────────────────────┘
```

The design keeps the Apple-only UI/SDK layer thin so the maximum surface stays
Linux-testable. Crypto goes through swift-crypto on Linux and system CryptoKit on
Apple behind `#if canImport(CryptoKit)`. Full rationale and the
dependency-ordered phase plan:
[`docs/superpowers/plans/2026-06-17-glymr-implementation-roadmap.md`](docs/superpowers/plans/2026-06-17-glymr-implementation-roadmap.md).

## Building & testing

The platform-agnostic tier runs in a Docker dev image (Swift 6.1 + Rust) — no
Mac required:

```bash
docker compose build dev
docker compose run --rm dev swift test                 # GlymrKit + SeedKit
docker compose up -d sshd sshd-legacy                   # SSH fixtures for integration tests
docker compose run --rm dev cargo test -p glymr-ssh-core
```

The Apple-gated tier needs macOS + Xcode (also run in CI on macOS runners):

```bash
swift build --target GlymrKit          # compiles under system CryptoKit
bash scripts/build-xcframework.sh      # Rust core → all iOS triples → UniFFI XCFramework
xcodegen generate                      # project.yml → Glymr.xcodeproj (brew install xcodegen)
open Glymr.xcodeproj                    # run the MVP app in the iOS Simulator
```

See [docs/mvp-app-testing.md](docs/mvp-app-testing.md) for running the app and
connecting to a host.

CI (`.github/workflows/ci.yml`) runs all of the above: the Linux fast loop on
every push/PR, plus a macOS job that builds the XCFramework (validating
`aws-lc-rs` across the three iOS triples) and builds the app for the iOS Simulator.

## Repository layout

| Path | Contents |
|---|---|
| `App/` + `project.yml` | iOS app target (SwiftUI MVP); `project.yml` is the XcodeGen manifest |
| `crates/glymr-ssh-core/` | Rust SSH core (russh) exposed to Swift via UniFFI |
| `Sources/GlymrKit/` | Platform-agnostic Swift: `Model/`, `Storage/`, `Crypto/`, `Tmux/`, `Predictor/`, `Theme/` |
| `Sources/SeedKit/`, `Sources/glymr-seedbuild/` | Build-time predictor-seed ingestion (tldr-pages + Fig specs) |
| `Tests/` | `GlymrKitTests`, `SeedKitTests`, `BridgeTests` (macOS) |
| `docs/superpowers/specs/` | Per-subsystem design specs (one locked design each) |
| `docs/superpowers/plans/` | The roadmap + per-phase implementation plans |
| `docs/brainstorming-decisions.md` | Every locked decision, by topic, with the deferred list |
| `mockups/specs/`, `mockups/drafts/` | Locked visual record · pre-decision explorations |
| `scripts/` | `build-xcframework.sh`, `build-seed.sh` |

## Design specs

Every v1 subsystem has a locked spec under `docs/superpowers/specs/`. The index
below links each; the canonical decision log is
[`docs/brainstorming-decisions.md`](docs/brainstorming-decisions.md).

**Connection & SSH**
- SSH algorithm allowlist (4-tier closed set; PQC in Tier 1) — `2026-06-17-ssh-algorithms-design.md`
- Host-key trust UX (TOFU + mismatch handling) — `2026-06-17-host-key-trust-design.md`
- SSH certificate auth — `2026-06-17-ssh-cert-auth-design.md`
- Jump-host chain authentication — `2026-06-17-chain-auth-design.md`

**Terminal & tmux**
- Terminal emulator scope (`xterm-256color`, OSC policy, mouse modes) — `2026-06-17-terminal-emulator-scope-design.md`
- Terminal UX additions (font zoom, URL tap, cursor, scrollback, resize) — `2026-06-17-terminal-ux-additions-design.md`
- Terminal feedback (bell halo + haptic, never sound) — `2026-06-17-terminal-feedback-design.md`
- Degraded mode & tmux requirements (≥3.0, raw-PTY fallback) — `2026-06-14-degraded-mode-design.md`
- Context detection (per-pane foreground process → keybar promotions) — `2026-06-14-context-detection-design.md`
- tmux session naming + multi-device — `2026-06-17-tmux-session-design.md`

**Input — keybar & predictor**
- Keybar layout / customization / gesture ownership — `2026-06-15-keybar-customization-design.md`
- Function keys (Fn mode, caps-lock state machine) — `2026-06-14-function-keys-design.md`
- External keyboard support (real modifiers, Cmd-shortcut map) — `2026-06-17-external-keyboard-design.md`
- Predictor (CMS + Bloom, seed deference, privacy) — `2026-06-13-predictor-design.md`

**Data & sync**
- Host config model (schema, resolution, storage backbone) — `2026-06-15-host-config-model-design.md`
- Identities & Keys management — `2026-06-15-identities-keys-management-design.md`
- iCloud sync scope (what syncs vs stays local) — `2026-06-16-icloud-sync-scope-design.md`

**UI, product & ship**
- Host CRUD flow — `2026-06-15-host-crud-design.md`
- Multi-connection switching semantics — `2026-06-15-multi-connection-switching-design.md`
- Connection-status banner (transient + expanded) — `2026-06-16-banner-expanded-design.md`
- First-host onboarding & Tips & Gestures — `2026-06-16-first-host-onboarding-design.md`
- Settings sub-screens — `2026-06-16-settings-sub-screens-design.md`
- Pro / paid scope — `2026-06-16-pro-paid-scope-design.md`
- iPad scope — `2026-06-17-ipad-scope-design.md`
- Design tokens / theming — `2026-06-17-design-tokens-design.md`
- Screen-capture protection — `2026-06-17-screen-capture-protection-design.md`
- Privacy statement — `2026-06-17-privacy-statement-design.md`

## Roadmap

Phases build bottom-up so each rests only on verified earlier work: **0**
Foundations → **1** SSH core → **2** Storage & sync → **3** Terminal + tmux →
**4** Keybar, input & predictor → **5** Host & identity UI → **6** Connection
management UI → **7** Settings, security & ship polish. See the
[implementation roadmap](docs/superpowers/plans/2026-06-17-glymr-implementation-roadmap.md)
for exit criteria and per-phase plans.

## Contributing

This is an early-stage solo project with a locked, spec-driven design. If you
want to get oriented: read this README, then `docs/brainstorming-decisions.md`,
then the relevant spec before any code. The platform-agnostic tier (`crates/`,
`Sources/GlymrKit/`) is fully buildable and testable on Linux via the Docker
commands above — start there. Issues and discussion are welcome; please open an
issue before a large PR so it can be checked against the locked specs.

## License

[GPL-3.0-only](LICENSE), copyright **True Positive LLC**, plus an
[`LICENSE.IOS`](LICENSE.IOS) App Store covenant (the open-source-plus-paid-Pro
model, following Blink's precedent). Source files carry SPDX headers and the
project is REUSE-compliant.
