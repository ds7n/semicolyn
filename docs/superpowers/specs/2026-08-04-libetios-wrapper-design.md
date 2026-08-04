<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# `libetios` wrapper, design

**Date:** 2026-08-04
**Status:** approved (brainstorm), pending implementation plan
**Slice of:** `docs/superpowers/specs/2026-07-10-et-transport-design.md` §2 (parent ET-transport spec, branch `docs/et-transport-spec`, unmerged)
**Depends on:** `ETerminal.xcframework` (shipped PR #115, `ff0e674`) + `extern/eternaltermlib` submodule (`f3d544a`)

## Purpose

Make the already-linked `ETerminal.xcframework` actually usable from Swift. Today the app
links `eternaltermlib` (via the `SemicolynSSHCoreFFI` binaryTarget deps) but **no Swift code
calls the `et_*` C ABI**, it is dead-linked. This slice adds the thin Swift-drivable session
wrapper (`ETSession`) plus its pure decision helpers, turning "linked" into "drivable by a
test harness", without yet performing a real connection.

## Scope

### In
- An Obj-C++ `ETSession` over the `eternaltermlib` C ABI (`extern/eternaltermlib/include/eternaltermlib.h`):
  holds one `et_client`, delivers decrypted bytes / state / end to Swift closures, accepts
  `send` / `setWindowSize` / `close`, and **guarantees the ABI's serialization contract**
  (`et_send`/`et_set_window_size` never race `et_close`).
- Three pure, Linux-tested Kit deciders in `Sources/SemicolynKit/ET/`: an `ETConfig` value type
  + validator + env-array marshalling, an `on_end` reason sanitizer, and a defensive
  `et_state` → Swift enum map.
- The session speaks **bytes + size + lifecycle only**, the exact contract SwiftTerm already
  consumes from the SSH/tmux/Mosh paths, so the terminal view stays transport-agnostic.
- An `onFirstFrame` hook is *exposed* on `ETSession` (fires once on the first output byte,
  gated like `MoshSession.onFirstFrame`), for the fallback slice to bind later.

### Out (each its own later slice, per the parent spec)
- **§3 russh bootstrap:** generate `id`/`passkey`, plant the credential over the existing russh
  SSH session, build the live `ETConfig`. Not here, `ETSession` takes an already-built config.
- **§4 probe + fallback-to-SSH:** probe `etterminal` + port 2022, degrade to SSH with a banner.
  The `onFirstFrame`/`onEnd` **decision** (fallback vs crash-banner, mirroring
  `MoshExitDecision`) is deferred; only the *hook* exists here.
- **§5 per-host Transport picker.**
- `ConnectionViewModel` wiring beyond exposing the hooks a future VM binds.

## Boundary contract

The public surface a future caller (bootstrap slice / VM) gets:

```
ETSession(config: ETConfig,
          onOutput: (Data) -> Void,
          onState:  (ETConnectionState) -> Void,
          onFirstFrame: () -> Void,
          onEnd:    (String) -> Void)     // reason RAW/untrusted; caller sanitizes
  .start()                                       // et_connect, spawn transport thread
  .send(_ bytes: Data)                           // serialized on et.api
  .setWindowSize(cols:rows:width:height:)        // serialized on et.api
  .close()                                        // idempotent; drains + joins
```

## Architecture, the two-queue split

The wrapper owns **two queues with distinct jobs**:

```
                    ┌─────────────────────────────────────────┐
   Swift/VM ──────► │ ETSession (Obj-C++, App/ET/)             │
  send/resize/close │                                          │
                    │   private serial DispatchQueue "et.api"  │  ← ABI ordering
                    │   ├─ send   ─► guard !isClosed ─► et_send │
                    │   ├─ resize ─► guard !isClosed ─► et_set… │
                    │   └─ close  ─► isClosed=true; et_close;   │
                    │                handle=NULL (idempotent)   │
                    │                                          │
                    │   et_client handle ──► eternaltermlib    │
                    └──────────────┬───────────────────────────┘
                                   │ callbacks on ET's transport thread
                                   ▼
              on_bytes/on_state/on_end (C ctx = ETSession*)
                                   │  copy buffer HERE (valid only in-call)
                                   │  read isClosed
                                   ▼
                    dispatch_async(main) ──► Swift closures ──► SwiftTerm
```

### Why two queues, not one
- **`et.api` (private serial)** is the **serialization point**: every `send`/`resize`/`close`
  runs here, so *by construction* no `et_send` executes after the `close` block. This is the
  C ABI's "must not race `et_close`" guarantee, owned by the wrapper, not the library.
- **main queue** is where callbacks deliver to Swift, so SwiftTerm/UIKit is touched safely,
  exactly the `MoshSession.mm` shape.

The main queue is deliberately *not* used as the serialization point: you cannot block the main
queue draining in-flight sends on teardown, and the ABI needs a queue you fully control for
ordering. The split is the crux of the design.

### Rejected alternative, Swift `actor` as the serial point
Considered making a Swift `actor ETSession` the serialization point (all `send`/`resize`/`close`
actor-isolated `async`). Rejected: the C handle would live behind an actor while callbacks
arrive on a C transport thread, forcing an `await`/`Task` hop **into** the actor at the byte
hot-path. A private serial `DispatchQueue` in Obj-C++ keeps ordering at the ABI boundary where
the handle lives, with no async ceremony at the C boundary, and matches the existing
`MoshSession` precedent.

### Critical rules baked in
1. **`on_bytes` copies its buffer inside the C callback** (into `NSData`/`Data`) *before* the
   async hop, the ABI says `buf` is valid only for the duration of the callback.
2. Callbacks read `isClosed` and **drop if set**, so no Swift closure fires after `close()`.
3. `ctx` passed to `et_connect` is the `ETSession*`; the C callback trampolines cast it back.
   `ETSession` outlives the handle: `close()` joins the transport thread (inside `et_close`)
   **before** the object can dealloc, so no trampoline fires into freed memory.

### File placement
- `App/ET/ETSession.h` + `App/ET/ETSession.mm`, Obj-C++, macOS-CI-only, mirroring `App/Mosh/`.
- `Sources/SemicolynKit/ET/`, the three pure deciders (Linux-tested).

## Components

### Pure, Linux-tested (`Sources/SemicolynKit/ET/`)

**1. `ETConfig` + validator + env marshalling**, the flat-array seam.
```swift
struct ETConfig: Sendable, Equatable {
    var host: String
    var port: UInt16          // 0 kept as 0; the C ABI maps 0 → default 2022
    var id: String            // 16-char bootstrap client id
    var passkey: String       // 32-char bootstrap secretbox key
    var env: [String: String] // must include TERM
    var cols: UInt16
    var rows: UInt16
    var width: UInt16         // 0 = unknown
    var height: UInt16        // 0 = unknown
    var keepaliveSecs: Int32  // 0 = ET default (5)
}

enum ETConfigError: Error, Equatable {
    case emptyHost, emptyID, emptyPasskey, missingTERM
}

// Validate at the boundary; throws the SPECIFIC typed error for invalid input.
func validateETConfig(_ cfg: ETConfig) throws -> ETConfig

// Deterministic (sorted-key) parallel arrays for the C ABI's env_keys/env_vals.
func etEnvArrays(_ env: [String: String]) -> (keys: [String], vals: [String])
```
The `.mm` reads the *validated* config and fills the C `et_config`, pinning the parallel arrays
for the duration of the `et_connect` call (the ABI deep-copies, so they may be freed on return).

**2. `on_end` reason sanitizer**, the security seam (parent §1 security note).
```swift
// nil → "connection ended". Strips C0/C1 control + CSI/OSC sequences and markup;
// truncates to a fixed max length. The reason may be remote-server-supplied → UNTRUSTED.
func sanitizeEndReason(_ reason: String?) -> String
```
The `.mm` calls this **before** the reason reaches any log or banner.

**3. `ETConnectionState`**, the defensive state map.
```swift
enum ETConnectionState: Sendable, Equatable {
    case connecting, connected, roaming, disconnected
    case unknown(Int32)
}
// 0-3 → the named cases; any other int → .unknown(raw), never a crash.
func mapETState(_ raw: Int32) -> ETConnectionState
```

### Macro-glue, macOS-CI-only (`App/ET/ETSession.mm`)
Dispatch orchestration, buffer-copy, the `isClosed` guard, the C-callback trampolines, and the
`et_config` fill. **No branching logic lives here** that is not one of the three deciders above,
that rule is what keeps the `.mm` thin and keeps every wrong-able branch under Linux tests.

## Data flow, error handling, lifecycle

### Connect → stream → teardown
1. Caller builds `ETConfig` → `validateETConfig` (throws `ETConfigError` **before** any C call).
2. `ETSession(config:…)` → `start()` dispatches `et_connect(&cfg, &cbs, self)` on `et.api`.
   Non-blocking; the transport thread spawns.
3. **Output:** `on_bytes` (transport thread) → copy to `Data` → read `isClosed` →
   `dispatch_async(main)` → `onOutput(Data)` → `terminalView.feed`. The first byte also fires
   `onFirstFrame` exactly once.
4. **Input:** `send(Data)` / `setWindowSize(…)` → `dispatch_async(et.api)` → `guard !isClosed`
   → `et_send` / `et_set_window_size`.
5. **State:** `on_state` → `mapETState` → main → `onState(ETConnectionState)`. `.roaming`
   surfaces so the UI can show a reconnecting hint (reusing the Mosh banner in a later slice).
6. **Teardown:** `close()` → `dispatch_async(et.api)` block: `isClosed = true; et_close(handle);
   handle = NULL`. Idempotent (guard on entry). Same serial queue ⇒ every prior send has already
   run and no later send will.

### Error handling (typed, at boundaries)
| Failure | Handling |
|---|---|
| Bad config (empty host/id/passkey, missing TERM) | `validateETConfig` throws the specific `ETConfigError` **before** `et_connect` |
| `et_connect` returns NULL (synchronous arg failure) | `start()` surfaces a typed `ETStartError`; no thread spawned |
| Async handshake failure (e.g. wrong passkey) | arrives via `on_end(reason)` → `onEnd(reason)` RAW; the .mm does not sanitize |
| `et_send`/`et_set_window_size` returns negative `et_err` | logged (file-verbose), non-fatal; the caller's keystroke is dropped |
| Untrusted `on_end(reason)` | the .mm forwards raw; the Swift consumer sanitizes via `sanitizeEndReason` (unit-tested) before any log or banner |
| Callback after `close()` | dropped by the `isClosed` guard before touching Swift |

### Lifecycle / roaming
On background/foreground, ET's own resume handles the network; the wrapper keeps the handle
**alive** across suspension (never `close()` on a `scenePhase` transition), mirroring the Mosh
"don't interfere with roaming" rule. A true non-resumable death → `on_end` → `onEnd`.

### Memory safety
`ctx = ETSession*` (unretained in C). `close()` joins the transport thread (inside `et_close`)
before the object can dealloc, so no trampoline fires into freed memory. The owner (a future VM)
holds the `ETSession` strongly for the session's life.

## Testing strategy

### Linux fast loop (`swift test`), the real coverage
Per `docs/superpowers/specs/2026-06-18-testing-standards-design.md`: EP + BVA, assert observable
values (no tautologies), negative tests assert the *specific* failure.

| Unit | Tier | Cases |
|---|---|---|
| `validateETConfig` | Core | ✅ valid config; ❌ empty host / empty id / empty passkey / missing TERM → assert the **specific** `ETConfigError` case. Port 0 accepted; cols/rows boundary values. |
| `etEnvArrays` | Core | Empty env → empty arrays; single entry; multi → keys/vals **parallel & index-aligned** (assert exact pairing + deterministic sorted order); TERM present. |
| `sanitizeEndReason` | **Critical** (untrusted input) | `nil` → `"connection ended"`; CSI/OSC injection stripped; `\r`-overwrite stripped; markup stripped; over-long truncated to the **exact** max; a clean string passes through unchanged. Each asserts the exact output string. |
| `mapETState` | Trivial+ | 0 → `.connecting`, 1 → `.connected`, 2 → `.roaming`, 3 → `.disconnected`; `7` → `.unknown(7)`; `-1` → `.unknown(-1)`. |

Every negative test asserts the specific failure/output, no "it didn't crash" tautologies.

### macOS CI (compile + smoke), the only Apple signal
- `ETerminal.xcframework` links; the `App` target compiles with `ETSession.mm`.
- A bridge-test target (mirroring the Mosh `SemicolynBridgeTests`) drives `ETSession` against a
  **fake `et_client`** loopback and asserts:
  1. bytes sent via `send()` echo back through `onOutput`;
  2. `onFirstFrame` fires **exactly once** across all output bytes;
  3. `close()` is idempotent and **no callback fires after it**;
  4. a callback delivering a raw injection string reaches `onEnd` **RAW/verbatim**, the wrapper
     does not sanitize; `sanitizeEndReason` is unit-tested separately (see the Linux table above)
     and applied by the consumer.
- This is the only place the queue-hop + buffer-copy + `isClosed` guard get exercised.

### Honest gaps (not covered here)
A real `etserver` handshake and true roaming need a live host, deferred to a device/integration
pass in the bootstrap (§3) and fallback (§4) slices. Green CI here means "the wrapper is
correctly wired and serialized", **not** "ET works end-to-end".

## Non-goals / YAGNI
- No `onFirstFrame` **degradation decision** (fallback vs crash-banner), hook only; decider lands in §4.
- No live `ETConfig` from a real bootstrap, §3.
- No Transport picker, no per-host mode selection, §5.
- No port-forwarding / jumphost (out of `eternaltermlib`'s own scope).
