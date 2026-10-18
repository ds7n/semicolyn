<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Architecture & spec map

The high-level overview and the index into the detailed specs/plans. For status & pending work see [TODO.md](../TODO.md); for the full decision log see [docs/brainstorming-decisions.md](brainstorming-decisions.md); for build/test gotchas see [CLAUDE.md](../CLAUDE.md).

## What it is

semicolyn is an **iOS / iPadOS SSH + mosh terminal client built for touch**: terminal work that feels native on a phone, with a context-aware key bar, a snippet launcher, **gesture-driven plain tmux** (windows and panes on SSH, Mosh and Eternal Terminal), an **on-device predictor** that learns your vocabulary, and security-first credential handling with end-to-end-encrypted sync. Open-source (GPL-3.0) with a cosmetic-only one-time Pro.

## Layering

```
┌─ Swift (SemicolynKit) ─ platform-agnostic, Linux-tested ─┐   ┌─ Apple-only (macOS-gated) ─┐
│  model · resolution · storage stack · tmux launch       │   │  SwiftUI · SwiftTerm        │
│  gesture engine · tmux bindings · predictor engine      │   │  Keychain/SE · CloudKit     │
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
| `Sources/SeedKit/`, `Sources/semicolyn-dictbuild/`, `Sources/semicolyn-predeval/` | Build-time predictor tooling: dictionary builders (English, commands) and the replay evaluation harness |
| `Tests/` | `SemicolynKitTests`, `SeedKitTests`, `BridgeTests` (macOS) |
| `docs/superpowers/specs/` | Per-subsystem locked design specs (one design each) |
| `docs/superpowers/plans/` | The roadmap + per-phase implementation plans |
| `docs/brainstorming-decisions.md` | Every locked decision, by topic, with the deferred list |
| `mockups/specs/`, `mockups/drafts/` | Locked visual record · pre-decision explorations |
| `scripts/` | `build-xcframework.sh`, `build-mosh-xcframework.sh`, `build-english-dict.sh`, `build-command-dict.sh`, `dict/` |
| `corpora/eval/` | Predictor evaluation text only (commands and prose replay); never shipped or used to build a dictionary |

## Spec map

Every v1 subsystem has a locked spec under [`docs/superpowers/specs/`](superpowers/specs/). Primary specs by area (the granular sub-spec families are noted where they exist):

**Connection & SSH** — `ssh-algorithms` (4-tier allowlist, PQC `mlkem768x25519` in Tier 1) · `host-key-trust` (TOFU + mismatch) · `ssh-cert-auth` · `chain-auth` (ProxyJump) · `pty-shell-channel` · `mosh-transport` (vendored `blinksh/mosh` → `Mosh.xcframework`, russh bootstrap → `MoshSession` bridge → SwiftTerm; M1–M4 shipped, on TestFlight; device feel-pass pending).

**Terminal & tmux**: `terminal-emulator-scope` (`xterm-256color`, OSC policy, mouse modes) · `terminal-ux-additions` (font zoom, URL tap, cursor, scrollback, resize) · `terminal-feedback` (bell halo + haptic, never sound) · `degraded-mode` (tmux ≥3.0, raw-PTY fallback) · `context-detection` · `tmux-session` · `phase-3c-terminal-ux-integration`. tmux is plain tmux driven by gestures (`single-gesture-engine`, `tmux-private-gesture-bindings`); the earlier `tmux-control-*` control-mode (`-CC`) family is superseded (see the 2026-10-18 entry in [brainstorming-decisions.md](brainstorming-decisions.md)).

**Input — keybar & keyboard** — `keybar-customization` (layout / gesture ownership) · `function-keys` (Fn / caps-lock SM) · `external-keyboard`.

**On-device predictor**: `2026-10-17-predictor-rework-design` is the current design: one engine (`PredictorEngine`, `SuggestionRanker`) scores every candidate on one scale from the shipped English dictionary, the command tree, learned words (CMS+Bloom rolling stores, `predictor-learned-store` / `-rolling-serialization`), screen words harvested from output (`predictor-output-harvesting`), bigram context and spelling corrections; `predictor-privacy-filter` and the secret-exclusion layers gate what is learned. Two dictionary files ship in `App/Resources/predictor/`: `english_v2.bin` (GDIC, words and word pairs with 1-byte scores) and `commands_v2.bin` (GCMT, a scored command, subcommand and flag tree), each with a `.provenance.txt` record and REUSE sidecar; attribution is in `SEED_ATTRIBUTION.md`. They are built by `scripts/build-english-dict.sh` and `scripts/build-command-dict.sh` (the `semicolyn-dictbuild` tool, inside the dev container) from sources fetched by `scripts/dict/fetch-sources.sh`; tldr pages held out by `TldrHoldout` give the command tree only their tool name, never their examples. `semicolyn-predeval` replays text through the engine (`replay -t <file> [-l] [-n 5] --english <f> --commands <f>`: keystrokes saved per 100, zero-suggestion rate, hits by slot, p95 latency); `tldr-eval` writes the held-out command lines (`corpora/eval/commands_eval.txt`), and `corpora/eval/dev_v1.txt` + `prompt_v1.txt` are the prose text. Suggestion-surface hygiene (typed-echo-only learning, chip clearing) is `2026-07-07-predictor-suggestion-hygiene-design`.

**Data, host model & sync** — `host-config-model` (schema, resolution, storage backbone) · `identities-keys-management` · `icloud-sync-scope` (what syncs vs stays local).

**UI, product & ship** — `host-crud` · `multi-connection-switching` · `banner-expanded` · `first-host-onboarding` · `settings-sub-screens` · `pro-paid-scope` · `ipad-scope` · `design-tokens` (theming) · `neon-midnight-theme` (the default theme) · `themed-ansi-palette-infra` (terminal ANSI-16 palette + strict derivation).

**Security, privacy & cross-cutting** — `screen-capture-protection` · `privacy-statement` · `testing-standards`.

## Plans & roadmap

Phases build bottom-up so each rests only on verified earlier work: **0** Foundations → **1** SSH core → **2** Storage & sync → **3** Terminal + tmux → **4** Keybar, input & predictor → **5** Host & identity UI → **6** Connection-management UI → **7** Settings, security & ship polish. Per-phase implementation plans (with exit criteria) are in [`docs/superpowers/plans/`](superpowers/plans/); the master is [`2026-06-17-semicolyn-implementation-roadmap.md`](superpowers/plans/2026-06-17-semicolyn-implementation-roadmap.md). Current state: [TODO.md](../TODO.md).
