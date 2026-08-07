<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# ET exit-fix + scroll diagnostic + menu cleanup (Batch 1), design

**Status:** approved (2026-08-06). Batch 1 of two. Batch 2 (wire ET -> tmux `-CC`
native panes, the roadmap headline) is a separate later slice. This batch fixes the
exit false-failure, adds a decisive scroll diagnostic (no scroll fix this batch), and
cleans up the transport/tmux menu. All lands on `fix/et-onend-clean-exit`; one CI/TF
build only after all three items are in.

Context: the ET device retest of the prior raw-terminal batch showed near-zero
user-visible progress. Device logs (all diagnostic categories on) gave precise root
causes, captured below. Rows-behind-keybar (Issue 2 of the prior batch) is NOT
re-addressed here (its fix shipped; its device result is folded into the scroll finding
because the two share the raw path).

## Item A: exit shows a false "could not connect: closed" + flash (FIX)

**Symptom (device):** after being connected and using ET, an intentional exit (typing
`exit` OR tapping the "x" disconnect button) sometimes shows the full
"Eternal Terminal could not connect: closed" screen with Close/Retry, and a transient
flash.

**Root cause (log-confirmed).** The device log shows both outcomes:
- `et: session ended (first-frame seen) -> dismiss to list` (x3, the graceful path works)
- `et: session ended pre-first-frame (closed)` (x1) -> routed to
  `.handshakeFailed("closed")` -> the "could not connect" screen, on a session that had
  been in use.

The mechanism: the "x" button calls `disconnect()` -> `teardown()`. `teardown()` runs
`etSession?.close()` (which triggers ET's asynchronous `onEnd`) AND synchronously sets
`etFirstFrameSeen = false`. ET's `onEnd` closure then fires on a later main-queue hop and
reads the now-`false` flag, so `etExitDecision(reason: "closed", sawFirstFrame: false)`
returns `.handshakeFailed` -> the failure screen. A user-initiated disconnect is being
misclassified as a pre-connect handshake failure.

The residual "flash" is the same class: the `.failed` screen (or the transient `.idle`
render) painting for a frame during teardown.

**Fix.** A user-initiated disconnect must never run the ET `onEnd` failure path.

1. Add `private var etUserDisconnecting = false` on `ConnectionViewModel`.
2. In `disconnect()`, set `etUserDisconnecting = true` BEFORE calling `teardown()`.
3. In ET's `onEnd` closure, FIRST check `if self.etUserDisconnecting { <silent cleanup>;
   return }` before `etExitDecision`, so a user teardown closes the session and returns
   without setting `.failed` or any banner. (State is already being driven to `.idle` by
   `disconnect()`.)
4. Reset `etUserDisconnecting = false` at the START of each connect attempt (in
   `connect(...)`, before `attachET`). It must NOT be reset in `teardown()`: `onEnd` is
   async and fires AFTER `teardown()` returns, so clearing it in `teardown()` would clear
   it before `onEnd` reads it, reintroducing the bug. Reset-at-connect-start means the
   flag is only ever `true` in the window between a user disconnect and the next connect,
   exactly when a stray `onEnd` must be swallowed, and the async `onEnd` still sees `true`.

This is subtle enough that the implementation must trace the exact async ordering:
`disconnect()` sets the flag -> `teardown()` calls `etSession.close()` -> `onEnd` fires
LATER and must still see `true`. So the flag lifecycle is: set in `disconnect()`, cleared
at the next connect-start. It is only ever `true` between a user disconnect and the next
connect, exactly the window where a stray `onEnd` must be swallowed.

**Also verify the clean `exit`-in-shell path is unaffected:** typing `exit` (not the x
button) fires `onEnd` with `etFirstFrameSeen` still `true` and `etUserDisconnecting`
`false` -> `.dismiss` -> graceful. The log already shows this working (3x dismiss). The
new guard only intercepts the user-disconnect path.

**Flash:** with the failure path suppressed on disconnect, the only remaining transition
is `disconnect()` -> `teardown()` -> `state = .idle` -> `.onChange` dismiss. The prior
batch's `.idle -> Color.clear` already blanks that transient. Confirm on device that no
`.failed` screen paints on the x-button path after this fix.

## Item B: scroll is dead in ET AND raw SSH (DIAGNOSTIC ONLY this batch)

**Symptom (device, user-confirmed):** swipe to scroll on the ET or raw-SSH shell ->
"nothing at all moves." Now reproduces on raw SSH too, not only ET.

**Evidence (device `touch:begin` roster, new build).** At touch-down on a swipe:
`scrollEnabled=true delaysContent=false fr=true panEnabled=true contentSize=605
frameH=499` (real scroll range: content 605 > frame 499), mode `localScroll`, and the
recognizer roster shows the native scroll pan enabled with NO competing enabled pan that
should win. Yet across every swipe there are ZERO `gr-observe` and ZERO `drag-begin`
events, and nothing scrolls. So the touch lands but NO pan recognizer ever begins: the
finger drag is not being interpreted as a pan by the native scroll pan or by ours.

**Why no fix this batch.** Static analysis cannot yet name what prevents the native pan
from starting (the `touch:begin` log only captures touch-DOWN, not the pan's state
transitions DURING the drag). The roster shows UIKit text-interaction recognizers
(`_UIRelationshipGestureRecognizer`) present, a candidate, but attributing without the
pan-state trace would be guessing. Per the debugging discipline (and the user's choice:
"diagnostic only this batch"), ship the precise diagnostic; fix next build from the trace.

**Diagnostic to add.** Log the native scroll pan's state transitions across the whole
drag (not just began/changed):

1. In `TerminalGestureController` (or `PaneTerminalView`), attach a target to
   `view.panGestureRecognizer` that logs EVERY state on EVERY callback, including
   `.possible`(0)/`.began`(1)/`.changed`(2)/`.ended`(3)/`.cancelled`(4)/`.failed`(5), with
   the current `mode`, `translation`, and `numberOfTouches`. The existing
   `observeRecognizerState` gates on `.began || .changed`; add a variant (or widen it)
   that logs ALL states for the native pan specifically, so a pan that reaches `.failed`
   or `.cancelled` (never `.began`) is visible.
2. Also log, once per drag attempt, whether ANY of the view's pans changed state at all
   (to distinguish "native pan failed to begin" from "no pan saw the touch").

Output token: `scroll-trace pan=<kind> state=<n> mode=<m> touches=<n> tx=<x> ty=<y>`.
The next device swipe then shows definitively: does the native pan reach `.began`? Does
it reach `.failed` (and if so, what required it to fail)? Or does it stay `.possible`
(touch never delivered as a pan)?

This is diagnostic-only: it attaches a logging target and adds no behavior. It must NOT
disable, enable, reorder, or require-to-fail any recognizer.

## Item C: transport / tmux menu cleanup (DESIGN FIX)

**Problems (confirmed in code):**
1. Redundant selectors: a `Transport` picker (Default/SSH/Mosh/ET) AND a separate
   "Enable Mosh" toggle (`HostEditorSections.moshSection`, `vm.host.mosh.value?.enabled`).
   `resolveTransport` reconciles them via legacy migration.
2. "Attempt tmux control mode" (`DefaultsEditorView` ~633, and the host equivalent) is
   consumed ONLY in `attachSSHShell` (`tmuxLaunchDecision`); it does nothing for Mosh or
   ET, but is presented as a general option.

**Design decisions (locked):**
- **Transport dropdown is the sole transport selector.** Remove the "Enable Mosh" toggle
  from the host editor's Mosh section. The Mosh *config* (server path, UDP port range,
  prediction mode) stays in the model and in a Mosh settings section that is shown ONLY
  when the resolved/selected transport is Mosh. Back-compat is preserved automatically:
  `resolveTransport` already migrates a legacy `mosh.enabled=true` host (no transport
  field) to `.mosh` (Resolution.swift:199), so existing Mosh hosts keep working with the
  toggle gone. Removing the toggle removes only the redundant WRITE path; the read path
  (legacy migration) stays.
- **"Attempt tmux control mode" is transport-agnostic in principle** (tmux `-CC` runs over
  any PTY stream; only Mosh structurally cannot do `-CC`, per the roadmap:
  `mosh-tmux-et-modes-roadmap`). So show the toggle for **SSH and ET**, HIDE it only when
  the selected transport is **Mosh**. Relabel/subtitle it to name what it does ("Run tmux
  in control mode for native panes") and note ET support is pending wiring (Batch 2).
  IMPORTANT HONESTY CONSTRAINT: today the toggle does nothing for ET (ET does not run tmux
  `-CC` yet). So its ET subtitle must say the wiring is upcoming, NOT imply it works now.
  Wiring ET -> tmux `-CC` is Batch 2.
- Apply the same show/hide + relabel in BOTH the host editor and the Defaults editor
  (they mirror each other).

**Non-goals for Item C:** no change to `resolveTransport`, `tmuxLaunchDecision`, or the
Mosh config model. This is a UI-layer cleanup (which controls are shown, and their
labels), plus removing one redundant toggle. The four-state `Inherited<Transport>` picker
stays as-is.

## Testing

- **Kit (Linux):** `resolveTransport` and the mosh legacy-migration are already tested; if
  Item C introduces any new pure "should this control show" predicate, extract it to
  `Sources/SemicolynKit/` with EP tests (e.g. `showsTmuxControlToggle(transport:) -> Bool`
  = true for .ssh/.et, false for .mosh). Prefer a tiny pure helper over an inline `if` so
  it is Linux-tested.
- **App (macOS CI):** the exit-guard wiring (`ConnectionViewModel`), the scroll diagnostic
  (`TerminalGestureController`/`PaneTerminalView`), and the editor UI changes are App-tier,
  macOS-CI-compiled only.
- **Device retest (all categories ON), after the single Batch-1 build:**
  1. Item A: connect ET, use it, then (a) type `exit` and (b) tap the "x" button. BOTH must
     return to the connection list with NO "could not connect" screen and NO flash. Verify
     the log shows the disconnect path is silent (no `pre-first-frame` -> `.failed` on a
     used session).
  2. Item B: swipe on ET and on raw SSH; capture the `scroll-trace pan=... state=...`
     lines. Record whether the native pan reaches `.began`, `.failed`, or stays
     `.possible`. This names the scroll fix for the next build.
  3. Item C: host/defaults editors show Transport as the only transport selector (no
     "Enable Mosh" toggle); the tmux-control toggle is shown for SSH and ET, hidden for
     Mosh, and its ET subtitle says wiring is pending. Existing Mosh hosts still connect
     via Mosh (legacy migration intact).

## Out of scope (explicit)

- **ET -> tmux `-CC` wiring (Batch 2).** The headline feature; its own spec/plan/build. ET
  is an `ETSession` (own C stream), not a russh `Connection`, so tmux `-CC` must run inside
  the ET PTY and route ET output through `TmuxRuntime` into `TmuxPaneContainer`. Large;
  done separately.
- The scroll FIX (this batch is diagnostic-only for scroll, by decision).
- Rows-behind-keybar (shipped in the prior batch; not re-touched here).
- Any change to the four-state Transport picker semantics or `resolveTransport`.
