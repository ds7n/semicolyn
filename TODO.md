<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Status & TODO

The canonical status + pending-work list. Architecture and the spec/plan map live in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md); the full decision log (incl. per-spec "out of scope") in [docs/brainstorming-decisions.md](docs/brainstorming-decisions.md).

**Headline:** design complete; a connect-and-get-a-shell MVP builds for the iOS Simulator. The protocol + logic tiers are built and Linux-tested; the app shell is built and validated by macOS CI. Not yet device-installable (needs Apple Developer signing).

**Tests green:** 17 Rust unit + 35 Rust integration (vs containerized `sshd`) + 561 Swift (NeotildeKit + SeedKit), all on the Linux fast loop.

## Phase status

| Phase | Scope | State |
|---|---|---|
| **0 — Foundations** | Cargo + SwiftPM workspace, UniFFI bridge proof, design tokens, data model, AES-256-GCM record envelope | ✅ Done |
| **1 — SSH core** | russh behind UniFFI: handshake, host-key TOFU, auth (password / publickey / keyboard-interactive), OpenSSH cert auth, PTY shell, local/remote/dynamic forwards, ProxyJump, 4-tier algorithm allowlist | ✅ Done¹ |
| **2a — Storage core** | Host/identity schema + resolution table; `BlobStore`→`EncryptedRecordStore`, `SecretStore`, `HostKeyStore`; repository invariants; sync taxonomy | ✅ Done |
| **2b-i — Key minting** | ed25519 generation + OpenSSH-key import in the Rust core; `IdentityService` (mint→Keychain→metadata); `CoreIdentityMinter` bridge; publickey connect from a stored identity | ✅ Done (iCloud-Keychain flavor) |
| **2b-ii — Sync + SE** | CloudKit Private DB + sync engine; Secure-Enclave flavor (`SecAccessControl` + russh→SE signing bridge) | ⏳ enrollment-gated |
| **3 — Terminal + tmux** | Control-mode stack done²; **Plans A+B+C+D done**: probe→attach `tmux -CC`, native pane layout, multi-window, debounced resize, raw-PTY degrade; terminal UX (bell, OSC 52, titles, URL tap, cursor, mouse dot, pinch-zoom); per-pane context detection (engine + `pane_current_command` poll + observable) + mid-session crash banner. | ✅ Done³ |
| **4 — Keybar, input & predictor** | Predictor engine done. **4a MVP keybar done**: mount + core input slots (Esc·Pad·Modifier·Tab + symbols), keystroke codec, Ctrl-lock modifier SM, input router — compile-validated on macОS CI (interaction/visual unverified pending a Simulator/device). **4b–4e pending**: promotions+Fn, predictor strip, customization, external keyboard. | ◐ Engine + 4a done; 4b–4e pending |
| **MVP app shell** | iOS app target + SwiftTerm wired via UniFFI: connect → password/keyboard-interactive/**publickey** auth → shell, real host-key TOFU trust | ✅ Builds for Simulator |
| **5–7 — UI & ship** | Host CRUD UI + identity create/import + connect-from-saved done. Standalone Identities & Keys mgmt, connection-management UI, settings, IAP, App Store polish pending | ◐ Host CRUD done, rest pending |

¹ The `ssh-ed25519-cert-v01@openssh.com` **host**-certificate variant is deferred — blocked on russh 0.61 (verifies the server host key only as a plain `PublicKey`; no CA/principal/validity path). A guard test prevents advertising it until upstream support lands.
² Control-mode stack verified against real `tmux` in the `sshd` fixture, incl. the DCS-wrapped live `-CC` stream.
³ Plan D ships the context **engine + signal + observable** (`PaneContextMachine` dwell SM, `PaneContextStore`, `PromotionRegistry`/catalog, `list-panes` poll, `@Published paneContexts`); the keybar **visual** consumption (promoted slots, engage/disengage animation, per-pane pin, kill-switch) is Phase 4. Mirrors "predictor engine done / UI pending".

## Next (unblocked dev work)

- **Phase 4 — keybar UI (4a done, merged #14).** Remaining slices: **4b** promotions render (consume Plan-D `paneContexts` + `PromotionRegistry`) + Fn mode/auto-engage + per-pane DECCKM arrow mode; **4c** predictor strip (consume the done engine); **4d** Settings→Keybar editor + custom slots + macro creation + reverse-bar; **4e** external keyboard (`UIKeyCommand` map, hardware modifiers, compact bar). Specs: `2026-06-15-keybar-customization-design.md`, `2026-06-14-function-keys-design.md`, `2026-06-17-external-keyboard-design.md`. **Plus a Simulator/device pass on 4a** (mount-above-keyboard via `inputAccessoryView`, slot recolor, gestures) — currently compile-only-validated.
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
