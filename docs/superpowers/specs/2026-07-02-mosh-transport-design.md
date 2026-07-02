<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Mosh transport — design

**Date:** 2026-07-02
**Type:** Feature design (new transport). Adds real, interoperable Mosh support to
semicolyn by vendoring the upstream Mosh C++ client as an iOS library, bootstrapped
over the existing russh SSH core and rendered through SwiftTerm.

## Context & goal

semicolyn is billed as an SSH/**Mosh** client, but Mosh today is a **stub**: `MoshConfig`
exists on `Host` and there's a settings UI, yet the connect flow never consults it and no
Mosh transport exists (`connection.rs` even labels `open_exec` "the *future* mosh bootstrap").
This design makes Mosh **real and interoperable** — semicolyn connects to any standard
`mosh-server`, with Mosh's predictive local echo — so the product claim is true.

The defining fact about Mosh: it is **not** a byte-stream transport like SSH. `mosh-server`
runs its own terminal emulator remotely and syncs **screen-state diffs** to the client over
UDP (its SSP protocol); the client renders that state and speculatively echoes keystrokes.
So Mosh partly *replaces* the terminal-emulation model rather than slotting under SwiftTerm
as a transport swap.

## Locked decisions

- **Real Mosh interop** — speak the actual Mosh protocol, interoperate with stock `mosh-server`.
- **Full Mosh including predictive echo** in v1 (not just transport).
- **Vendor the real Mosh C++** (Blink-style) — reimplementing Mosh natively (Rust/Swift) was
  rejected: no native reimplementation exists anywhere, prediction is subtle, and vendoring
  gets correct interop + prediction for free. The reference iOS client (Blink) vendors Mosh C++.
- **Source = `blinksh/mosh`** (the iOS-library fork) as a **pinned git submodule** + a
  modernized build script. We own the *build integration*, not the Mosh code. The public
  `blinksh/build-mosh` is archived (2020, Xcode 7) — a starting point to modernize, not usable
  as-is.
- **Bootstrap reuses the existing russh core** — so **keyed (public-key) login is inherited**;
  Mosh rides the SSH auth semicolyn already has.

## Licensing

Mosh is GPLv3+ (with an OpenSSL exception); `blinksh/mosh` is GPLv3; semicolyn is GPL-3.0-only
— all compatible. Crucially, upstream Mosh's [`COPYING.iOS`](https://github.com/mobile-shell/mosh/blob/master/COPYING.iOS)
grants an **explicit App Store exception**: the copyright holders "will not pursue any license
violation that results solely from the conflict between the GPLv3 and the Apple App Store terms
of service." So the GPLv3-vs-App-Store tension is pre-waived for the vendored Mosh code.
Obligations (already met): vendored files retain **their** copyright + GPL headers (REUSE
per-file provenance — not `© True Positive LLC`); source stays available; credit Mosh + Blink.
Only Mosh + the thin libmoshios wrapper is vendored — **not** Blink's broader userland.

## Architecture & tiers

Respecting the repo's Linux-tested / Apple-only split:

**① Vendored Mosh build → `Mosh.xcframework`** (Apple-only, macOS-CI). `blinksh/mosh` as a pinned
submodule + `scripts/build-mosh-xcframework.sh` (modernized from `build-mosh` / Blink's current
build) → builds Mosh + libprotobuf, device + simulator slices, into `Mosh.xcframework`. Wired
into xcodegen + the CI xcframework step, mirroring `SemicolynSSHCore.xcframework`.

**② Bootstrap + decision → SemicolynKit** (pure, Linux-tested):
- `MoshServerCommand` — resolved `MoshConfig` → `mosh-server new -s -c <colors> -l LANG=… --` argv.
- `MoshConnect` — parses `MOSH CONNECT <port> <key>` → `(port, key)` or a typed error.
- `MoshLaunchDecision` — Mosh vs SSH from resolved config + bootstrap outcome (mirrors the
  existing `tmuxLaunchDecision` pure pattern).

**③ Bridge → App tier** (Obj-C++, macOS-CI): `MoshSession` — thin wrapper over libmoshios's
`STMClient`. Inputs (host, UDP port, base64 key, cols/rows, locale/env); runs Mosh's loop on a
background thread; emits **output bytes → `SwiftTerm.feed()`**; takes **keystrokes/resize ←
SwiftTerm**; handles roaming + teardown.

**Bootstrap** reuses russh: SSH connect + **publickey auth** → `open_exec("mosh-server new -s …")`
→ capture stdout → `MoshConnect` parse → hand off to `MoshSession`. The SSH connection's only job
is the bootstrap and may close afterward (Mosh is independent). SwiftTerm stays the display.

## Data flow / lifecycle

1. Connect to a Mosh-enabled host → russh SSH connect + publickey auth.
2. russh `open_exec` runs `mosh-server`; it binds a UDP port, prints `MOSH CONNECT <port> <key>`,
   detaches. SSH connection can close.
3. Kit parses the line (`MoshConnect`).
4. App creates `MoshSession(host, port, key, size, env)` → libmoshios opens UDP, OCB/SSP
   handshake, begins receiving the framebuffer.
5. Loop: framebuffer diffs → Mosh's Display → escape bytes → `SwiftTerm.feed()`; SwiftTerm
   keystrokes → `MoshSession` → Mosh UserStream. **Prediction is internal to Mosh** — its output
   already carries the predicted overlays.
6. Resize / roam / teardown handled by `MoshSession` (network-path change → Mosh re-sends from the
   new source addr; background pauses UDP, foreground resumes).

## Components & boundaries

**Kit (pure, Linux-tested):**

| unit | does | depends on |
|---|---|---|
| `MoshServerCommand` | `MoshConfig` → `mosh-server` argv | MoshConfig |
| `MoshConnect` | server stdout → `.success(port,key)` / `.failed(reason)` | — |
| `MoshLaunchDecision` | config + bootstrap outcome → `.mosh(port,key)` / `.fallbackSSH(reason)` | above two |

**App (Apple-only, macOS-CI):**

| unit | does | depends on |
|---|---|---|
| `Mosh.xcframework` | vendored libmoshios + protobuf, device+sim slices | `blinksh/mosh` submodule, build script |
| `MoshSession` | drive libmoshios: pump loop on bg thread, bytes↔SwiftTerm, resize, roam, teardown | Mosh.xcframework, SwiftTerm |
| `ConnectionViewModel` branch | after SSH auth: bootstrap → parse → create `MoshSession` → attach terminal | russh core, Kit units, `MoshSession` |

**Key seam:** `MoshSession` speaks only **bytes + size events** to the rest of the app — the same
contract SwiftTerm already consumes from the SSH shell — so the terminal view is agnostic to
whether it is fed by SSH or Mosh.

## Error handling

Every bootstrap-stage failure **falls back to a normal SSH session** so the user still connects;
only post-handoff drops are left to Mosh to ride out.

| failure | detection | behavior |
|---|---|---|
| `mosh-server` not installed | `open_exec` nonzero / no `MOSH CONNECT` | banner "mosh-server not found on host" → SSH fallback |
| Malformed `MOSH CONNECT` | `MoshConnect.failed` | typed error → banner → SSH fallback |
| UDP blocked/unreachable (firewall on 60000–61000) | `MoshSession` handshake timeout | banner "Mosh UDP unreachable — check firewall / falling back to SSH" |
| Crypto/key mismatch | libmoshios handshake failure | "Mosh connection failed" → SSH fallback |
| Network drop mid-session | libmoshios (Mosh's job to survive) | subtle "reconnecting" via the existing **degraded banner** — no teardown |
| Session/server death | thread exit / libmoshios signal | reuse the existing **mid-session crash banner** |

## Testing

**Kit (Linux, XCTest) — real assertions, EP/BVA/adversarial:**
- `MoshConnect` — valid line; missing `MOSH CONNECT`; truncated; extra server chatter; bad port;
  empty key → each asserts the *specific* typed outcome.
- `MoshServerCommand` — exact argv for representative configs (default, custom server path, custom
  port range, locale).
- `MoshLaunchDecision` — enabled/disabled × bootstrap success/failure branches.

**Rust (Docker fixture) — bootstrap interop:** add `mosh-server` to the sshd fixture image →
integration test that `open_exec`s `mosh-server new -s` against the real server and asserts a
well-formed `MOSH CONNECT` line. Proves the bootstrap end-to-end against real mosh-server on Linux
CI. (The UDP session itself is Apple-only, not Linux-testable.)

**macOS CI:** builds + links `Mosh.xcframework` (primary gate). **Stretch goal:** a macOS
integration test driving libmoshios against a real `brew install mosh` server on the runner →
proves true UDP/SSP interop in CI (may land as follow-up if flaky).

**Device/Simulator manual pass:** roaming, predictive-echo feel, resize.

## Internal phasing (ships as one cohesive feature)

Sequenced to kill the biggest risk first — the modernized C++ iOS build:

- **M1 — Build integration:** submodule `blinksh/mosh` + `scripts/build-mosh-xcframework.sh`
  (modernized for current Xcode / arm64-sim / iOS-26 SDK) + xcodegen link + **CI green**. If the
  modern iOS C++ build can't be made to work, we learn it here, before building on it.
- **M2 — Kit + Rust bootstrap:** the pure units (Linux-tested) + the Rust mosh-server bootstrap test.
- **M3 — Bridge + wiring:** `MoshSession` + `ConnectionViewModel` branch + terminal I/O.
- **M4 — Resilience + polish:** roaming/network-change, error banners + SSH fallback,
  Simulator/device feel pass (+ the stretch macOS interop test).

## Out of scope / risks

- **Out of scope:** Mosh over a non-SSH bootstrap; Mosh-specific server management UI beyond the
  existing `MoshConfig`; the stretch macOS interop test may be deferred.
- **Primary risk (M1):** modernizing the archived Blink build for current Xcode/arm64-sim/iOS-26 +
  building libprotobuf for iOS. This is why M1 is first and standalone.
- **Secondary risk:** iOS roaming/network-path handling and UDP-in-background behavior — validated
  in M4 on device.
