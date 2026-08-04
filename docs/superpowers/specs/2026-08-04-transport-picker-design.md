<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Per-host Transport picker + ET interactive, design

**Date:** 2026-08-04
**Status:** approved (brainstorm), pending implementation plan
**Slice of:** `docs/superpowers/specs/2026-07-10-et-transport-design.md` §5 (per-host Transport picker), plus the ET input/resize wiring deferred from slice 1b.
**Depends on:** slice 1a (`ETSession`, merged `8cfd630`) + slice 1b (`attachET`, `ETBootstrapError`, merged `0f1b422`).

## Purpose

Make the connection transport an **explicit per-host user choice** (SSH / Mosh / ET, exactly
one, default SSH), and make ET a **usable interactive terminal** (typing + resize wired), so ET
can be tested end-to-end on device against a real `etserver`.

User decisions driving this slice:
- **Connection type is explicitly chosen by the user** (not auto-selected). This is the parent
  spec's §5, built now.
- **On failure of the chosen transport: show the error, no silent fallback** (consistent for all
  three transports). Reuse the existing `.failed` state for the message in this slice; a
  dedicated Retry/Cancel screen is deferred.

## Scope

### In
1. **`Transport` field on the host** (SSH / Mosh / ET, exactly one, default SSH), stored via the
   existing `Inherited<T>` three-state pattern, edited in the host editor + Defaults editor.
2. **Explicit connect routing:** `connect()` dispatches on the resolved transport, replacing the
   implicit "Mosh silently wins" branch. Each transport's connect failure surfaces `.failed`
   with its reason (no silent cross-transport fallback).
3. **ET interactive:** wire keystrokes into `sendTerminalInput` (the `etSession` arm) and resize
   into a `setETClientSize`, so ET accepts input and reflows.

### Out (later slices)
- A dedicated ET Retry/Cancel error screen (this slice reuses the existing `.failed` banner).
- ET roaming UX (reuse the Mosh banner later), jumphost bootstrap.
- Probe (checking `etterminal` presence before connecting): the connect attempt itself surfaces
  the typed error, which is sufficient for this slice.

### Behavior change to flag (intended)
Today a Mosh-enabled host that fails to bootstrap **silently falls through to SSH**. Under
explicit choice, Mosh-explicit-but-failed becomes a visible `.failed` (matching the no-silent-
fallback decision). This alters current Mosh behavior deliberately.

## Transport model (pure, Linux-tested, `Sources/SemicolynKit/Model/`)

```swift
public enum Transport: String, Codable, Sendable, CaseIterable {
    case ssh, mosh, et
}
```

Add to `Host` and `Defaults`: `public var transport: Inherited<Transport>` (same three-state
`Inherited<T>` pattern as every other host field). Old saved hosts have no `transport` key in
their JSON, so it decodes as `.inherited` (backward compatible, no migration script).

**The single decision point (replaces "Mosh silently wins"):**
```swift
public func resolveTransport(host: Host, defaults: Defaults) -> Transport
// precedence:
//   1. explicit host.transport
//   2. explicit defaults.transport
//   3. LEGACY MIGRATION: resolveMoshEnabled(host, defaults) == true  -> .mosh
//   4. default .ssh
```
The legacy-mosh migration keeps existing Mosh hosts on Mosh without any stored `transport`
field. Pure function, fully Linux-tested.

## Connect routing + input/resize wiring (App, macOS-CI-only)

**Dispatch** (both connect call sites, currently `if await attachMoshIfPossible {return}` at
`App/ConnectionViewModel.swift:1458` and `:1533`) becomes an explicit switch:
```swift
switch resolveTransport(host: host, defaults: defaults) {
case .et:
    switch await attachET(conn: conn, host: host, defaults: defaults) {
    case .success: return
    case .failure(let e): state = .failed(etFailureMessage(e)); return   // no fallback
    }
case .mosh:
    if await attachMoshIfPossible(conn: conn, host: host, defaults: defaults) { return }
    state = .failed("Mosh could not connect."); return                   // no silent SSH slide
case .ssh:
    try await attachSSHShell(conn: conn, host: host, defaults: defaults)
}
```

`etFailureMessage(_ e: ETBootstrapError) -> String` is a pure Kit helper mapping each error case
to a readable line ("Eternal Terminal could not connect: <reason>"), Linux-tested. `attachET`
already returns the typed `ETBootstrapError` from slice 1b (its `serverOutput`/`reason` are
already sanitized).

**Input wiring** (the SACRED-PATH router `sendTerminalInput`): add the `etSession` arm first,
transport write before anything else, matching the existing structure:
```swift
if let etSession {
    etSession.send(Data(bytes))
} else if let moshSession {
    moshSession.writeInput(Data(bytes))
} else if let tmux {
    tmux.sendInput(bytes)
} else {
    rawWriter?.enqueue(bytes)
}
```

**Resize wiring** (mirror `setMoshClientSize`, since ET like Mosh has no `ShellSession` so the
default `session?.resize` is a no-op):
```swift
func setETClientSize(cols: Int, rows: Int) {
    etSession?.setWindowSizeCols(UInt16(cols), rows: UInt16(rows), width: 0, height: 0)
}
```
Routed from `TerminalScreen`'s debounced resize the same way `setMoshClientSize` is.

**Teardown:** `etSession?.close(); etSession = nil` in `teardown()` (added in slice 1b; keep).

## Host editor UI (App, macOS-CI-only)

- A **Transport `Picker`** at the top of the connection section in `HostEditorSections.swift`,
  mirroring the existing three-state `Picker` used for compression/forwardAgent. Options SSH /
  Mosh / ET; default SSH.
- A one-line description per selected option (from the parent §5 guidance): SSH "works
  everywhere; native panes; does not survive roaming"; Mosh "survives roaming; no native panes;
  needs mosh-server + a UDP port range"; ET "panes and roaming; needs etserver on the host + TCP
  2022; connect failure is surfaced, not silently switched".
- The existing Mosh section (server path / UDP range / prediction) stays and applies when Mosh
  is the chosen transport. The picker governs *which* transport is used; the legacy "mosh
  enabled" state maps to the picker showing `.mosh` (resolver migration keeps old data working).
- The **Defaults editor** gets the same picker (a global default transport).

## Testing strategy

### Linux fast loop (`swift test`), the real coverage
| Unit | Tier | Cases |
|---|---|---|
| `resolveTransport` | Core | host-explicit ssh / mosh / et each win; defaults-explicit used when host inherits; legacy migration (mosh.enabled true, no transport set → `.mosh`); nothing set → `.ssh`. Assert the exact `Transport`. |
| `etFailureMessage` | Core | each `ETBootstrapError` case (execFailed / noIDPASSKEY / malformedIDPASSKEY / invalidConfig / handshakeFailed) → its exact readable string; the sanitized reason is passed through. |
| `Transport` Codable + Host back-compat | Trivial+ | `Transport` round-trips through JSON; a `Host` JSON *without* a `transport` key decodes with `transport == .inherited` (no crash, no data loss). |

Every negative/edge asserts the exact value. No tautologies.

### macOS CI (compile)
The editor picker, the Defaults picker, the connect switch, `setETClientSize`, and the
`sendTerminalInput` ET arm all compile; the app builds.

### Device (the payoff, first real end-to-end)
Set a host's Transport = ET and connect to a box with sshd + etserver running (this dev host is
now configured: sshd on :22, etserver on :2022, ET v7.0.0). Verify:
- ET connects (handshake succeeds), output renders.
- Typing works (keystrokes reach the remote shell).
- Rotation / keyboard show-hide reflows the terminal (resize wired).
- A host pointed at a port with no etserver shows the `.failed` ET message (not a silent SSH
  fallback, not a hang).

### Honest gap
The real ET handshake against etserver v7.0.0 is verified for the FIRST time on device (no CI
server). Our vendored client is `et-v6.0.2-374-gdfc75d663` with `PROTOCOL_VERSION = 6`; the
server is marketing-version 7.0.0. Protocol version (not marketing version) is what must match,
and it is expected compatible, but a `MISMATCHED_PROTOCOL` at this step is the risk to watch, and
would be addressed then (re-pin the vendored client, or confirm the server's protocol version).

## Non-goals / YAGNI
- No dedicated Retry/Cancel screen (reuse `.failed`).
- No Auto transport mode (explicit choice only, per the parent §5 decision).
- No probe-before-connect; the connect attempt's typed error is enough.
- No ET roaming banner / jumphost this slice.
