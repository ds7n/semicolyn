<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Status & TODO

The canonical status + pending-work list. Architecture and the spec/plan map live in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md); the full decision log (incl. per-spec "out of scope") in [docs/brainstorming-decisions.md](docs/brainstorming-decisions.md).

**Headline:** design complete; a connect-and-get-a-shell MVP builds for the iOS Simulator. The protocol + logic tiers are built and Linux-tested; the app shell is built and validated by macOS CI. Not yet device-installable (needs Apple Developer signing).

**Tests green:** 17 Rust unit + 35 Rust integration (vs containerized `sshd`) + 681 Swift (NeotildeKit + SeedKit), all on the Linux fast loop.

## Phase status

| Phase | Scope | State |
|---|---|---|
| **0 — Foundations** | Cargo + SwiftPM workspace, UniFFI bridge proof, design tokens, data model, AES-256-GCM record envelope | ✅ Done |
| **1 — SSH core** | russh behind UniFFI: handshake, host-key TOFU, auth (password / publickey / keyboard-interactive), OpenSSH cert auth, PTY shell, local/remote/dynamic forwards, ProxyJump, 4-tier algorithm allowlist | ✅ Done¹ |
| **2a — Storage core** | Host/identity schema + resolution table; `BlobStore`→`EncryptedRecordStore`, `SecretStore`, `HostKeyStore`; repository invariants; sync taxonomy | ✅ Done |
| **2b-i — Key minting** | ed25519 generation + OpenSSH-key import in the Rust core; `IdentityService` (mint→Keychain→metadata); `CoreIdentityMinter` bridge; publickey connect from a stored identity | ✅ Done (iCloud-Keychain flavor) |
| **2b-ii — Sync + SE** | CloudKit Private DB + sync engine; Secure-Enclave flavor (`SecAccessControl` + russh→SE signing bridge) | ⏳ enrollment-gated |
| **3 — Terminal + tmux** | Control-mode stack done²; **Plans A+B+C+D done**: probe→attach `tmux -CC`, native pane layout, multi-window, debounced resize, raw-PTY degrade; terminal UX (bell, OSC 52, titles, URL tap, cursor, mouse dot, pinch-zoom); per-pane context detection (engine + `pane_current_command` poll + observable) + mid-session crash banner. | ✅ Done³ |
| **4 — Keybar, input & predictor** | **4a + 4b + 4c done**: 4a mount + core input slots + keystroke codec + Ctrl-lock modifier SM + input router; 4b context promotions (bronze from `paneContexts`) + Fn mode (F1–F12, Fn SM, htop/top/mc auto-engage) + per-pane DECCKM; 4c predictor strip (input token tracker → engine suggestions → auto-hiding chip row, tap-to-complete, learn/harvest/flush, incognito-gated) — all compile-validated on macОS CI (interaction/visual unverified pending a Simulator/device). **4d-1 done**: Codable keybar layout + sticky-rule mutations (reorder/remove/move-across-divider) + reverse-bar + persisted `KeybarSettingsStore` + Settings→Keybar list editor (Esc-pill long-press entry); pure core Linux-tested, editor macОS-CI-only. **4d-2 done** (PR #18): macro model + `{Ctrl+R}…{Enter}` template parser + custom-slot binding model (4 gestures, ≥1-binding rule) + `KeybarLibrary` folded into settings (back-compat decode) + macro→bytes expansion / `fireMacro` + `MacroRecorder`; App tier: searchable Launcher, custom-slot editor, template/record macro creation, wired "+ Add" sheet (core Linux-tested, App macОS-CI-only). Placeholders deferred to v2. **4e pending**: external keyboard. | ◐ 4a–4d done; 4e pending |
| **MVP app shell** | iOS app target + SwiftTerm wired via UniFFI: connect → password/keyboard-interactive/**publickey** auth → shell, real host-key TOFU trust | ✅ Builds for Simulator |
| **5–7 — UI & ship** | Host CRUD UI + identity create/import + connect-from-saved done. Standalone Identities & Keys mgmt, connection-management UI, settings, IAP, App Store polish pending | ◐ Host CRUD done, rest pending |

¹ The `ssh-ed25519-cert-v01@openssh.com` **host**-certificate variant is deferred — blocked on russh 0.61 (verifies the server host key only as a plain `PublicKey`; no CA/principal/validity path). A guard test prevents advertising it until upstream support lands.
² Control-mode stack verified against real `tmux` in the `sshd` fixture, incl. the DCS-wrapped live `-CC` stream.
³ Plan D ships the context **engine + signal + observable** (`PaneContextMachine` dwell SM, `PaneContextStore`, `PromotionRegistry`/catalog, `list-panes` poll, `@Published paneContexts`); the keybar **visual** consumption (promoted slots, engage/disengage animation, per-pane pin, kill-switch) is Phase 4. Mirrors "predictor engine done / UI pending".

## Next (unblocked dev work)

- **Phase 4 — keybar UI (4a #14, 4b #15, 4c #16, 4d-1 #17, 4d-2 #18 done).** Remaining slice: **4e** external keyboard (`UIKeyCommand` map, hardware modifiers, compact bar). Spec: `2026-06-17-external-keyboard-design.md`. **4d-2 follow-ups** (deferred, noted in code): parameterized macro placeholders (`{{host}}`, defaults, per-host remembered values) — the v2 placeholder system; editing an existing macro's body from the Launcher; live-keybar capture for record mode (v1 uses a dedicated input pad). Spec: `2026-06-15-keybar-customization-design.md`.
- **Simulator/device pass on the keybar (4a + 4b + 4c + 4d-1 + 4d-2)** — compile-only-validated so far. Verify: mount-above-keyboard (`inputAccessoryView` vs the v1 `safeAreaInset`), slot recolor, gestures, predictor-strip slide/chips/tap-complete; **plus the unrendered spec visuals** — promoted-slot bronze top-edge accent (context spec §"Promoted slot visual") and Fn-locked brighter glyph + 4pt lock-dot (function-keys spec §"Visual"). **4d-1 editor**: Esc-pill long-press → Settings→Keybar; verify drag-reorder, swipe/edit-mode delete (Esc/Pad locked), per-row move-across-divider menu, reverse-bar mirror (`layoutDirection` flip), Reset. Note 4d-1 used two sections + a per-row move action instead of the spec's single draggable divider (SwiftUI cross-section drag is unreliable) — revisit. **4d-2 surfaces**: Launcher (search/pin/delete), custom-slot editor (4 binding rows, ≥1-binding Save gate), macro creation (template live-parse + record chip list), pinned-macro / custom-slot rendering (hint glyphs, `fireMacro`), "+ Add" sheet. Gated on Apple enrollment for device.
- **Predictor 4c follow-ups** (tracked): flush learned state on app-background (`scenePhase`) — today only session teardown flushes, so a backgrounded/killed app loses session learning; add an `onHarvestBytes` slot to `TerminalShellOutput` so raw-shell (degraded) output-harvest works (tmux path already harvests); move the tmux harvest call inside the visible-pane branch; nil `output.onBytes` in `teardown`.
- **Theme picker + Pro-gating** — Settings UI to switch themes; gate **Bell-bronze** as a Pro cosmetic (Neon Midnight is the free default). Specs: `2026-06-16-settings-sub-screens-design.md`, `2026-06-16-pro-paid-scope-design.md`.
- **Phase 3c deferred seams** (`TODO(phase4)` markers in `App/`): `onSSHLink` connect-prefill; selection-suspend gesture + cursor-placement-halo suspend; active-pane title keying (currently last-pane-wins); unify the crude `sendApproxClientSize` with the new debounced resize path.

## Enrollment-gated (Apple Developer Program org enrollment, in flight)

- **2b-ii** — CloudKit Private DB sync engine + Secure-Enclave identity flavor.
- **On-device / TestFlight testing** and code-signing — needs the signing identity.

## Deferred / when-needed

- **Accessibility review** — app-wide a11y pass (VoiceOver for terminal + keybar, Dynamic Type vs fixed cell font, low-opacity overlay + focus-border contrast, Reduce Motion for bell pulse / cursor blink, haptic opt-out, tap-target minimums). Best once terminal UX + keybar/Settings UI exist.
- **Nerd Fonts** — patched glyph fonts (powerline/dev icons) in the terminal renderer, if users hit missing glyphs. Ties into a Phase-4 Terminal Settings font picker.
- **russh host-cert gap** — see footnote ¹; blocked upstream.

## Resolved (recent)

- **Naming/trademark** — renamed Glymr → neotilde (LIVE registered GLYMR mark drove it); USPTO-cleared; full domain namespace owned. TODO: file our own NEOTILDE mark (Cl. 009/042). Record: `docs/2026-06-24-naming-decision-neotilde.md`.
- **Default theme** — **Neon Midnight** (coral neon on midnight blue-black, bell-only glow); Bell-bronze retained as a switchable alternate. Spec: `docs/superpowers/specs/2026-06-25-neon-midnight-theme-design.md`.
