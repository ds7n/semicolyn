<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# ET `onEnd` clean-exit fix, design

**Status:** approved (2026-08-05). Follow-up slice after PR #120 (ET parse fix + UAF
crash fix + connect watchdog) merged as `9a7275a`.

## Problem

Device round 3 (build off PR #120) confirmed the crash, spin, and malformed-credential
fixes and reached a working Eternal Terminal session: it connected, `onFirstFrame`
fired, and typing reached the remote shell. The user then typed `exit`. The shell ended,
but the app **kept the terminal view up and silently swallowed further keystrokes**
instead of gracefully ending the session. Only a manual back-out resolved it.

### Root cause (verified in source)

In `attachET`'s `onEnd` closure (`App/ConnectionViewModel.swift`, added in the watchdog
slice), the outcome transition is guarded by `if !self.etResolved`. A successful session
sets `etResolved = true` inside `onFirstFrame`. So when a clean `exit` fires `onEnd`:

- `etSession` is closed and nil'd (correct), but
- `etResolved` is already `true`, so the guarded block **never runs**: it sets neither
  `.failed` nor any dismissal.

The result: `state` stays `.shell` forever. The terminal view stays mounted; because
`etSession` is now `nil`, `sendTerminalInput` falls through to a no-op `rawWriter`, so
keystrokes are accepted-then-dropped. There is no graceful end.

Note: the earlier memory phrased the cause as "`onEnd` sets `.failed` for EVERY end."
The observed symptom (keeps accepting input, never dismisses) is real, but the actual
mechanism is "`onEnd` does *nothing* to state once first-frame was seen," not a spurious
`.failed`.

## Precedent

The Mosh transport already solved the analogous problem with a pure, Linux-tested
`moshExitDecision(reason:elapsed:)` in `Sources/SemicolynKit/Mosh/MoshExitDecision.swift`,
consumed by the Mosh `onEnd`. Mosh deliberately dropped a first-frame discriminator
because real mosh renders an init framebuffer *before* the UDP handshake confirms, so
`onFirstFrame` is not a reliable success signal there; it classifies on `(reason, elapsed)`
instead.

**ET is different:** ET's `onFirstFrame` fires only when the ET stream is genuinely up, so
it *is* a reliable success signal. ET's decision therefore keys on **whether first-frame
was ever seen**, which is simpler and does not depend on server-supplied reason text for
the graceful/failure split.

## Decisions

1. **Clean-exit UX = dismiss to the connection list.** On a clean end after first-frame,
   tear the session down and return to the host/connection list with no banner. The
   session genuinely ended; there is nothing to recover (unlike the tmux mid-session
   crash banner, which offers Reattach / Start-new against a still-alive SSH transport,
   irrelevant to ET). Scoped to ET only; the latent SSH `exit` → `.failed("Session
   closed")` behavior is out of scope for this slice.

2. **Classification = first-frame seen.** If `onFirstFrame` fired, ANY subsequent end
   (including a mid-session network drop) is a graceful dismiss. If first-frame never
   fired, the end is a pre-connect failure → the `.failed` handshake banner. The reason
   string is used only for the failure-path banner text, never to split graceful vs
   failure (avoids keying UX off an untrusted, server-supplied string).

## Design

### 1. New pure Kit decider

`Sources/SemicolynKit/ET/ETExitDecision.swift` (Linux-tested), mirroring
`MoshExitDecision`:

```swift
/// How an ET session end should be handled by `ConnectionViewModel`. Pure +
/// Linux-tested so the decision is covered off the Apple-only bridge gate.
///
/// Unlike Mosh (which cannot trust its pre-handshake init frame and classifies on
/// reason + elapsed), ET's `onFirstFrame` fires only when the stream is genuinely
/// up, so first-frame IS a reliable success signal: once seen, any later end is a
/// normal session end.
public enum ETExitDecision: Equatable, Sendable {
    /// A real session ran (first-frame seen) and then ended → graceful teardown
    /// to the connection list. No error banner.
    case dismiss
    /// First-frame never fired → the handshake never came up → `.failed` banner,
    /// carrying the sanitized reason string for display.
    case handshakeFailed(String)
}

/// Classify an ET session end.
/// - Parameters:
///   - reason: the raw `onEnd` reason (UNTRUSTED, possibly server-supplied). Only
///     consulted on the failure path; sanitized here before it can reach the UI.
///   - sawFirstFrame: whether `onFirstFrame` fired for this session.
public func etExitDecision(reason: String?, sawFirstFrame: Bool) -> ETExitDecision {
    sawFirstFrame ? .dismiss : .handshakeFailed(sanitizeEndReason(reason))
}
```

Sanitization happens inside the decider so the untrusted reason is never handed to the
banner raw. `sanitizeEndReason` already exists (`ETEndReason.swift`) and strips ANSI /
control bytes / angle-bracket markup and truncates.

### 2. Track first-frame on the VM

Add `private var etFirstFrameSeen = false` (mirrors the existing `moshFirstFrameSeen`):

- Set `etFirstFrameSeen = true` in `sess.onFirstFrame`.
- Reset `etFirstFrameSeen = false` in `teardown()` (alongside the existing `etResolved =
  false`).

### 3. Rewrite the `onEnd` body

Route on `etExitDecision(reason:sawFirstFrame:)`:

- **`.dismiss`** → run the graceful-dismiss path: `teardown()` then `state = .idle`
  (the exact mechanism `disconnect()` uses). `teardown()` already cancels the watchdog,
  closes + nils `etSession`, and resets all flags; `state = .idle` returns the view to
  the host list. This stops input and dismisses. No banner.
- **`.handshakeFailed(msg)`** → keep the current failure behavior: `etSession?.close()`,
  `etSession = nil`, `state = .failed(etFailureMessage(.handshakeFailed(reason: msg)))`.

**Resolve-once interaction (the one subtle bit):** the current guard *skips* `onEnd`'s
outcome entirely when `etResolved` is `true`. That is exactly the case we now need to
handle for a graceful end. The fix keys the branch on `etFirstFrameSeen` instead:

- `etFirstFrameSeen == true` → `.dismiss` (a real session ended, even if the watchdog
  had also cancelled). Safe to teardown + `.idle`.
- `etFirstFrameSeen == false` but a **watchdog timeout already set `.failed`** → a late
  `onEnd` (enqueued before the callback was niled) must NOT clobber that `.failed` with a
  second, possibly weaker banner. Guard this with the existing resolve flag: if the
  watchdog already resolved (first-frame never seen AND `etResolved == true`), bail.
- `etFirstFrameSeen == false` and not yet resolved → the normal pre-connect failure:
  set `etResolved = true` and `.failed`.

Concretely, `onEnd` becomes:

```swift
sess.onEnd = { [weak self] reason in
    guard let self else { return }
    self.etWatchdog?.cancel(); self.etWatchdog = nil
    switch etExitDecision(reason: reason, sawFirstFrame: self.etFirstFrameSeen) {
    case .dismiss:
        DebugLog.shared.log(.transport, "et: session ended cleanly (first-frame seen) → dismiss to list")
        self.teardown()          // closes+nils etSession, resets flags, cancels watchdog
        self.state = .idle
    case .handshakeFailed(let msg):
        // First-frame never fired. If the watchdog already resolved to a timeout
        // .failed, a late onEnd must not clobber it.
        if self.etResolved {
            DebugLog.shared.log(.transport, "et: onEnd after watchdog already resolved → ignored")
            return
        }
        self.etResolved = true
        DebugLog.shared.log(.transport, "et: session ended pre-first-frame (\(msg)) → .failed")
        self.etSession?.close()
        self.etSession = nil
        self.state = .failed(etFailureMessage(.handshakeFailed(reason: msg)))
    }
}
```

The `msg` is already sanitized inside `etExitDecision`, so the `.transport` log line and
the banner both use the safe string (no separate `sanitizeEndReason` call in `onEnd`).

### What stays untouched (all correct, do not change)

- The 15s connect watchdog (`etWatchdog`), including its resolve-once `etResolved` guard
  and its own `.failed` timeout message.
- The `CFBridgingRetain` ctx lifecycle / `etSession?.close()` release-once semantics.
- `sanitizeEndReason`, `etFailureMessage`, `mapETState`.
- `onFirstFrame`'s `etResolved = true` + `state = .shell` (we only ADD the
  `etFirstFrameSeen = true` line beside it).

This slice changes *only* which state `onEnd` sets, driven by the new decider.

## Testing

### Kit (Linux, `swift test`), `ETExitDecisionTests`

Equivalence partitioning + boundary values + a wiring assertion:

| Case | `sawFirstFrame` | `reason` | Expected |
|---|---|---|---|
| Clean exit after session | `true` | `nil` | `.dismiss` |
| Clean exit, benign reason | `true` | `"session ended"` | `.dismiss` |
| Mid-session drop after session | `true` | `"connection lost"` | `.dismiss` |
| Adversarial reason, first-frame seen | `true` | `"\u{1B}[31mboom\u{1B}[0m"` | `.dismiss` (reason ignored on dismiss path) |
| Pre-connect failure, nil reason | `false` | `nil` | `.handshakeFailed("connection ended")` (sanitize default) |
| Pre-connect failure, plain reason | `false` | `"handshake rejected"` | `.handshakeFailed("handshake rejected")` |
| Pre-connect failure, ANSI/control reason | `false` | `"\u{1B}[1mfail\u{1B}[0m\r\n"` | `.handshakeFailed("fail ")` (exact sanitized value; trailing space is the collapsed CRLF) |

The ANSI/control case asserts the **exact** sanitized string to prove sanitization is
actually wired through the decider (anti-tautology: the test fails if the decider forgets
to call `sanitizeEndReason`). The dismiss-with-adversarial-reason case proves the reason
is not consulted on the graceful path.

### App (macOS CI)

The `onEnd` rewrite is App-tier (`ConnectionViewModel`), validated by the macOS CI
compile. Runtime behavior is confirmed on the device retest below.

## Device retest (after this slice builds to TestFlight)

Set a host Transport = Eternal Terminal, point it at the dev box (sshd :22 + etserver
v7.0.0 :2022 up), connect.

1. Verify it connects and typing works (unchanged from #120).
2. Type `exit`. **EXPECT:** the session ends gracefully and the app returns to the
   connection/host list. NO error banner, and the terminal no longer accepts input.
3. Point a host at a port with no etserver and connect. **EXPECT:** the pre-first-frame
   failure path still shows the `.failed` "Eternal Terminal could not connect…" banner
   (unchanged), and the 15s watchdog still yields the timeout `.failed` if the port
   blocks (unchanged).

## Out of scope

- The plain-SSH `exit` → `.failed("Session closed")` behavior (a separate latent
  annoyance; not part of this ET slice).
- A distinct mid-session-drop banner for ET (a first-frame-seen drop is dismissed
  gracefully like a clean exit; a dedicated "you were disconnected" banner is a possible
  future refinement, not needed now).
- The ET §4 dedicated Retry/Cancel error screen and the roaming banner (already queued
  follow-ups).
