# Semicolyn Implementation Roadmap

> **For agentic workers:** This is the **top-level roadmap** — it sequences the
> ~25 locked design specs into dependency-ordered phases. It is NOT a bite-sized
> task plan. Each phase gets its own detailed plan (see
> `docs/superpowers/plans/`) written with `superpowers:writing-plans` when that
> phase is next. Phase 0 is already detailed:
> `2026-06-17-phase-0-foundation.md`.

**Goal:** Ship Semicolyn v1 — an iOS SSH/mosh client with a tmux-control-mode session
engine, context-aware keybar, on-device predictor, and security-first credential
handling — building up from a verified foundation in dependency order.

**Architecture:** A Rust SSH core (`russh`) is bridged to Swift via a thin
UniFFI binding and consumed by a SwiftUI app. `tmux -CC` control mode runs over
the SSH channel; a Swift-side protocol parser turns its event stream into a
native pane model rendered with SwiftUI/UIKit. Secrets live in iCloud
Keychain / Secure Enclave; host metadata lives in CloudKit Private DB under
client-side AES-256-GCM.

**Tech Stack:** Swift 6 / SwiftUI, Rust (`russh` 0.61+, `tokio`, UniFFI 0.31+),
SwiftTerm (terminal emulator — see Decision D1), CryptoKit / swift-crypto (the
Linux-testable shim), CloudKit, Keychain Services, Secure Enclave. **Licensed
GPL-3.0-only** (+ `LICENSE.IOS` covenant). CI on GitHub Actions macOS runners.

---

## Locked stack decisions (2026-06-17)

| Decision | Choice | Rationale / evidence |
|---|---|---|
| **SSH stack** | **russh** (Rust, Apache-2.0, v0.61.2) | Only actively-maintained stack with `mlkem768x25519` + OpenSSH cert auth + full per-category algorithm control + all forward types. Compiles for iOS today (cryptovec fix PR #483; aws-lc-rs ≥1.14 or `ring` backend). |
| **Swift↔Rust bridge** | **UniFFI 0.31+** with `#[uniffi::export(async_runtime = "tokio")]` | Full async→Swift `async/await` mapping; ships XCFramework tooling; proven by prior art (nikhilsh/conduit, jowparks/server-remote). No reusable russh→Swift binding exists — we build a thin one (~12–20 methods). |
| **Rust crypto backend** | **aws-lc-rs** (pin `aws-lc-sys` ≥ 0.39.0) | Required for `mlkem768x25519` — **`ring` has no ML-KEM**, so it would forfeit the PQC that motivated russh. aws-lc-rs became **GPL-3-compatible** when AWS-LC relicensed its OpenSSL-derived sources to Apache-2.0 (PR #3091, 2026-03-11), so the earlier license-driven lean toward `ring` no longer applies. Enforce with a `cargo deny` license gate (assert no `OpenSSL`-tagged crate). iOS-sim bindgen fix landed v1.14.0; FIPS unsupported on iOS — use non-FIPS. `ring` is a fallback only if aws-lc-rs blocks the iOS build (accepting loss of ML-KEM → re-opens D2). |
| **Terminal emulator** | **SwiftTerm** (recommended — see Decision D1) | Maps ~1:1 to `terminal-emulator-scope-design`: xterm-256, truecolor, SGR mouse modes, DECSCUSR, OSC. Confirm before Phase 3. |
| **License** | **GPL-3.0-only** + `LICENSE.IOS` covenant | Matches the one proven open-source-**and**-paid precedent in this category (Blink); as sole copyright holder you dual-distribute (GPL source for self-builders + paid App Store binary). All deps are GPL-3-compatible (russh Apache-2.0, UniFFI MPL-2.0, SwiftTerm MIT, swift-crypto Apache-2.0). iSH-style `LICENSE.IOS` non-enforcement covenant resolves the GPL-vs-App-Store ToS tension. |
| **Build & CI host** | **GitHub Actions macOS runners** + local Swift-Linux/swift-crypto fast loop | iOS build/test needs macOS (Apple SDK is EULA-bound to Apple hardware; no iOS Simulator on Linux). GHA macOS is **free & unlimited on a public repo**, with full arbitrary shell for the Rust→UniFFI→xcframework→`swift test` pipeline. The Linux box runs the platform-agnostic tier (Rust core, data model, crypto via swift-crypto) for fast TDD. Xcode Cloud reserved for TestFlight/App Store **delivery** later (needs a one-time Mac to onboard + an app target). |

## Open decisions to resolve before their phase

- **D1 — Terminal emulator (before Phase 3):** SwiftTerm vs roll-own. Recommend
  SwiftTerm. Not yet user-confirmed.
- **D2 — `sntrup761x25519` gap (before Phase 1 ships):** russh has
  `mlkem768x25519` but **not** `sntrup761x25519` (russh issue #626). The
  Tier-1 allowlist in `ssh-algorithms-design.md` lists both. Options: (a) wait
  for upstream, (b) contribute it to russh, (c) amend the spec to make sntrup761
  opportunistic. Decide before declaring Tier-1 complete.
- **D3 — CloudKit container provisioning (before Phase 2):** needs an Apple
  Developer account ($99/yr) + iCloud container identifier. Procurement, not
  engineering. (Same $99 account also unlocks Xcode Cloud's 25 free hrs for
  delivery and is required for App Store signing.)
- **D4 — aws-lc-rs iOS build (before Phase 1 ships):** confirm aws-lc-rs builds
  for all three iOS triples in GHA. If it blocks, the only fallback (`ring`)
  drops ML-KEM — which re-opens D2's PQC question. Verify early in the Phase-1
  spike.

**Resolved:** repo privacy/history scrubbed clean (commit-author domain, sample
handle, internal IPs rewritten across all history; force-pushed 2026-06-17) — so
flipping the repo public is unblocked whenever the open-source launch is wanted.

---

## Phase sequence

Phases are ordered so each builds only on verified, earlier work. Each produces
working, testable software on its own.

### Phase 0 — Foundations *(detailed plan written)*
Workspace + toolchain (Cargo workspace, SwiftPM packages, xcframework build
pipeline), Rust core crate + UniFFI bridge proof, the design-token layer, the
core data model (`Host`/`Identity`/`Defaults` + resolution), and the AES-256-GCM
record envelope.
**Specs:** `design-tokens`, `host-config-model` (schema + storage primitive only).
**Exit:** `swift test` green across all four task suites; `coreVersion()` round-trips Rust→Swift.

### Phase 1 — SSH core (the de-risking spike)
russh behind the UniFFI bridge: TCP+SSH handshake, host-key TOFU delegate,
auth (publickey / password / keyboard-interactive), OpenSSH cert presentation,
raw PTY shell channel with stdin write + stdout/stderr stream + resize,
`direct-tcpip` / `forwarded-tcpip` forwards, ProxyJump as nested channels, and
the four-tier algorithm allowlist enforced via russh's per-category config.
**Specs:** `ssh-algorithms`, `host-key-trust`, `ssh-cert-auth`, `chain-auth`.
**Exit:** integration tests against a containerized `sshd` in CI; cert auth + a 2-hop ProxyJump pass.

### Phase 2 — Storage & sync
Keychain identity store (iCloud-Keychain + Secure-Enclave flavors via
`SecAccessControl`), `known_hosts` in Keychain, CloudKit Private DB host/Defaults
records wrapped in the Phase-0 AES envelope, per-category iCloud sync toggles.
**Specs:** `host-config-model` (storage backbone), `identities-keys-management`
(store layer), `icloud-sync-scope`.
**Exit:** identity create→store→fetch round-trips on-device; CloudKit records readable only as ciphertext.

### Phase 3 — Terminal core + tmux control mode
SwiftTerm integration (Decision D1), the `tmux -CC` control-mode protocol parser
(`%output`/`%window-*`/`%layout-change`/`%begin`/`%end`), the native pane model,
SwiftUI pane rendering, degraded raw-PTY fallback, and the terminal feature set.
**Specs:** `terminal-emulator-scope`, `terminal-ux-additions`, `terminal-feedback`,
`degraded-mode`, `context-detection`, `function-keys`, `tmux-session`.
**Exit:** connect → tmux `-CC` → native panes render; split/new-window/resize work; raw-PTY fallback verified.

### Phase 4 — Keybar, input & predictor
Keybar layout/customization engine (locked-left + scroll, Esc pill, Pad,
sticky/lockable modifiers), macro/snippet unification, gesture ownership,
external-keyboard adaptation + Cmd-shortcut map, and the on-device predictor
(CMS + Bloom vocabulary, suggestion strip, seeded defaults).
**Specs:** `keybar-customization`, `function-keys` (keybar side), `external-keyboard`,
`predictor` (`docs/superpowers/specs/2026-06-13-predictor-design.md`).
**Exit:** keybar drives real input into a live pane; predictor suggests from learned vocabulary.

### Phase 5 — Host & identity UI
Host CRUD form (nine sections, default-collapse, inline identity sub-flow),
Identities & Keys management surface, first-host onboarding + Tips & Gestures.
**Specs:** `host-crud`, `identities-keys-management` (UI), `first-host-onboarding`.
**Exit:** create a host end-to-end through the UI and connect to it.

### Phase 6 — Connection management UI
Multi-connection lifecycle (Active / Live·Awake / Live·Sleeping / Recent),
Esc-pill picker, status banners + expanded banner templates, mosh roaming +
SSH sleep/reattach.
**Specs:** `multi-connection-switching`, `banner-expanded`.
**Exit:** 8-connection soft cap + LRU demotion; banner expand/collapse; mosh resume path.

### Phase 7 — Settings, security surface & ship polish
Settings sub-screens (Security / App preferences / About & Help), privacy
statement content, screen-capture protection, Pro/paid IAP, theme-picker
plumbing (hidden in v1), iPad single-window size-class pass.
**Specs:** `settings-sub-screens`, `privacy-statement`, `screen-capture-protection`,
`pro-paid-scope`, `design-tokens` (picker UI), `ipad-scope`.
**Exit:** App Store submission readiness — privacy section, IAP, all settings reachable.

---

## Cross-cutting constraints (apply to every phase)

- **No telemetry, analytics, crash reporting, ads, or third-party SDKs** (`privacy-statement-design`).
- **tmux ≥ 3.0** required for control mode; below that → raw-PTY degraded mode.
- **No inline hex in UI** — colors only via `Color.theme.*` tokens.
- **Secrets never in CloudKit** — keys/passwords/passphrases/`known_hosts` live in Keychain/SE; CloudKit holds only AES-GCM ciphertext of metadata.
- **Conventional commits**; squash-merge to keep history clean.
- **UUIDs internal, labels for humans** — references survive label edits.
- **GPL-3.0-only** — every source file starts with `// SPDX-FileCopyrightText: 2026 True Positive LLC`
  then `// SPDX-License-Identifier: GPL-3.0-only` (REUSE-compliant); keep UniFFI's
  MPL-2.0 file headers intact; ship `LICENSE` + `LICENSE.IOS`.
- **`cargo deny check licenses`** gates every CI build — fails if any crate
  resolves to a GPL-incompatible license (e.g. an `OpenSSL`-tagged `aws-lc-sys`
  < 0.39.0 sneaking back in).
- **Platform-agnostic logic stays Linux-testable** — crypto via swift-crypto
  behind `#if canImport(CryptoKit)`; keep the Apple-only UI/SDK layer thin so the
  testable surface is maximal before macOS CI.
- **Never commit secrets** — history goes fully public on open-sourcing; gitignore
  `.env`/`data/`.

## Dependency notes

- Phase 1 depends on Phase 0's Rust/UniFFI toolchain (Task 1) only.
- Phase 2 depends on Phase 0's data model (Task 3) + AES envelope (Task 4).
- Phase 3 depends on Phase 1 (SSH channel) and Phase 0 tokens.
- Phases 5–7 depend on the data/UI layers beneath them but are largely
  parallelizable once Phase 3 lands.
</content>
</invoke>
