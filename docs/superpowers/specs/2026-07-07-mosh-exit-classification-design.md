# Mosh Exit Classification + First-Frame Watchdog — Design Spec

**Date:** 2026-07-07
**Status:** Locked direction, ready for implementation plan
**Scope:** Fix first-connect-over-Mosh landing on a blank terminal + crash banner instead of falling back to SSH. Amends the first-frame dividing line in `2026-07-03-mosh-m3-m4-bridge-wiring-design.md`.

---

## The bug (device trace, build 22)

```
1.23  mosh: sess.start() — UDP session launching, state=.shell
1.32  mosh: onFirstFrame — UDP handshake up, frames flowing
1.32  mosh: onEnd firstFrameSeen=true reason=Mosh connection failed — using SSH
1.32  mosh: post-first-frame exit → crash banner
```

Mosh bootstraps fine (port + key), `sess.start()` renders a blank `.shell`, `onFirstFrame`
fires, then **~90 ms later** `mosh_main` returns nonzero (`MoshSession.mm:256`, reason
*"Mosh connection failed — using SSH"*). Because `moshFirstFrameSeen == true`, `onEnd` takes
the **post-first-frame** branch → **crash banner**, not the pre-first-frame **SSH fallback**.
Result: blank terminal + a useless crash banner, no working shell. Reattach "works" only
because the user then picks SSH.

### Root cause

The `firstFrameSeen` boolean is the wrong discriminator. The M3/M4 spec (lines 207–218)
assumed a handshake failure yields `onEnd` **before** any frame. Real mosh emits an
**init/clear framebuffer diff before the UDP handshake is confirmed**, so `onFirstFrame`
fires for a connection that then fails. "Saw a frame" ≠ "session is healthy."

---

## Fix — two pieces

### 1. Exit classification by reason + elapsed time (fixes the trace)

Replace the `firstFrameSeen` branch in `attachMoshIfPossible`'s `onEnd` with a pure,
Kit-tested decision on **why** and **how soon** the loop exited. `firstFrameSeen` is dropped
from the decision entirely — the device proves it unreliable.

New Kit seam (`Sources/SemicolynKit/Mosh/MoshExitDecision.swift`):

```swift
public enum MoshExitDecision: Equatable, Sendable {
    case fallbackSSH   // handshake never really came up → SSH on the retained connection + banner
    case crashBanner   // a live session died → reuse the mid-session crash banner
    case ended         // clean exit (rc == 0) → session ended normally
}

/// Classify a Mosh loop exit.
/// - reason:  the `onEnd` reason string; `nil` ⟺ a clean (rc == 0) exit.
/// - elapsed: seconds from `sess.start()` to `onEnd`.
/// - graceWindow: the handshake grace window (default 3.0s).
public func moshExitDecision(reason: String?, elapsed: TimeInterval,
                             graceWindow: TimeInterval = 3.0) -> MoshExitDecision {
    guard reason != nil else { return .ended }        // clean exit
    return elapsed < graceWindow ? .fallbackSSH : .crashBanner
}
```

**Why time works despite slow links:** the timer measures start→*loop exit*, not
time-to-frame. Mosh does not exit while a handshake is merely slow — its SSP loop
retransmits and waits, so a slow-but-reachable link never fires `onEnd` inside the window;
it eventually renders. `onEnd` inside 3 s therefore only happens on an actual fast failure
(crypto mismatch / UDP blocked / refused) — exactly the SSH-fallback case. A nonzero exit
after 3 s means the session lived first, then died → crash banner. The only reclassified
case (a real session that dies in <3 s) lands on the harmless side: SSH-fallback on the live
connection is a reasonable first-connect recovery.

### 2. First-frame watchdog (covers the silent hang)

The timer in (1) only fires when mosh *exits*. A hung UDP path where `mosh_main` neither
renders a real frame **nor** returns leaves a permanent blank screen with no recovery. Add a
watchdog armed at `sess.start()`:

- If **no real frame** has rendered and **no `onEnd`** has fired within **`watchdogWindow`
  (default 10 s)**, treat it as a stalled handshake → tear down Mosh and SSH-fall-back on the
  retained connection (same path as `.fallbackSSH`), banner *"Mosh didn't connect — using SSH"*.
- The watchdog is cancelled by either `onEnd` (piece 1 handles it) or the first **real**
  frame. "Real frame" here is pragmatic: the watchdog only needs *some* evidence mosh is
  alive. Since the init-diff `onFirstFrame` is unreliable as a health signal but does prove
  the loop is running, the watchdog cancels on `onFirstFrame` OR `onEnd` — its sole job is the
  **no-callback-at-all** hang. (A session that got an init frame but then fails fast is still
  caught by piece 1's <3 s classification.)

Watchdog timing lives in the App tier (it needs a real clock/Task), but the **window
constants and the arm/cancel/fire predicate** are a pure Kit seam so the logic is tested:

```swift
// Sources/SemicolynKit/Mosh/MoshExitDecision.swift (same file)
public enum MoshWatchdogAction: Equatable, Sendable { case fallbackSSH, noop }

/// Given whether the loop has signalled life (onFirstFrame or onEnd) by the deadline,
/// decide the watchdog action.
public func moshWatchdogAction(sawAnyCallback: Bool) -> MoshWatchdogAction {
    sawAnyCallback ? .noop : .fallbackSSH
}
```

---

## Wiring (App tier — `attachMoshIfPossible`, macOS-CI-verified)

- Record `let startedAt = <monotonic clock>` immediately before `sess.start()`.
- `onEnd`: compute `elapsed = now - startedAt`; switch on `moshExitDecision(reason:elapsed:)`:
  - `.fallbackSSH` → existing pre-first-frame path (stop session, `moshFallback` banner,
    `attachSSHShell` on the retained `conn`).
  - `.crashBanner` → existing post-first-frame path (stop session, `crashBanner = .tmuxEnded`).
  - `.ended` → clean session end. **New:** a clean Mosh exit on first-connect currently has no
    explicit handling; treat it like `.crashBanner`'s teardown but with the session-ended
    state (no alarming "crashed" copy). For v1, reuse `.tmuxEnded` (acceptable — matches how a
    clean tmux exit is surfaced); refine copy later if needed.
- Arm a watchdog `Task` after `sess.start()` that sleeps `watchdogWindow`, then if neither
  `onFirstFrame` nor `onEnd` has fired, runs `moshWatchdogAction(sawAnyCallback:)` →
  `.fallbackSSH` path. Cancel/guard the task from `onFirstFrame` and `onEnd`.
- Keep all the existing gated `DebugLog` milestones; add `mosh: exitDecision=<...> elapsed=<>s`
  and `mosh: watchdog fired → SSH fallback` / `mosh: watchdog cancelled`.

---

## Testing

| Unit | Where | Cases | Tier |
|---|---|---|---|
| `moshExitDecision` | Linux XCTest | **EP/BVA:** clean (`reason=nil`, any elapsed) → `.ended`; nonzero @ elapsed `0`, `2.9`, `2.999` → `.fallbackSSH`; nonzero @ `3.0` (boundary), `3.001`, `30` → `.crashBanner`; the exact device reason string `"Mosh connection failed — using SSH"` @ `0.09s` → `.fallbackSSH` (regression pin) | Core |
| `moshWatchdogAction` | Linux XCTest | `sawAnyCallback=false` → `.fallbackSSH`; `true` → `.noop` | Core |
| `attachMoshIfPossible` wiring | macOS CI (manual/device) | onEnd routes to each branch; watchdog fires on a stubbed no-callback session; watchdog cancelled by onFirstFrame | Core |

Boundary note: the window is a **half-open** interval — `elapsed < 3.0` is fallback, `elapsed == 3.0` is crashBanner. Tests must pin `2.999`→fallback and `3.0`→crashBanner.

---

## Spec amendment

This supersedes the dividing line in `2026-07-03-mosh-m3-m4-bridge-wiring-design.md`
(lines 207–209, 217–220): "first frame seen ⇒ healthy" is replaced by "**exit reason +
elapsed time** classify the exit; `firstFrameSeen` is not a health signal." The M3/M4 rows
for *crypto/key mismatch* and *UDP blocked* still resolve to SSH fallback — now correctly even
when an init frame preceded the failure.

---

## Non-goals

- Distinguishing an init framebuffer diff from a real post-handshake frame inside
  `libmoshios` (the faithful-but-fragile path). Not needed: time + reason already classify
  correctly, and the watchdog covers the no-callback hang.
- Tuning `graceWindow`/`watchdogWindow` per-host or via settings. Fixed defaults (3 s / 10 s);
  revisit only if device testing shows a real link that violates them.
- Changing `MoshSession.mm` exit reasons. The three `fireEnd` sites and their `rc`-derived
  reason strings are correct; only the Swift-side interpretation changes.
