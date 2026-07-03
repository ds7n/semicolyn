<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Architecture & spec map

The high-level overview and the index into the detailed specs/plans. For status & pending work see [TODO.md](../TODO.md); for the full decision log see [docs/brainstorming-decisions.md](brainstorming-decisions.md); for build/test gotchas see [CLAUDE.md](../CLAUDE.md).

## What it is

semicolyn is an **iOS / iPadOS SSH + mosh terminal client built for touch** — terminal work that feels native on a phone: a context-aware key bar, a snippet launcher, **tmux control mode** driving persistent native tabs/panes, an **on-device predictor** that learns your vocabulary, and security-first credential handling with end-to-end-encrypted sync. Open-source (GPL-3.0) with a cosmetic-only one-time Pro.

## Layering

```
┌─ Swift (SemicolynKit) ─ platform-agnostic, Linux-tested ─┐   ┌─ Apple-only (macOS-gated) ─┐
│  model · resolution · storage stack · tmux -CC          │   │  SwiftUI · SwiftTerm        │
│  parser/model/encoder/controller · predictor engine     │   │  Keychain/SE · CloudKit     │
└───────────────────────────┬─────────────────────────────┘   └──────────────┬─────────────┘
                            UniFFI XCFramework bridge ────────────────────────┘
┌───────────────────────────┴──────────────────────────┐
│  Rust (crates/semicolyn-ssh-core) — russh, aws-lc-rs   │
│  handshake · auth · PTY · forwards · ProxyJump        │
└───────────────────────────────────────────────────────┘
```

The design keeps the **Apple-only UI/SDK layer thin** so the maximum surface stays Linux-testable. Decision logic lives in `Sources/SemicolynKit/` (pure, XCTest on the Linux fast loop); the Rust SSH core is exposed through a UniFFI XCFramework; only SwiftUI/SwiftTerm/Keychain/CloudKit wiring is Apple-gated. Crypto goes through swift-crypto on Linux and system CryptoKit on Apple behind `#if canImport(CryptoKit)`. (The two-tier rule and its build/test consequences: [CLAUDE.md](../CLAUDE.md).)

## Repository layout

| Path | Contents |
|---|---|
| `App/` + `project.yml` | iOS app target (SwiftUI MVP); `project.yml` is the XcodeGen manifest |
| `crates/semicolyn-ssh-core/` | Rust SSH core (russh) exposed to Swift via UniFFI |
| `Sources/SemicolynKit/` | Platform-agnostic Swift: `Model/`, `Storage/`, `Crypto/`, `Tmux/`, `Predictor/`, `Theme/`, `Terminal/`, `IO/` |
| `Sources/SeedKit/`, `Sources/semicolyn-seedbuild/` | Build-time predictor-seed ingestion (tldr-pages + Fig specs) |
| `Tests/` | `SemicolynKitTests`, `SeedKitTests`, `BridgeTests` (macOS) |
| `docs/superpowers/specs/` | Per-subsystem locked design specs (one design each) |
| `docs/superpowers/plans/` | The roadmap + per-phase implementation plans |
| `docs/brainstorming-decisions.md` | Every locked decision, by topic, with the deferred list |
| `mockups/specs/`, `mockups/drafts/` | Locked visual record · pre-decision explorations |
| `scripts/` | `build-xcframework.sh`, `build-mosh-xcframework.sh`, `build-seed.sh` |

## Spec map

Every v1 subsystem has a locked spec under [`docs/superpowers/specs/`](superpowers/specs/). Primary specs by area (the granular sub-spec families are noted where they exist):

**Connection & SSH** — `ssh-algorithms` (4-tier allowlist, PQC `mlkem768x25519` in Tier 1) · `host-key-trust` (TOFU + mismatch) · `ssh-cert-auth` · `chain-auth` (ProxyJump) · `pty-shell-channel` · `mosh-transport` (vendored `blinksh/mosh` → `Mosh.xcframework`, russh bootstrap → `MoshSession` bridge → SwiftTerm; M1+M2+M3 shipped, M4 pending).

**Terminal & tmux** — `terminal-emulator-scope` (`xterm-256color`, OSC policy, mouse modes) · `terminal-ux-additions` (font zoom, URL tap, cursor, scrollback, resize) · `terminal-feedback` (bell halo + haptic, never sound) · `degraded-mode` (tmux ≥3.0, raw-PTY fallback) · `context-detection` · `tmux-session` + the `tmux-control-channel` / `-control-mode-parser` / `-command-encoder` / `-session-model` / `-session-controller` family · `phase-3c-terminal-ux-integration`.

**Input — keybar & keyboard** — `keybar-customization` (layout / gesture ownership) · `function-keys` (Fn / caps-lock SM) · `external-keyboard`.

**On-device predictor** — `predictor-design` is the overview; **16 component specs** (`predictor-core-sketches`, `-prefix-ranking`, `-bigram-next-token`, `-candidate-aggregate`, `-daily-rollover`, `-bigram-rollover`, `-seed-deference`/`-seed-ingestion`/`-seed-runtime-load`, `-fig-ingestion`, `-output-harvesting`, `-privacy-filter`, `-learned-store`, `-engine`, `-rolling-serialization`, `-vocab-serialization`) cover the CMS+Bloom vocabulary, ranking, rollover, ingestion, and privacy.

**Data, host model & sync** — `host-config-model` (schema, resolution, storage backbone) · `identities-keys-management` · `icloud-sync-scope` (what syncs vs stays local).

**UI, product & ship** — `host-crud` · `multi-connection-switching` · `banner-expanded` · `first-host-onboarding` · `settings-sub-screens` · `pro-paid-scope` · `ipad-scope` · `design-tokens` (theming) · `neon-midnight-theme` (the default theme) · `themed-ansi-palette-infra` (terminal ANSI-16 palette + strict derivation).

**Security, privacy & cross-cutting** — `screen-capture-protection` · `privacy-statement` · `testing-standards`.

## Plans & roadmap

Phases build bottom-up so each rests only on verified earlier work: **0** Foundations → **1** SSH core → **2** Storage & sync → **3** Terminal + tmux → **4** Keybar, input & predictor → **5** Host & identity UI → **6** Connection-management UI → **7** Settings, security & ship polish. Per-phase implementation plans (with exit criteria) are in [`docs/superpowers/plans/`](superpowers/plans/); the master is [`2026-06-17-semicolyn-implementation-roadmap.md`](superpowers/plans/2026-06-17-semicolyn-implementation-roadmap.md). Current state: [TODO.md](../TODO.md).
