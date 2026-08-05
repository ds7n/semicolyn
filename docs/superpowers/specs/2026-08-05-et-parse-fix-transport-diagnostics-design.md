<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Eternal Terminal IDPASSKEY parse fix + transport diagnostics, design

**Date:** 2026-08-05
**Status:** approved (brainstorm), pending implementation plan
**Fixes:** device bug, an Eternal Terminal connect fails with "the server sent a malformed credential" (`.malformedIDPASSKEY`) despite a valid server response.
**Depends on:** slices 1a (`8cfd630`) + 1b (`0f1b422`) + Transport picker (`87edea3`).

## Root cause (measured, not inferred)

Confirmed from a real `etserver` v7.0.0 bootstrap on the dev host + the upstream ET source:

- The server's `IDPASSKEY` line is well-formed (`IDPASSKEY:<16-char id>/<32-char passkey>`, one slash, all alphanumeric).
- Our `parseETIDPASSKEY` takes the marker's line **up to the next newline** and requires the WHOLE line to be exactly `<16>/<32>` (`parts.count == 2 && parts[0].count == 16 && parts[1].count == 32`).
- Upstream ET (`SshSetupHandler.cpp:105`) instead does `sshBuffer.substr(passKeyIndex + 10, 16 + 1 + 32)`, a **fixed 49-character window** immediately after `IDPASSKEY:`, and ignores anything before or after.
- So any trailing content on the credential line (a `\r` from the SSH PTY, a status token, or shell-init noise like the observed `bash: cannot set terminal process group`) makes our line-exact parse fail where upstream succeeds. That is the bug.

**Diagnosis was slowed by a real gap:** the default `connect` logging scrubs the raw `IDPASSKEY` payload as a secret, so the exact malformation was invisible in the device logs (which only recorded `malformedIDPASSKEY`). This slice closes that gap too.

## Scope

### In
1. **Parser fix:** `parseETIDPASSKEY` adopts the upstream fixed-49-char-window behavior, tolerant of surrounding/trailing content, while still validating lengths + charset + slash position.
2. **`transport` diagnostics category** (a new `LogCategory`, default OFF) that carries the raw-but-MASKED bootstrap payload the always-on `connect` category scrubs.
3. **A pure `maskBootstrapPayload` helper** (Linux-tested) that masks credential VALUES but keeps structure + surrounding/trailing content visible, so a parse malformation is diagnosable without logging the live secret.
4. **Wire `.transport` logs** at the `attachET` parse site + `captureETBootstrap` (masked payload, on success AND failure).

### Out (later / separate)
- Mosh adopting `maskBootstrapPayload` (the shared helper + category exist; Mosh wiring is a later touch).
- The protocol-version-mismatch case (server marketing 7.0.0 vs vendored client `PROTOCOL_VERSION = 6`). NOTE: the binary contains "Mismatched protocol versions"; that is a HANDSHAKE-stage failure that would surface as `.handshakeFailed` on the stream AFTER a successful parse, NOT as `.malformedIDPASSKEY`. It is a real future risk to watch on the device retest, but it is not this bug and is out of scope here.
- The on-connect-command feature (separately parked, `on-connect-command-todo-2026-08-05`).
- Any Diagnostics UI beyond the one auto-rendered toggle.

## The parser fix

Current (buggy) `parseETIDPASSKEY` in `Sources/SemicolynKit/ET/ETBootstrap.swift`:
```swift
let afterMarker = stdout[range.upperBound...]
let line = afterMarker.prefix { $0 != "\n" && $0 != "\r" }   // TOO STRICT: whole line
let parts = line.split(separator: "/", omittingEmptySubsequences: false)
guard parts.count == 2, parts[0].count == 16, parts[1].count == 32 else { ... }
```

New behavior (mirrors upstream's fixed window, tolerant of trailing/surrounding junk):
- Find `IDPASSKEY:` anywhere (unchanged; no marker → `.noIDPASSKEY(sanitized)`).
- Take the **49 scalars** immediately after the marker (`16 + 1 + 32`). If fewer than 49 remain → `.malformedIDPASSKEY`.
- Require scalar[16] == `/`; id = scalars[0..<16], passkey = scalars[17..<49].
- Require id (16) and passkey (32) are **all alphanumeric** (matches ET's `genRandomAlphaNum`; this keeps garbage rejecting, e.g. if the 49-window landed on a banner).
- On success → `ETCredential(id, passkey)`. On any check failing → `.malformedIDPASSKEY`.

This still rejects genuinely malformed input (short response, non-alphanumeric window, wrong slash position) but accepts a valid credential followed by trailing content, which upstream accepts and we were wrongly rejecting.

## The `transport` diagnostics category

- Add `case transport` to `LogCategory` (`App/LogCategory.swift`) with a description like: "Raw transport handshake structure (Eternal Terminal IDPASSKEY, Mosh connect). Credential values are masked. Verbose, off by default." **NOT** added to `defaultEnabled`.
- The Diagnostics screen renders it automatically (`DiagnosticsSettingsView.swift:144`, `ForEach(LogCategory.allCases)`), so it gets a toggle for free; its `description` is the subtitle.

### `maskBootstrapPayload` (pure, Kit, Linux-tested)
`Sources/SemicolynKit/ET/ETBootstrapMask.swift`:
```swift
// Mask credential VALUES, keep structure + surrounding/trailing content visible.
public func maskBootstrapPayload(_ raw: String) -> String
```
Behavior for an Eternal Terminal response:
- If `IDPASSKEY:` is present: emit `IDPASSKEY:<id:N>/<key:M>` where N/M are the actual byte counts of the 16/32 windows found, followed by `[len=<total-after-marker> trailing=<repr>]` where `trailing` is a control-char-safe repr (`\r`, `\xNN`) of any bytes on the line after the 49-char window, and any leading bytes before the marker are shown as `leading=<repr>`.
- If no `IDPASSKEY:` marker: emit `no-marker len=<n> content=<repr>` (a repr of the whole payload, which is non-secret in that case, it is server error text; still run it through the existing `sanitizeEndReason` first so ANSI/markup can't leak).
- The actual id/passkey characters are NEVER emitted. Only lengths, delimiters, and non-credential surrounding bytes.

This is exactly what diagnoses a trailing-junk / banner / CRLF malformation without logging the live credential.

### Wiring
In `App/ConnectionViewModel.swift`:
- At the `attachET` parse site: one `DebugLog.shared.log(.transport, "et: bootstrap payload " + maskBootstrapPayload(stdout))` on BOTH the success and failure branches of `parseETIDPASSKEY`.
- In `captureETBootstrap`: a `.transport` line with `maskBootstrapPayload(capturedStdout)` after capture.
- The existing `.connect` lines (`et: IDPASSKEY parse FAILED (...)`, `parsed ok`) stay as-is (they never carried the secret).

## Testing strategy

### Linux fast loop (`swift test`), the real coverage
| Unit | Tier | Cases |
|---|---|---|
| `parseETIDPASSKEY` (fixed) | **Critical** (parses a secret from untrusted output) | exact `IDPASSKEY:<16>/<32>` → success (exact id+passkey); **trailing `\r`** after the 32 → success; **trailing ` extra=1`** → success; **leading banner** before the marker → success; embedded-in-noise → success; ❌ fewer than 49 chars after marker → `.malformedIDPASSKEY`; ❌ scalar[16] != `/` → `.malformedIDPASSKEY`; ❌ non-alphanumeric in the id/passkey window → `.malformedIDPASSKEY`; ❌ no marker → `.noIDPASSKEY(sanitized)`. Assert exact values / specific case. |
| `maskBootstrapPayload` | **Critical** (must NOT leak the credential) | a valid payload → output contains `<id:16>/<key:32>` and the byte lengths but NOT the actual id/passkey substrings (assert the raw id/passkey chars are absent from the output); trailing `\r`/junk shown in `trailing=`; leading banner shown in `leading=`; no-marker → the sanitized content repr, no crash; a payload whose credential chars happen to appear, assert the mask still does not emit them verbatim. |

Every negative asserts the specific case; the mask tests assert the credential is ABSENT from the output (the security property).

### macOS CI (compile)
The new `.transport` `LogCategory` case, the Diagnostics toggle (auto), and the `.transport` log calls compile; the app builds.

### Device (the payoff)
With this build: retry the Eternal Terminal connect against the dev host (etserver v7.0.0 up). Expected: **it now connects** (parser fix). If it still fails at any stage, flip Settings → Diagnostics → `transport` ON, reproduce, and the masked payload line shows the exact malformation (or, if it is now a `.handshakeFailed`, that confirms the separate protocol-version issue and we address that next).

## Non-goals / YAGNI
- No un-masked credential logging (masking is mandatory; the value never hits the log).
- No Mosh wiring of the helper this slice.
- No protocol-version-mismatch handling (separate, watch-item).
- No new Diagnostics UI beyond the auto-rendered toggle.
