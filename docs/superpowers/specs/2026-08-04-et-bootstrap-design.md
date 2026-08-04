<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# ET bootstrap (slice 1b), design

**Date:** 2026-08-04
**Status:** approved (brainstorm), pending implementation plan
**Slice of:** `docs/superpowers/specs/2026-07-10-et-transport-design.md` §3 (parent ET-transport spec)
**Depends on:** slice 1a `libetios` wrapper (merged `8cfd630`): `ETSession`, `ETConfig`, `validateETConfig`, `sanitizeEndReason`, `mapETState`.

## Purpose

Turn "ETSession exists but nothing feeds it" into a **real ET connection** on a host that runs
`etserver`. User-facing goal (stated by the user): ET must be **transparent**, pick ET for a
host, connect, get a terminal, exactly like SSH/Mosh, with no ET-specific knowledge required of
the user.

This slice plants the ET credential over the existing russh SSH session, reads back the
server's credential, builds a live `ETConfig`, and drives `ETSession` so its byte stream reaches
SwiftTerm.

## Correction to the parent spec (§3)

The parent §3 says: *"No response is needed back; the credential is self-generated."* This is
**wrong** against the authoritative ET source. `etterminal` (the vendored
`extern/eternaltermlib/extern/eternalterminal/src/terminal/TerminalMain.cpp`, and the client
`SshSetupHandler.cpp`) shows:

- The client generates a client `id`/`passkey` for the bootstrap command, but modern `etserver`
  **generates its own** `id`/`passkey` and prints `IDPASSKEY:<id>/<passkey>` on stdout
  (`TerminalMain.cpp:153,185`).
- The client **reads that line back** (`SshSetupHandler.cpp:91`, `find("IDPASSKEY:")`) and uses
  the **server's** `id`/`passkey` for the ET connection. The client-generated pair is a legacy
  fallback for old servers, marked by forcing `id[0..2] = 'X'`.

So this slice is a **request/response** bootstrap (like Mosh's `MOSH CONNECT` parse), not
fire-and-forget. This supersedes the parent §3 "no response needed" text; recorded in the
decision log.

## User decision (supersedes parent §4)

The user chose: on ET failure, **show an error with Retry/Cancel, NO silent fall-back to SSH**
(pure error + retry). This **supersedes** the parent §4 locked decision (silent SSH fallback +
banner, mirroring Mosh). The error+retry *UI* is the §4 slice; this slice's obligation is to
surface a **clean typed failure** (never a silent degrade) that the §4 slice renders.

## Scope

### In
- Generate a client `id` (16) + `passkey` (32) alphanumeric via the platform CSPRNG; force
  `id[0..2] = 'X'` (the upstream legacy-compat marker).
- Build the bootstrap command `echo '<id>/<passkey>_<TERM>' | etterminal --verbose=0` and run it
  over the **existing authenticated russh session** via the same `openExec` one-shot the
  Mosh/tmux bootstraps use (`Connection.openExec`).
- Capture the exec stdout (2s-guard race, mirroring `captureMoshBootstrap`) and **parse the
  `IDPASSKEY:<id>/<passkey>` line**, using the **server's** `id`/`passkey`.
- Build a live `ETConfig` (host, port 2022, server `id`/`passkey`, env incl. `TERM`,
  `cols`/`rows`) → `validateETConfig` → `ETSession(config:).start()`.
- Wire `ETSession.onOutput` bytes into SwiftTerm and route keystrokes / resize back through
  `send` / `setWindowSize`.
- On any bootstrap failure, surface a **typed `ETBootstrapError`** (no silent fallback).

### Out (later slices)
- **§4 probe + error/retry UI:** the failure banner/retry screen and any `etterminal`
  presence probe. This slice only produces the typed error.
- **§5 per-host Transport picker.** Until it exists, ET is reached via a temporary explicit
  entry point (a dev toggle or a direct call in `ConnectionViewModel`), not the polished picker.
- Jumphost bootstrap (upstream's `--jump`/`--dsthost` path). Out of scope; SSH-direct only.

## Architecture (mirrors the Mosh bootstrap)

```
ConnectionViewModel (App, macOS-CI) , ET selected, russh session authenticated
  │
  ▼
1. etGenerateCredential() ───────────► (id, passkey)                       [Kit, CSPRNG]
2. etBootstrapCommand(id:passkey:     ─► "echo 'XXX…/…_xterm-256color'      [Kit, pure]
     term:verbose:killPrefix:path:)       | etterminal --verbose=0"
3. conn.openExec(command:) ───────────► capture stdout, race a 2s guard    [App, russh one-shot]
4. parseETIDPASSKEY(stdout) ──────────► .ok(serverID, serverPasskey)       [Kit, pure]
                                         | .failure(ETBootstrapError)
5. etConnectConfig(host:port:id:      ─► ETConfig → validateETConfig        [Kit, pure; reuses 1a]
     passkey:term:cols:rows:)
6. ETSession(config:).start() ────────► onOutput → SwiftTerm.feed          [App, slice 1a]
   keystrokes / resize ───────────────► session.send / setWindowSize
   onEnd(reason) ─────────────────────► .handshakeFailed(sanitized reason)
```

**The repo rule:** every wrong-able branch is a pure Kit decider (Linux-tested); the App layer
is thin wiring (`openExec`, the `ETSession` lifecycle, SwiftTerm I/O), validated by macOS CI.

### Components, pure, Linux-tested (`Sources/SemicolynKit/ET/`)

**1. `etGenerateCredential()`**, CSPRNG credential.
```swift
struct ETCredential: Sendable, Equatable { let id: String; let passkey: String }  // id 16, passkey 32
func etGenerateCredential() -> ETCredential
// alphanumeric only (matches ET genRandomAlphaNum); id[0..2] == "X"; CSPRNG-backed
// (swift-crypto on Linux / SecRandomCopyBytes on Apple behind #if canImport(CryptoKit)).
```

**2. `etBootstrapCommand(...)`**, the exact remote command.
```swift
func etBootstrapCommand(id: String, passkey: String, term: String,
                        verbose: Int = 0, killPrefix: Bool = false,
                        etterminalPath: String? = nil) -> String
// "echo '<id>/<passkey>_<term>' | <etterminalPath ?? etterminal> --verbose=<verbose>"
// killPrefix prepends "pkill etterminal -u <user>; sleep 0.5; " (upstream kill flag). Default off.
```

**3. `parseETIDPASSKEY(_:)`**, read the server credential from untrusted stdout.
```swift
enum ETBootstrapError: Error, Equatable {
    case execFailed
    case noIDPASSKEY(serverOutput: String)   // serverOutput already sanitized
    case malformedIDPASSKEY
    case invalidConfig(ETConfigError)
    case handshakeFailed(reason: String)     // reason already sanitized
}
func parseETIDPASSKEY(_ stdout: String) -> Result<ETCredential, ETBootstrapError>
// finds "IDPASSKEY:" anywhere in stdout (mirrors upstream find()), extracts <16>/<32>.
// no line -> .noIDPASSKEY(sanitize(stdout)); wrong lengths / missing '/' -> .malformedIDPASSKEY.
```

**4. `etConnectConfig(...)`**, assemble the live config (reuses slice 1a).
```swift
func etConnectConfig(host: String, port: UInt16 = 2022, id: String, passkey: String,
                     term: String, cols: UInt16, rows: UInt16) throws -> ETConfig
// builds ETConfig (env = ["TERM": term]) then returns try validateETConfig(cfg).
```

### App wiring (macOS-CI-only)
- A `ConnectionViewModel` ET branch: generate credential, `openExec` the bootstrap (a
  `captureETBootstrap` mirroring `captureMoshBootstrap`), parse, build config, start `ETSession`,
  hook `onOutput` → SwiftTerm and keystroke/resize → `send`/`setWindowSize`.
- `onEnd(reason)` is routed through `sanitizeEndReason` (slice 1a) into `.handshakeFailed`.
- Temporary entry point until §5: a direct call / dev toggle; NOT the Transport picker.

## Error handling (typed, no silent fallback)

| Failure | Typed result |
|---|---|
| `openExec` won't open / SSH channel dies | `.execFailed` |
| stdout has no `IDPASSKEY:` (etserver missing, `.bashrc` noise) | `.noIDPASSKEY(serverOutput:)` |
| `IDPASSKEY:` malformed / wrong id/passkey length / no `/` | `.malformedIDPASSKEY` |
| `validateETConfig` rejects | `.invalidConfig(ETConfigError)` |
| ET TCP handshake fails after start (wrong passkey, port blocked) | `.handshakeFailed(reason:)` via `ETSession.onEnd` |

Each is a distinct case so the §4 slice can render "ET could not connect: <reason>" +
Retry/Cancel. **No degrade-to-SSH in this slice.**

## Security (credential-planting; treat as sensitive)

- `id`/`passkey` from a **CSPRNG**, never a non-cryptographic RNG. Charset alphanumeric
  (matches ET's `genRandomAlphaNum`).
- The `passkey` is a live secret embedded in the exec command string → **never logged**.
  Decision-point logging redacts it: log lengths/shape only (mirrors the predictor
  secret-exclusion discipline, `docs/superpowers/specs/2026-07-04-predictor-secret-exclusion-design.md`).
- The `IDPASSKEY:` line carries the live secret → **not logged verbatim**; log "parsed ok /
  failed", never the value.
- `.noIDPASSKEY`'s `serverOutput` is arbitrary remote text → **sanitized** (reuse slice 1a's
  `sanitizeEndReason`) before it reaches any log or the §4 UI.
- `.handshakeFailed`'s `reason` (from `ETSession.onEnd`) is already routed through
  `sanitizeEndReason`.

## Testing strategy

### Linux fast loop (`swift test`), the real coverage
Per `docs/superpowers/specs/2026-06-18-testing-standards-design.md`.

| Unit | Tier | Cases |
|---|---|---|
| `etBootstrapCommand` | Core | exact string for default (`--verbose=0`); TERM passthrough; `id[0..2]='X'` present; kill-prefix on/off; custom `etterminalPath`. Assert the **exact** command string. |
| `parseETIDPASSKEY` | **Critical** (parses a secret from untrusted output) | ✅ `IDPASSKEY:<16>/<32>` → exact id+passkey; embedded in surrounding server noise → still extracts; ❌ no line → `.noIDPASSKEY` (with sanitized output); ❌ id/passkey wrong length → `.malformedIDPASSKEY`; ❌ missing `/`; injection-laden output captured but sanitized, never executed. Assert the **specific** case + exact values. |
| `etConnectConfig` | Core | valid `ETConfig` (port 2022 default, TERM in env, cols/rows); round-trips `validateETConfig`; empty id/passkey → the specific `ETConfigError`. |
| `etGenerateCredential` | **Critical** (CSPRNG) | id length 16, passkey length 32; charset alphanumeric only; `id[0..2] == "X"`; two calls differ (not a constant/stub); backed by the platform CSPRNG. |

Every negative asserts the specific case; secret-bearing units assert exact values (no weak
predicates).

### macOS CI (compile + seam)
- App wiring compiles (the `ConnectionViewModel` ET branch, `captureETBootstrap`, `ETSession`
  I/O hookup).
- A bridge-style test drives the **capture → parse → config** seam against a **canned bootstrap
  stdout** (a fake `IDPASSKEY:` string), asserting the resulting `ETConfig` id/passkey match,
  reusing the slice-1a `SemicolynBridgeTests` fake pattern.

### Honest gap
A real end-to-end ET connect needs a live `etserver` host (or an sshd fixture with
`etterminal`/`etserver`, a possible future integration fixture like the Mosh one). This slice's
automated tests stop at the parse/config seam + the `ETSession` fake; the live handshake is a
device/integration pass. Green CI here means "bootstrap logic + wiring correct", NOT "ET
connects end-to-end".

## Non-goals / YAGNI
- No probe / error-retry UI (§4), only the typed error.
- No Transport picker (§5), a temporary explicit entry point.
- No jumphost bootstrap (`--jump`/`--dsthost`).
- No `serverfifo` / telemetry / config-file paths from upstream ET (`--serverfifo` etc.); a
  minimal `--verbose=0` invocation. Add `--serverfifo` only if a device pass shows it is needed.
