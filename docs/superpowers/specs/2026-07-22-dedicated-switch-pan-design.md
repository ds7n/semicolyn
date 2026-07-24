<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Dedicated Switch Pan: own the horizontal swipe (design)

**Date:** 2026-07-22
**Status:** Approved (brainstorm complete); ready for implementation plan.
**Fixes:** plain-shell swipe-to-switch dead after a window switch (device 2026-07-22).

## Problem

At a plain shell (`.localScroll`), the window-switch swipe rides SwiftTerm's inherited
`UIScrollView.panGestureRecognizer` (we `addTarget` to it: `handleScrollViewPan`). On a
freshly-created pane after a switch, that native pan does NOT begin tracking (no `.began`,
so no `drag-begin`, so the swipe is dead), while keyboard input works fine. Confirmed by
device log: after a switch to a plain-shell window, zero `drag-begin`/`drag-axis-lock`/
`gr-observe` for ~5.7s of swipe attempts, but keystrokes reach the shell.

Root cause (traced in code): the native scroll pan's tracking depends on scroll-view state
we do not control, a fresh pane has `contentSize=(0,0)` and no bounce config, so the pan
does not engage a horizontal drag. Alt-screen panes are IMMUNE because they use our OWN
`altScreenPan` recognizer, not the native one. This is the ride-the-scroll-pan fragility
flagged earlier in the project: riding SwiftTerm's scroll pan for a horizontal gesture
couples the swipe to scroll-view internals.

NOTE: the `contentSize=(0,0)` mechanism is the best-supported hypothesis (inferred from
UIScrollView behavior), not proven byte-for-byte. The fix below does not depend on that
specific mechanism being exactly right: it stops depending on the native pan entirely, so
it is correct regardless of WHY the native pan fails to track.

## Fix: our own always-on horizontal switch pan

Add a dedicated `UIPanGestureRecognizer` we own (`switchPan`) for the horizontal
window-switch, so the swipe never depends on SwiftTerm's scroll-view state. This unifies the
model: alt-screen already uses an owned pan (`altScreenPan`); plain-shell now uses an owned
pan too. The native scroll pan keeps doing ONLY vertical scroll (its natural job, with free
momentum), and we stop `addTarget`-ing our switch logic onto it.

### Arbitration: simultaneous, axis-gated
- `switchPan` and SwiftTerm's scroll pan RECOGNIZE SIMULTANEOUSLY (add a `.switchPan`
  `GestureRole`; `gesturesMayRecognizeSimultaneously(.switchPan, .scrollPan) == true`).
- `switchPan`'s handler applies `DragAxisLock`: it acts ONLY on a horizontal-dominant drag
  (fires the switch on release via `SwitchCommitDecision` -> `onDragCommit`), and does
  NOTHING on a vertical/pending drag (lets the scroll pan scroll).
- The scroll pan handles vertical naturally (unchanged, native momentum kept).
- SwiftTerm's selection pan stays subordinated: `gesturesMayRecognizeSimultaneously(
  .selectionPan, .scrollPan) == false` (existing) AND add
  `gesturesMayRecognizeSimultaneously(.selectionPan, .switchPan) == false` so a drag can
  never become a text selection while switch-panning. The at-birth subordination
  (`subordinateSelectionPan`) already makes the selection pan require-to-fail vs the scroll
  pan; extend it to also require-to-fail vs `switchPan`.
- `switchPan` vs the taps/long-press/pinch: pinch coexists (2-finger); long-press must NOT
  co-recognize with `switchPan` for the held-then-drag hazard (mirror the existing
  `.altScreenPan`/`.longPress` exclusion: add `.switchPan`/`.longPress` -> false).

### Enablement
- `switchPan` is ALWAYS ON in `.localScroll` (unlike `altScreenPan`, which is only on in
  `.appOwnsInput`). In `.appOwnsInput` the switch is already handled by `altScreenPan`, so
  `switchPan` can be disabled there to keep exactly one switch-owner per mode (mirror the
  `setAltScreenPanEnabled` lockstep: `switchPan.isEnabled = (mode != .appOwnsInput)`).
  In `.mouseReporting`, SwiftTerm forwards the drag as mouse; `switchPan` still axis-gates,
  a horizontal-dominant drag switches (acceptable, matches current intent) unless device
  testing shows a conflict, in which case gate it like `.appOwnsInput`. Default: enabled in
  `.localScroll` and `.mouseReporting`, disabled in `.appOwnsInput`.

### Drag handling
`switchPan`'s handler is essentially the switch half of the current `handleScrollViewPan`:
- `.began` -> `beginDrag("switchPan", ...)` (snapshot mode, log `drag-begin`).
- `.changed` -> `driveLiveSwitch` (DragAxisLock; returns true if switch-locked). If it locks
  to switch, our pan owns the switch for this drag; if it locks to scroll/pending, our pan
  does nothing (the scroll pan is handling it).
- `.ended` -> `resolveLiveSwitch` (SwitchCommitDecision -> `onDragCommit(delta)` on commit;
  nothing on spring-back).

### Scroll residue
On a horizontal-dominant switch drag, the simultaneously-recognizing scroll pan may nudge
the buffer a few points vertically. Do NOT re-add offset-restore machinery initially (it was
deleted in the KISS pass): a horizontal drag moves little vertically, so the residue is
likely imperceptible. If device testing shows a visible vertical twitch on switch, add a
minimal `contentOffset` restore then (a small, testable Kit decision), not pre-emptively.

## Remove / simplify
- Stop `addTarget`-ing `handleScrollViewPan` onto `view.panGestureRecognizer` (line ~250):
  the native pan no longer carries our switch logic. `handleScrollViewPan` is either
  repurposed as `handleSwitchPan` (the new pan's selector) or deleted and replaced.
- The `observeStrayRecognizers` / `gr-observe` instrumentation (added this session) fires
  zero times because it only logs when a recognizer receives the touch; keep it (harmless,
  may help later) but note it did not catch this bug. A better hook (does the touch reach the
  view at all) is deferred: the owned-pan fix makes it moot for THIS bug (our pan will fire
  `drag-begin` regardless of scroll-view state).

## Testing
- Kit: the deciders (`DragAxisLock`, `SwitchCommitDecision`, `gesturesMayRecognizeSimultaneously`)
  already exist + are tested. ADD the new simultaneity pairings to
  `gesturesMayRecognizeSimultaneously` + `GestureRole.switchPan`, with tests:
  `(.switchPan,.scrollPan)==true`, `(.selectionPan,.switchPan)==false`,
  `(.switchPan,.longPress)==false`, `(.switchPan,.pinch)==true`.
- App tier: not Linux-buildable; macOS CI + device.
- Device matrix (THE fix):
  - Plain-shell swipe switches windows RELIABLY, INCLUDING immediately after a switch to a
    freshly-created plain-shell window (the exact repro).
  - Repeat several switches in a row: every one works (no dead pane).
  - Vertical scroll + momentum unaffected at a plain shell.
  - Alt-screen switch still works (altPan path unchanged).
  - Diagonal drag: scrolls (not a wrong switch); fast horizontal flick: switches.
  - Text selection (double/triple-tap) still works and is not hijacked by switchPan.
  - No visible vertical twitch at the start of a horizontal switch (else add residue restore).

## Decision log
- Root: plain-shell swipe rode SwiftTerm's native scroll pan, which does not track on a
  fresh pane (contentSize=0 / scroll-view state). Owned recognizer removes the dependency.
- Fix: dedicated always-on `switchPan` (in `.localScroll`/`.mouseReporting`), axis-gated,
  simultaneous with the scroll pan; selection + long-press subordinated to it.
- Reuse `DragAxisLock` + `SwitchCommitDecision` + `subordinateSelectionPan` (extend to switchPan).
- No offset-restore initially (deleted in KISS); add only if device shows residue.
- This resolves the ride-the-scroll-pan fragility for good: plain-shell and alt-screen both
  use owned pans now.
