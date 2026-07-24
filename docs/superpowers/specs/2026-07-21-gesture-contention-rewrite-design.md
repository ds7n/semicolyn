<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Gesture Contention Rewrite: Reliable Window-Switch Swipe (design)

**Date:** 2026-07-21
**Status:** Approved (brainstorm complete); ready for implementation plan.
**Scope:** The gesture-arbitration layer only. Makes the horizontal tmux-window-switch
swipe RELIABLE at a plain shell. Does NOT touch the switch handoff/render machinery
(the flicker/first-frame fix is a separate sequenced spec: capture-pane-on-switch).

## Problem

The window-switch swipe is unreliable at a plain shell (`.localScroll`) but works in
alt-screen apps (`.appOwnsInput`). Root cause (confirmed by code + device trace
2026-07-13, and re-verified by fresh SwiftTerm-source research 2026-07-21):

- In `.localScroll` the switch swipe FREE-RIDES SwiftTerm's inherited
  `UIScrollView.panGestureRecognizer` as an extra target (not a real competing
  recognizer), so it cannot participate in gesture arbitration.
- SwiftTerm creates its text-selection pan LAZILY (first selection). That recognizer can
  WIN the drag race before our per-`.began` cleanup runs, silently swallowing the drag as
  a text selection (the zero-log failure signature).
- In `.appOwnsInput` the swipe has its OWN dedicated `altScreenPan` and the native scroll
  pan is parked (`isScrollEnabled = false`), so there is no contention and it works.

## Constraints (facts established by research, not choices)

1. We KEEP SwiftTerm's `TerminalView` (a `UIScrollView`). The `SwiftTerm.Terminal` engine
   is the right emulator (used by Secure Shellfish, La Terminal, CodeEdit); replacing the
   VIEW was priced at 6-10 weeks with risk concentrated in rendering + IME, disproportionate
   to a gesture problem. The whole iOS-terminal ecosystem avoids rebuilding the terminal
   view (Blink uses hterm-in-WebView for years rather than go native). We stay on the
   shared maintained foundation and own only the thin gesture layer we already own today.
2. The native `UIScrollView` scroll pan COMMITS ON FIRST MOVEMENT with no dead-zone, and
   its behavior is NOT suppressible from outside. It cannot be held in a deferred/`.possible`
   state. True deferred-collapse ("keep the gesture unknown until a dead-zone resolves") is
   therefore impossible while we keep SwiftTerm's view. (Verified against SwiftTerm source,
   pinned commit 58915b1.)
3. SwiftTerm's selection pan CAN be subordinated by us: it is created without a delegate, so
   we may set its `.delegate` and/or call `require(toFail:)` from outside. Our existing
   `shouldRequireFailureOf` rule (selectionPan vs scrollPan) is correct but DEAD CODE today
   because the delegate is never set.

## The contention model: one authoritative drag owner

Because the scroll pan cannot defer, we make it the SINGLE authoritative owner of every
drag touch and interpret its `.changed` stream to decide what the drag MEANS. Nothing races
it; every other drag-like recognizer is subordinated. This is the maximal removal of
contention achievable within constraint 2: with exactly one drag recognizer, there are zero
drag-vs-drag races by construction.

```
Touch down
  scroll pan owns the drag (always; it commits first, we embrace that)
    .changed -> DragAxisLock.resolve(dx, dy)   [pure, Linux-tested, UNCHANGED]
      .pending (inside 12pt dead-zone) -> do nothing yet
      .scroll                          -> native scroll runs free (+ momentum, rubber-band)
      .switchWindow                    -> restore snapshotted offset, drive page-turn

Subordinated (REQUIRED TO FAIL vs scroll pan):
  - SwiftTerm selection pan (caught at BIRTH: delegate wired once + require(toFail:))
  - long-press

Non-contending (orthogonal by nature, UNCHANGED):
  - single / double / triple tap  (tap vs drag)
  - two-finger tap, pinch         (touch count)
```

The plain-shell and alt-screen paths share ONE mental model. Alt-screen keeps its dedicated
`altScreenPan` (there the scroll pan is parked), but the DECISION logic (`DragAxisLock` ->
switch) is identical.

## Components

### Reused unchanged (pure Kit deciders, Linux-tested)
- `DragAxisLock` (12pt dead-zone, 1.7:1 dominance ratio).
- `WindowDragModel` (offset + rubber-band + exposed-neighbor).
- `SwitchCommitDecision` (40% distance / 500 pt/sec flick, sign-checked).
- `GestureSimultaneity` (`gesturesMayRecognizeSimultaneously` + `GestureRole`). We finally
  ACTIVATE its selection rule; the policy itself is unchanged.

### Modified (all in `App/TerminalGestureController.swift`, the thin layer we own)

| ID | Change | Why |
|----|--------|-----|
| A | Offset snapshot/restore: capture `contentOffset` at drag `.began`; restore it the instant `DragAxisLock` resolves `.switchWindow`. | Erase the 0-3pt vertical residue the scroll pan nudged before switch locked. |
| B | Selection-pan-at-birth: detect SwiftTerm's lazy selection pan the moment it appears (re-scan on selection-relevant events / KVO on `gestureRecognizers`); set `.delegate = self` ONCE + `require(toFail: scrollPan)`. | Root-cause fix for the intermittent race: subordinate at birth, not per-drag. |
| C | Retain the per-`.began` `disableStraySwiftTermPans` scan as belt-and-suspenders insurance (retire only after device testing confirms B is durable). | Two-layer guarantee; a missed detection degrades to today's behavior, not worse. |
| D | Wire the dead code: setting the selection pan's delegate (B) makes the existing `shouldRequireFailureOf` (selectionPan vs scrollPan) fire. | Activate existing correct logic. |

### Explicitly NOT touched (kept working)
- The `commitSwitchDrag` transform-slide / both-ready gate / hidden-pane settle / resize-settle
  machinery. That is the HANDOFF layer, owned by the capture-pane follow-up spec. This spec
  only guarantees the swipe reliably REACHES it.
- Rendering, IME, scroll momentum, selection UI (loupe/handles), accessibility, keybar. SwiftTerm
  keeps doing the heavy lifting.

## Data flow: horizontal switch drag at a plain shell (the fixed case)

```
1. Finger down
   scroll pan .began -> beginDrag(): snapshot dragMode, appCursor, altScrollDecision
                     -> NEW: savedOffset = terminalView.contentOffset
                     -> dragAxis = .pending

2. Finger moves (inside 12pt dead-zone)
   scroll pan .changed -> DragAxisLock.resolve() = .pending -> no action
   (native scroll may nudge 0-3pt, tolerated, about to be undone)
   selection pan CANNOT start (required to fail vs scroll pan, fix B/D)

3. Finger crosses dead-zone, horizontal-dominant
   DragAxisLock.resolve() = .switchWindow(delta)
   NEW: terminalView.contentOffset = savedOffset   (instant undo of residue)
   onDragBeginSwitch() -> beginSwitchReveal()  [existing]

4. Finger continues horizontally
   each .changed -> WindowDragModel.offset() -> onDragUpdate(offset, exposed)
                 -> paneContentView.transform slides + card-dim ramps  [existing]
   native vertical scroll inert (axis locked to switch for this drag)

5. Finger releases
   scroll pan .ended -> SwitchCommitDecision.resolve(dx, width, velocity)
       .commit(delta) -> onDragCommit -> commitSwitchDrag  [existing handoff machinery]
       .springBack    -> onDragCancel -> spring back        [existing]
```

The change vs today: at step 2 selection can no longer silently win and swallow the drag
(B/D); at step 3 the accidental scroll is erased (A). Step 4 onward is the EXISTING working
path; we only guarantee the drag reliably gets there.

- Vertical scroll drag: steps 1-2 identical; step 3 resolves `.scroll` -> we do nothing ->
  native scroll + momentum run free. No offset restore (restore fires only on switch-lock).
- Alt-screen drag: `altScreenPan` owns it (scroll pan parked), same `DragAxisLock` decision,
  same switch path.

## Edge cases (deterministic in ALL rows)

| Scenario | Behavior | Why safe |
|----------|----------|----------|
| Pure vertical | `.scroll` -> native scroll + momentum; no restore | dead-zone resolves vertical; we do nothing |
| Pure horizontal | `.switchWindow` -> restore offset -> page-turn | the fixed case; selection cannot intercept (B/D) |
| Diagonal | 1.7:1 dominance decides; ties -> `.scroll` (biased safe) | `DragAxisLock` handles it, unchanged |
| Hold-then-drag (meant as select) | held finger may fire long-press (zoom); a subsequent drag force-cancels long-press (existing) and the scroll pan owns it. Selection is TAP-initiated (double/triple-tap), never drag-initiated. | Consistent model: a drag never means "select" |
| Fast flick | `SwitchCommitDecision` flick threshold (500 pt/sec, sign-checked) commits | unchanged decider; sign-agreement guard prevents bounce-back false commits |
| Selection pan never yet created | no-op until it appears; caught at birth (B) | lazy creation handled |
| Selection pan appears mid-session | re-scan/KVO -> delegate wired + `require(toFail:)` -> subordinate for all future drags | root-cause fix |
| Restore-but-no-commit (spring-back) | offset already restored at lock; spring-back returns transform to identity; scroll offset stays at the restored top | no scroll corruption |
| Rapid re-drag during commit | existing `discardCommittedSnapshot` / `switchGeneration` guards | untouched machinery |

**Residual risk (flagged honestly):** fix B depends on reliably detecting the selection
pan's birth. If detection misses, the retained per-`.began` `require(toFail:)` insurance
(C) applies at the next drag. Two-layer guarantee: durable-at-birth (primary) + per-drag
insurance (fallback). A missed detection degrades to today's behavior, never worse.

## Testing

### Kit tier (Linux XCTest)
- Existing decider tests (`DragAxisLock`, `WindowDragModel`, `SwitchCommitDecision`,
  `gesturesMayRecognizeSimultaneously`) are UNCHANGED and must stay green (regression guard).
- NEW pure seam: extract the offset-restore decision as a tiny pure helper
  (input: saved offset + resolved `DragAxis` -> output: restore-or-not, and to what), then
  test it with equivalence partitions: `.switchWindow` -> restore to saved; `.scroll` -> no
  restore; `.pending` -> no restore. Assert the exact returned offset (no tautologies). This
  keeps the App-layer change to a one-line call of a TESTED decider (the `tmuxLaunchDecision`
  pure pattern).

### App tier (macOS-CI compile + device-verify, no local test)
- Compiles on macOS CI. The `@MainActor` delegate-callback trap checklist applies (the
  selection-pan delegate is set from a gesture-callback / nonisolated context).
- DEVICE VERIFICATION is the acceptance gate (standing rule for App-tier gesture changes).
  Device matrix = the edge-case table: plain-shell horizontal switch (the fix), vertical
  scroll unaffected, diagonal, fast flick, hold-then-drag, alt-screen switch still works,
  and selection-then-switch (the intermittent case) reliable across repeated attempts.

## Out of scope (sequenced follow-ups)

1. **capture-pane-on-switch (NEXT spec):** `-CC` does not replay a window's screen on
   select-window, so the new window is blank until output arrives; the current 80ms
   `switchSettleDelay` timer papers over it and causes the flicker. The fix (what iTerm2 /
   WezTerm do) is `capture-pane -p -e -J` on switch, feed through the emulator, reveal on the
   capture command's `%end` (an event-driven "ready" signal replacing the timer). This lands
   on the known-good gesture base this spec produces.
2. **ET transport:** orthogonal (a transport feeding the same gesture/render code). Unchanged
   by this work.

## Decision log (this brainstorm)

- Foundation: tmux `-CC` is the right multiplexer; no better tool exists (screen has no
  structured protocol; Zellij has no `-CC` equivalent and is not preinstalled; ET/mosh are
  transports, not multiplexers). The `-CC` async-delivery pain is inherent to the job.
- Terminal library: keep SwiftTerm (engine is right; view rebuild priced too high; ecosystem
  avoids rebuilding the view).
- Switch UX (locked): content-follows-finger page-turn; dim/placeholder peek (no live/snapshot
  neighbor, Option C); first visible frame of the new window MUST be its real final frame
  (handoff HELD until ready) -> that requirement is the capture-pane follow-up's job.
- Gesture model: one authoritative drag owner (scroll pan), interpret its stream; NOT pure
  deferred-collapse (impossible with SwiftTerm's view); selection subordinated at birth;
  offset snapshot/restore for residue.
