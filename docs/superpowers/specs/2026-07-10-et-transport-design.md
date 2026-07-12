<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Eternal Terminal (ET) transport mode

**Date:** 2026-07-10 (Component 1 revised 2026-07-12 to match the shipped `eternaltermlib`)
**Status:** Approved (brainstorming), pending implementation plan. **Component 1
(`eternaltermlib`) is SHIPPED + CI-green in `ds7n/eternaltermlib`;** the remaining work (§2–§5)
is semicolyn-side (xcframework build, `libetios` wrapper, russh bootstrap, probe/fallback,
Transport picker).
**Priority (2026-07-12):** ET is the user's **primary/targeted connection mode** (over raw SSH
or Mosh), so it is prioritized **ahead of roadmap Tracks 1 & 2** (previously "one track at a
time, T1→T2→T3"). The **no-Auto decision** (§5) removes ET's only dependency on Track 2, so ET
can proceed independently.
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
│  eternaltermlib — OWN STANDALONE REPO (SHIPPED, CI-green)     │
│  • vendors upstream ET src/base/ UNMODIFIED (git submodule)   │
│  • + ETClient class + a callback-based extern "C" C-ABI       │
│  • deps: libsodium, protobuf-lite only. NO Apple/UIKit.       │
│  • builds for Linux / macOS / iOS / Android                   │
│  • Linux-CI-testable against a real etserver fixture          │
└──────────────────────────────────────────────────────────────┘
                         ▲ vendored + linked by
┌──────────────────────────────────────────────────────────────┐
│  libetios  — IN semicolyn repo (thin wrapper, like extern/mosh)│
│  • Obj-C++/Swift bridge over eternaltermlib's C-ABI          │
│  • callbacks → Swift; app-lifecycle (suspend/resume) glue     │
│  • packaged as ETerminal.xcframework (build-et-xcframework.sh)│
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

### 1. `eternaltermlib` — portable C ET client (own repo) — **SHIPPED**

> **Status (2026-07-12):** this component is **built, tested, security-reviewed, and CI-green**
> in its own repo `ds7n/eternaltermlib` (Apache-2.0). It is no longer future work — the ABI
> below is the *shipped* header (`include/eternaltermlib.h`), and this section documents what
> semicolyn *consumes*, not what remains to build. The remaining ET work (§2–§5) is all
> semicolyn-side. (Named `eternaltermlib`, not the earlier working title `libet`.)

**What it does:** exposes ET's re-connectable transport behind a small, stable, callback-based
C ABI, with no iOS/Apple assumptions, so it is usable from Swift/Obj-C (iOS), a Linux test
harness, and — in principle — any FFI consumer (the reusable "good-netizen" artifact ET issue
#452 has asked for). ~679 LOC C++ (`src/session.cpp` / `transport.cpp` / `shim.cpp`) over the
vendored ET `src/base/` (submodule pinned `dfc75d6`).

**How you use it (the real, shipped C-ABI — a params struct so the ABI can grow without
breaking callers):**

```c
typedef struct et_client et_client;   // opaque handle

typedef enum {                        // reported via on_state
    ET_STATE_CONNECTING = 0, ET_STATE_CONNECTED = 1,
    ET_STATE_ROAMING = 2,             // link lost; ET is reconnecting + will replay the gap
    ET_STATE_DISCONNECTED = 3
} et_state;

typedef enum { ET_ERR_CLOSED = -1, ET_ERR_INVALID = -2 } et_err;  // typed failure codes

typedef struct {
    void (*on_bytes)(void *ctx, const uint8_t *buf, size_t len);  // decrypted stream bytes;
                                                                  // buf valid ONLY during the call — copy it
    void (*on_state)(void *ctx, et_state state);
    void (*on_end)(void *ctx, const char *reason);                // terminal teardown; reason may be NULL
                                                                  // and is UNTRUSTED remote text (see §Error handling)
} et_callbacks;

typedef struct {
    const char        *host;
    uint16_t           port;           // 0 -> default 2022
    const char        *id;             // 16-char bootstrap client id
    const char        *passkey;        // 32-char bootstrap secretbox key
    const char *const *env_keys;       // InitialPayload env map (include "TERM")
    const char *const *env_vals;       // parallel to env_keys; env_count entries
    size_t             env_count;
    uint16_t           cols, rows;     // initial window, char cells
    uint16_t           width, height;  // initial window, pixels; 0 if unknown
    int                keepalive_secs; // 0 -> ET default (5)
} et_config;

// Non-blocking: spawns the transport thread, returns immediately. Returns NULL ONLY on
// synchronous argument failure (NULL host/id/passkey, or env_count>0 with a NULL array/entry).
// Async handshake/connect failure (e.g. wrong passkey) is reported via on_end, NOT this return.
// cfg strings are deep-copied; the caller may free them on return.
et_client *et_connect(const et_config *cfg, const et_callbacks *cbs, void *ctx);

int  et_send(et_client *c, const uint8_t *buf, size_t len);                       // -> TERMINAL_BUFFER
int  et_set_window_size(et_client *c, uint16_t cols, uint16_t rows,               // -> TERMINAL_INFO (SIGWINCH)
                        uint16_t width, uint16_t height);
void et_close(et_client *c);                                                      // tear down + free; idempotent
```

- **Callbacks fire on the library's internal transport thread** — the consumer must hop to its
  own queue/actor (§2). `on_bytes`' `buf` is valid only for the duration of the call.
- **Serialization contract (a real constraint on §2):** `et_send` / `et_set_window_size` must
  NOT race `et_close` on the same handle; the caller externally serializes so no other call on
  a handle is in flight when `et_close` runs. `et_close` is idempotent for repeated *sequential*
  calls (incl. after `on_end`), but that does not cover a live race. → the Swift wrapper must
  own a single serialization point (an actor or a serial queue) per session.
- **`TERM` and initial window are set in `et_config`** (env map + `cols/rows/width/height`),
  not only in the bootstrap string — the bootstrap plants the credential; `et_config` carries
  the InitialPayload the client sends after connecting.
- **Depends on:** vendored ET `src/base/` + libsodium + protobuf-lite. Callback model chosen
  over a blocking `et_read/et_write` so no consumer owns a read loop; identical on Linux + iOS.

**What it does NOT do:** the SSH bootstrap. `eternaltermlib` takes an already-planted
`(host, port, id, passkey)` and only speaks the ET TCP protocol. Bootstrapping is the caller's
job (§3) — the clean seam that removes ET's one iOS-hostile dependency (the system `ssh`
shell-out).

**Testing (done, in-repo):** a Docker `etserver` fixture exercises connect / stream round-trip /
reconnect-replay on Linux CI against a real server, plus a roaming test (drop the fd, reconnect,
assert the backed buffer replays the gap with no loss); the full suite also runs under
ThreadSanitizer and AddressSanitizer+UBSan. Untrusted-input decode hardening and callback-pointer
validation landed via security review.

### 2. `libetios` — thin iOS wrapper (in semicolyn repo)

**What it does:** adapts `eternaltermlib`'s C-ABI to Swift and to the iOS app lifecycle, and
packages the whole thing as an `ETerminal.xcframework`. Analogous to `App/Mosh/MoshSession.mm`
over `mosh_main`, but thinner because `eternaltermlib` already did the transport work.

- An Obj-C++ `ETSession` (or a small C shim + Swift class) that holds the `et_client` handle,
  builds the `et_config` (host/port/id/passkey + env map incl. `TERM` + initial `cols/rows`),
  forwards `on_bytes` into a Swift `onOutput` closure, maps `on_state`/`on_end` to Swift-visible
  events, and exposes `send(Data)` + `setWindowSize(cols:rows:width:height:)`.
- **Threading + serialization (from §1's contract, not optional):** callbacks arrive on the
  library's transport thread, so `on_bytes`/`on_state`/`on_end` must hop to the app's main
  actor / session queue before touching UI or Swift state, copying the `on_bytes` buffer inside
  the callback (valid only for the call). Because `et_send`/`et_set_window_size` must not race
  `et_close`, `ETSession` owns a **single serialization point** (a serial `DispatchQueue` or an
  actor) through which all three flow, and tears down only after in-flight sends drain — the
  wrapper, not the library, guarantees this.
- **Untrusted `on_end(reason)`:** the reason string may be remote-server-supplied; the wrapper
  sanitizes it before logging (no verbatim to the structured/diagnostics log) or rendering it in
  a banner (no markup), per §1's security note.
- App-lifecycle glue: on background/foreground, ET's resume handles the network side; the
  wrapper keeps the handle alive across suspension and reports roam state to the UI.
- `scripts/build-et-xcframework.sh` — cross-compiles `eternaltermlib` (+ libsodium +
  protobuf-lite) for the iOS device/simulator slices, mirroring `build-mosh-xcframework.sh`,
  with `-DET_HTTP_TLS=OFF` (drops OpenSSL for iOS). Linked as a `#if os(macOS)` binaryTarget in
  `Package.swift`, kept off the Linux `swift test` job. (Vendoring + this build are already
  in progress on branch `feat/et-ios-build`.)

### 3. Bootstrap via russh (semicolyn)

Replace ET's system-`ssh` shell-out with our existing russh core:

1. Generate `id` (16 chars) + `passkey` (32 chars) client-side (as upstream does).
2. Over the **existing russh SSH session**, run:
   `echo '<id>/<passkey>_<TERM>' | etterminal <opts>` — planting the credential with
   `etserver` on the host. (No response is needed back; the credential is self-generated.)
3. Build an `et_config` (`host`, `port` 2022, `id`, `passkey`, env map incl. `TERM`, initial
   `cols`/`rows`) and hand it to `libetios` → `et_connect(&cfg, &cbs, ctx)`.

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
would silently get Mosh, which has no panes). The fix is an **explicit, exclusive per-host
choice** — no auto-selection.

**Decision (2026-07-12): NO Auto mode.** The user picks exactly one transport per host —
**SSH / Mosh / ET** — to the exclusion of the others. Rationale:

- **Auto's cost is disproportionate to its value.** The only thing that forced ET to depend on
  Track 2 was defining Auto's precedence; dropping Auto removes that coupling entirely. Auto's
  precedence is genuinely hard (capability-max? configured-first? probe-and-rank?), interacts
  with fallback, and produces "why did it connect with X?" confusion.
- **Transport choice has real, user-visible tradeoffs the user wants to own** (ET needs
  `etserver`; Mosh has no panes; SSH roams poorly). A silent Auto that guesses wrong is exactly
  the current Mosh-silently-wins bug we're fixing.
- **Fallback ≠ Auto.** Graceful degradation stays without Auto: an explicit "ET" that can't
  connect still falls back to SSH + a banner (§4). Only the up-front *guessing* is removed.

Design:

- Per-host **Transport** field: **SSH / Mosh / ET**, exactly one selected. **Default: SSH** (the
  universally-available baseline — no `etserver`/`etterminal`, no UDP). Per-host transport is a
  **first-class feature**, not an afterthought: the user deliberately opts a host up to ET or
  Mosh.
- The chosen transport is attempted; on failure it falls back to SSH per §4 (banner, no
  dead-end). No silent cross-transport selection.
- **UI must surface each transport's pros/cons inline** so the choice is informed (not a bare
  segmented control). Guidance to convey per option:
  - **SSH** — works everywhere; native `tmux -CC` panes; **does not survive roaming** (drops on
    IP change / sleep).
  - **Mosh** — survives roaming; **no native panes** (`tmux -CC` can't run over Mosh); needs
    `mosh-server` + a UDP port range.
  - **ET** — **panes *and* roaming together**; needs `etserver`/`etterminal` on the host + TCP
    2022 reachable; falls back to SSH if unavailable.
- Pure resolution logic (selected transport → attempt/fallback decision) lives in
  `Sources/SemicolynKit/` as Linux-tested helpers, replacing the implicit Mosh-wins branch in
  `ConnectionViewModel`.
- **No dependency on Track 2.** (Previously Auto's precedence was deferred to coordinate with
  the Track-2 Startup-command rework; with Auto gone, the Transport picker is independent and
  ET no longer waits on Track 2.)

## Data flow

```
connect → russh SSH session established
        → [Transport picker] ET selected (explicit per-host choice; no Auto)
        → probe etterminal + plant '<id>/<passkey>_<TERM>' | etterminal   (§3)
        → libetios builds et_config → et_connect(&cfg, &cbs, ctx)          (§1)
        → ET TCP stream established (libsodium secretbox)
   bytes: etserver ──▶ on_bytes ──▶ [hop to session queue] ──▶ ETSession.onOutput ──▶ ControlModeParser
                                    ──▶ TmuxRuntime ──▶ TmuxPaneContainer (native panes)
   input: keystrokes ──▶ ETSession.send ──▶ [serial queue] ──▶ et_send ──▶ etserver
   resize: SIGWINCH  ──▶ ETSession.setWindowSize ──▶ [serial queue] ──▶ et_set_window_size ──▶ etserver
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
- **`eternaltermlib`-level failures:** `et_connect` returns NULL only on synchronous argument
  failure; async failures (bad passkey, connect/handshake error) arrive via `on_end(reason)` on
  the transport thread. `et_send`/`et_set_window_size` signal failure with a negative `et_err`
  (`ET_ERR_CLOSED` / `ET_ERR_INVALID`), mapped to a Swift-visible reason.
- **Untrusted `on_end` reason:** the reason may be remote-supplied text — `libetios` sanitizes
  before logging or rendering it (§2), so a hostile server cannot inject into logs/UI.

## Testing

Per `docs/superpowers/specs/2026-06-18-testing-standards-design.md` (EP + BVA, assert
observable values, negative tests assert the *specific* failure):

- **`eternaltermlib` (Linux CI, own repo — DONE):** connect success/failure (bad passkey → specific error, not
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

- **No ET library existed** — ET is an application, not a library (CMake builds executables
  only; no exported headers). We built `eternaltermlib` (the missing library) first, as a
  fork we **maintain** (clean/documented/PR-shaped so it is upstreamable if MisterTea ever
  bites, but not counting on adoption — Blink's equivalent was never merged). *Done: shipped,
  CI-green.*
- **We wrap ET's *internal* C++ classes** — a bridge break is a build-time CI failure, not a
  user outage. Empirically low: over ~7 years post-2019, the wrapped surface had **one**
  public-signature break (`SocketHandler::readPacket`, and only if called directly — the normal
  `Connection::read` path is unchanged). The surface is near-frozen; churn is internal `.cpp`
  and formatting sweeps behind a stable contract.
- **Protocol v6 exact-match, no negotiation** — low-risk: unchanged since 2019, bumps only on
  major releases (~1 per 3 years). A future bump fails *loudly* (`MISMATCHED_PROTOCOL` with a
  clear message) and is **absorbed by the SSH fallback** (§4). Mitigation: periodically bump
  the vendored submodule, like `extern/mosh`.
- **Crypto: nonce is a per-message counter seeded by a 1-byte direction tag** — ~~needs a code
  read before shipping~~ **RESOLVED in `eternaltermlib`**: the library's security review
  (untrusted-input decode hardening + callback-pointer validation, commits `88cd74a`/`31fa474`)
  and its roaming/replay tests against a real `etserver` cover the reconnect path. Any residual
  crypto concern is now the library's, not semicolyn's.
- **License: ET is Apache-2.0, semicolyn is GPL-3.0-only** — Apache-2.0 → GPL-3.0 is one-way
  compatible (incorporate + preserve NOTICE). `eternaltermlib` shipped **Apache-2.0** (matching
  upstream ET, keeping it upstreamable) with ET's NOTICE preserved; semicolyn incorporating the
  resulting xcframework into its GPL-3.0 binary is the compatible direction. **Run the
  `license-audit` skill on the combined iOS binary before shipping** (per `eternaltermlib`'s own
  `docs/license-audit.md` gate).

## Open items (deferred to implementation / plan)

- ~~Auto-precedence order (Transport=Auto) — coordinate with Track 2~~ **RESOLVED 2026-07-12:
  Auto dropped** (explicit exclusive SSH/Mosh/ET per host, default SSH). Removes the Track-2
  coupling; ET no longer waits on Track 2.
- ~~Exact final `libet` C-ABI function list~~ **RESOLVED** — the shipped `eternaltermlib` ABI is
  fixed (see §1): `et_connect(&cfg,&cbs,ctx)` / `et_send` / `et_set_window_size` / `et_close`.
- ~~`libet` repo scaffolding: name, license, CI shape~~ **RESOLVED** — `ds7n/eternaltermlib`,
  Apache-2.0, Docker + `etserver` fixture, Linux + iOS-cross CI (green), TSan/ASan.
- xcframework size budget; ET jumphost relevance; roam/reconnect UX (reuse Mosh's banner).
  *(still open — implementation-phase)*
