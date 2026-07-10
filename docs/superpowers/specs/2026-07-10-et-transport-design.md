<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Eternal Terminal (ET) transport mode

**Date:** 2026-07-10
**Status:** Approved (brainstorming), pending implementation plan
**Related:** transport/tmux roadmap Track 3 (`docs/brainstorming-decisions.md`; memory
`mosh-tmux-et-modes-roadmap`, `et-transport-brainstorm`); the Mosh integration this mirrors
(`docs/superpowers/specs/*mosh*`, `extern/mosh/`, `App/Mosh/MoshSession.mm`,
`scripts/build-mosh-xcframework.sh`, `Sources/SemicolynKit/Mosh/`); the native `-CC` panes
this reuses (`Sources/SemicolynKit/Tmux/`, `App/TmuxPaneContainer.swift`); the SSH core that
bootstraps it (`crates/semicolyn-ssh-core`, russh).

## Problem

semicolyn has two transports today, and neither delivers native tmux panes **and** network
roaming at once:

| Mode | Transport | Native `tmux -CC` panes | Roaming (survives IP change / sleep) |
|---|---|---|---|
| SSH (today) | SSH / TCP | ✅ works (Phase 3) | ❌ connection drops on roam |
| Mosh (today) | UDP (state-sync) | ❌ — `tmux -CC` cannot run over Mosh | ✅ |

`tmux -CC` emits a line-oriented control *protocol* over a clean byte *stream*; Mosh is a
state-synchronizing emulator that syncs a virtual *screen*, so it structurally shreds the
`-CC` stream (documented upstream incompatibility — iTerm2 docs, mosh issue #640). A user who
wants panes **and** roaming (e.g. a phone that sleeps / changes networks mid-tmux-session) has
no option.

## Goal

Add a third connection mode — **Eternal Terminal (ET)** — that carries a clean, resumable
byte stream, so native `tmux -CC` panes survive roaming. ET is a re-connectable secure remote
shell (SSH-bootstrapped, then its own resumable TCP with a backed byte buffer that replays
the gap on reconnect). Its byte stream feeds our **existing** `ControlModeParser` /
`TmuxRuntime` / `TmuxPaneContainer` unchanged — ET only replaces the *transport*, not the
terminal or tmux layers.

Non-goals for v1: auto-installing `etserver` on remote hosts; ET jumphost mode; ET port
forwarding beyond what the shell session needs.

## Background: what ET is (verified against upstream v7.0.0)

- Upstream: `MisterTea/EternalTerminal`, **Apache-2.0**, C++17. Three processes on the host:
  `etserver` (multiplexer/router), `etterminal` (runs as the user, hosts the PTY), and the
  `et` client. Default TCP port **2022**.
- **Crypto:** libsodium `crypto_secretbox` (XSalsa20 + Poly1305), 32-byte key = a 32-char
  passkey exchanged at bootstrap (no KDF). Not AES (the marketing is wrong).
- **Resume:** `BackedWriter` keeps an encrypted ring buffer of the last N bytes sent + a
  sequence number; on reconnect it re-sends `writer_seq − reader_seq`. `BackedReader` tracks
  the read sequence and revives on a new fd.
- **Protocol version = 6**, compared for *exact* equality (`ServerConnection.cpp`,
  `!=` → `MISMATCHED_PROTOCOL`, no negotiation). Empirically stable: last changed **2019**,
  three bumps ever (~1 per 3 years), always on a major release. See "Risk" below.
- **Bootstrap:** the upstream client self-generates `id` (16 chars) + `passkey` (32 chars),
  then shells out to the system `ssh` binary to run, on the host:
  `echo '<id>/<passkey>_<TERM>' | etterminal <opts>`. `etterminal` registers the credential
  with `etserver` via a fifo; the client then opens the real TCP connection on 2022 keyed by
  the passkey. **ET embeds no SSH library** — it runs the system `ssh`.
- **The transport is PTY-free and cleanly separable:** `src/base/{Connection, ClientConnection,
  BackedReader, BackedWriter, CryptoHandler, *SocketHandler, Packet, RawSocketUtils, Headers}`
  ≈ **~2,000 LOC**, no terminal/PTY knowledge. Terminal/PTY handling lives separately in
  `src/terminal/`.

## Architecture

Two new artifacts plus wiring in semicolyn. The design deliberately **splits the portable ET
client from the iOS glue** — the mistake Blink made with `libmoshios` (fusing `iOSClient` +
`mosh_main`) is what left their wrapper trapped and unreusable.

```
┌──────────────────────────────────────────────────────────────┐
│  libet  — OWN STANDALONE REPO (portable, reusable)            │
│  • vendors upstream ET src/base/ UNMODIFIED (git submodule)   │
│  • + ETClient class + a callback-based extern "C" C-ABI       │
│  • deps: libsodium, protobuf-lite only. NO Apple/UIKit.       │
│  • builds for Linux / macOS / iOS / Android                   │
│  • Linux-CI-testable against a real etserver fixture          │
└──────────────────────────────────────────────────────────────┘
                         ▲ vendored + linked by
┌──────────────────────────────────────────────────────────────┐
│  libetios  — IN semicolyn repo (thin wrapper, like extern/mosh)│
│  • Obj-C++/Swift bridge over libet's C-ABI                    │
│  • callbacks → Swift; app-lifecycle (suspend/resume) glue     │
│  • packaged as ET.xcframework via build-et-xcframework.sh     │
└──────────────────────────────────────────────────────────────┘
                         ▲ consumed by
┌──────────────────────────────────────────────────────────────┐
│  semicolyn app                                                │
│  • russh runs the etterminal bootstrap (replaces ssh shell-out)│
│  • ETSession (Swift) drives libetios; byte stream →           │
│    existing ControlModeParser / TmuxRuntime / TmuxPaneContainer│
│  • per-host Transport picker + probe/fallback to SSH          │
└──────────────────────────────────────────────────────────────┘
```

This mirrors semicolyn's existing two-tier philosophy: a portable, Linux-tested core
(`libet`, like `crates/semicolyn-ssh-core`) + a thin Apple edge (`libetios`, like the UniFFI
Swift bridge).

## Components

### 1. `libet` — portable C ET client (own repo)

**What it does:** exposes ET's re-connectable transport behind a small, stable, callback-based
C ABI, with no iOS/Apple assumptions, so it is usable from Swift/Obj-C (iOS), our Docker test
harness (Linux), and — in principle — any FFI consumer (the reusable "good-netizen" artifact
ET issue #452 has asked for).

**How you use it (C-ABI, callback model):**

```c
typedef struct et_client et_client;   // opaque handle

typedef struct {
    void (*on_bytes)(void *ctx, const uint8_t *buf, size_t len);  // received stream bytes
    void (*on_state)(void *ctx, et_state state);                  // connecting/connected/roaming/disconnected
    void (*on_end)(void *ctx, const char *reason);                // terminal teardown (reason may be NULL)
} et_callbacks;

// host+port = the ET TCP endpoint (2022); id+passkey = the bootstrap credential (already
// planted on the host by the caller over SSH). Returns NULL on immediate failure.
et_client *et_connect(const char *host, uint16_t port,
                      const char *id, const char *passkey,
                      const et_callbacks *cbs, void *ctx);

int  et_send(et_client *c, const uint8_t *buf, size_t len);  // write to the stream
void et_close(et_client *c);                                 // tear down + free
```

- `et_connect` opens ET's `ClientConnection` on a background thread; ET's own reconnect logic
  drives roaming and calls `on_state`. Received bytes surface via `on_bytes`; the caller feeds
  them straight to its tmux/terminal layer. The caller never touches ET C++ classes.
- **Depends on:** vendored ET `src/base/` (submodule) + libsodium + protobuf-lite (generated
  from `ET.proto`). Chosen callback model over a blocking `et_read/et_write` API so no consumer
  has to own a read loop; the same ABI works identically on Linux and iOS.

**What it does NOT do:** the SSH bootstrap. `libet` receives an already-planted
`(host, port, id, passkey)` and only speaks the ET TCP protocol. Bootstrapping is the caller's
job (see §3) — this is the clean seam that removes ET's one iOS-hostile dependency (the system
`ssh` shell-out).

**Testing:** a Docker Compose `etserver` fixture (mirroring our `sshd`/`sshd-legacy`
fixtures), so `libet`'s connect / stream / reconnect-replay behavior is exercised on Linux CI
against a real server — including a roaming test (drop the fd, reconnect, assert the backed
buffer replays the gap with no loss).

### 2. `libetios` — thin iOS wrapper (in semicolyn repo)

**What it does:** adapts `libet`'s C-ABI to Swift and to the iOS app lifecycle, and packages
the whole thing as an `ET.xcframework`. Analogous to `App/Mosh/MoshSession.mm` over
`mosh_main`, but thinner because `libet` already did the real work.

- An Obj-C++ `ETSession` (or a small C shim + Swift class) that: holds the `et_client` handle,
  forwards `on_bytes` into a Swift `onOutput` closure, maps `on_state`/`on_end` to
  Swift-visible events, and exposes `send(Data)`.
- App-lifecycle glue: on background/foreground, ET's resume handles the network side; the
  wrapper ensures the handle survives suspension and reports roam state to the UI.
- `scripts/build-et-xcframework.sh` — cross-compiles `libet` (+ libsodium + protobuf-lite) for
  the iOS device/simulator slices, mirroring `build-mosh-xcframework.sh`. Linked as a
  `#if os(macOS)` binaryTarget in `Package.swift`, kept off the Linux `swift test` job.

### 3. Bootstrap via russh (semicolyn)

Replace ET's system-`ssh` shell-out with our existing russh core:

1. Generate `id` (16 chars) + `passkey` (32 chars) client-side (as upstream does).
2. Over the **existing russh SSH session**, run:
   `echo '<id>/<passkey>_<TERM>' | etterminal <opts>` — planting the credential with
   `etserver` on the host. (No response is needed back; the credential is self-generated.)
3. Hand `(host, 2022, id, passkey)` to `libetios` → `et_connect`.

Pure decision/command-building logic (which command string, TERM handling, option assembly)
lives in `Sources/SemicolynKit/ET/` as Linux-tested helpers — mirroring
`MoshServerCommand.swift` and the `tmuxLaunchDecision` pure pattern.

### 4. Probe + fallback to SSH (semicolyn)

ET needs `etterminal` installed on the host and port 2022 reachable — unlike stock SSH.
Mirroring the Mosh `onFirstFrame`/`onEnd` degradation we already ship:

- Over the bootstrap SSH session, probe for `etterminal` (e.g. `command -v etterminal`) and
  attempt the ET TCP connect.
- On absence / connect failure / `MISMATCHED_PROTOCOL`, **fall back to plain SSH + `tmux -CC`**
  with an explanatory banner ("Eternal Terminal unavailable — using SSH"). No dead-end.
- The probe/decision is a pure `ETLaunchDecision` helper in `Sources/SemicolynKit/ET/`
  (ATTACH-ET vs DEGRADE(reason)), matching `tmuxLaunchDecision` / `MoshLaunchDecision`.

### 5. Per-host Transport picker (semicolyn)

Today a Mosh-enabled host **silently wins** — `ConnectionViewModel` returns on the Mosh path
before tmux/SSH is considered. With three transports this is untenable (a panes+roaming user
would silently get Mosh, which has no panes). So:

- Add an explicit per-host **Transport** field: **Auto / SSH / Mosh / ET** (Auto default).
- A non-Auto choice forces that transport (and falls back per §4 if it can't connect).
- **Auto**'s exact precedence is deferred to coordinate with roadmap **Track 2** (the per-host
  "Startup command" / connection-model rework) so Transport + Startup-command land as one
  coherent host-connection UI, not two bolted-on fields.

## Data flow

```
connect → russh SSH session established
        → [Transport picker] ET selected (or Auto→ET)
        → probe etterminal + plant '<id>/<passkey>_<TERM>' | etterminal   (§3)
        → libetios.et_connect(host, 2022, id, passkey)                     (§1)
        → ET TCP stream established (libsodium secretbox)
   bytes: etserver ──▶ on_bytes ──▶ ETSession.onOutput ──▶ ControlModeParser
                                    ──▶ TmuxRuntime ──▶ TmuxPaneContainer (native panes)
   input: keystrokes ──▶ ETSession.send ──▶ et_send ──▶ etserver
   roam:  IP change / wake ──▶ ET BackedWriter replays gap ──▶ on_state(roaming→connected)
                                    ──▶ roam banner (reuse Mosh's)
   fail:  probe miss / connect fail / proto mismatch ──▶ DEGRADE ──▶ SSH + tmux -CC + banner (§4)
```

## Error handling

- **ET server absent / port unreachable / protocol mismatch** → graceful fallback to SSH
  (§4), banner, session continues.
- **Mid-session ET drop that can't resume** → `on_end(reason)`; surface a banner. (Whether to
  attempt an SSH fallback *after* first frame, or just report, follows the Mosh precedent:
  after first frame a hard end is reported, not silently re-routed.)
- **libet-level failures** (bad key, connect error) → non-NULL error path from `et_connect` /
  negative `et_send` return, mapped to a Swift-visible reason string.

## Testing

Per `docs/superpowers/specs/2026-06-18-testing-standards-design.md` (EP + BVA, assert
observable values, negative tests assert the *specific* failure):

- **`libet` (Linux CI, own repo):** connect success/failure (bad passkey → specific error, not
  just "failed"); stream round-trip (send bytes, assert exact echo); **reconnect replay**
  (drop fd mid-stream, reconnect, assert the backed buffer replays exactly the missed bytes,
  none lost/duplicated); protocol-mismatch path (server on a different version → `on_end`/error
  surfaces `MISMATCHED_PROTOCOL`, not a generic failure). Against a real `etserver` fixture.
- **`Sources/SemicolynKit/ET/` pure helpers (Linux `swift test`):** `ETLaunchDecision`
  (ATTACH-ET vs each DEGRADE reason), bootstrap command-string builder (exact `id/passkey_TERM`
  formatting incl. odd `$TERM`), Transport-picker resolution. Good AND bad cases each.
- **libetios / xcframework / app wiring:** macOS-CI-verified (not Linux-buildable), plus
  on-device roaming pass (start a tmux `-CC` session over ET, background the app / change
  networks, confirm panes survive with no data loss).

## Risks & mitigations

- **No ET library exists** — ET is an application, not a library (CMake builds executables
  only; no exported headers). We are building `libet` first; plan to **maintain a fork** (make
  it clean/documented/PR-shaped so it is upstreamable if MisterTea ever bites, but do not count
  on adoption — Blink's equivalent was never merged).
- **We wrap ET's *internal* C++ classes** — a bridge break is a build-time CI failure, not a
  user outage. Empirically low: over ~7 years post-2019, the wrapped surface had **one**
  public-signature break (`SocketHandler::readPacket`, and only if called directly — the normal
  `Connection::read` path is unchanged). The surface is near-frozen; churn is internal `.cpp`
  and formatting sweeps behind a stable contract.
- **Protocol v6 exact-match, no negotiation** — low-risk: unchanged since 2019, bumps only on
  major releases (~1 per 3 years). A future bump fails *loudly* (`MISMATCHED_PROTOCOL` with a
  clear message) and is **absorbed by the SSH fallback** (§4). Mitigation: periodically bump
  the vendored submodule, like `extern/mosh`.
- **Crypto: nonce is a per-message counter seeded by a 1-byte direction tag** — needs a code
  read of `CryptoHandler` before shipping to confirm reconnect does not risk nonce reuse under
  the same passkey. Implementation-phase verification.
- **License: ET is Apache-2.0, semicolyn is GPL-3.0-only** — Apache-2.0 → GPL-3.0 is one-way
  compatible (incorporate + preserve NOTICE), but run the **license-audit** skill before
  vendoring; `libet`'s own license likely GPL-3.0 to match, with ET's Apache NOTICE preserved.

## Open items (deferred to implementation / plan)

- **Auto-precedence order** (Transport=Auto) — coordinate with Track 2.
- Exact final `libet` C-ABI function list — pin against ET's real `ClientConnection`
  read/write signatures when writing the shim.
- `libet` repo scaffolding: name, license, Docker + `etserver` fixture CI shape.
- xcframework size budget; ET jumphost relevance; roam/reconnect UX (reuse Mosh's banner).
