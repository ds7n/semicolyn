<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# KISS Window Switch: swipe -> select-window -> redraw (design)

**Date:** 2026-07-22
**Status:** Approved (brainstorm complete); ready for implementation plan.
**Supersedes:** the finger-drag transition + capture-pane approach. The animated
switch machinery is DELETED, not fixed.

## Principle

A tmux window switch is one action: **detect a horizontal swipe, send tmux
`select-window`, let the terminal redraw.** Same mechanism as sending any other
command. No animation, no window prediction, no graying out, no snapshot, no
reveal gate. The screen changes when tmux's bytes arrive, exactly like typing
`tmux next-window`.

The gesture detection was never the problem and stays. The problem was the
cinematic slide bolted on top of it: a finger-follows-content animation plus the
async-handoff machinery (both-ready gate, hidden-pane settle, timeout backstop,
generation guards) that existed ONLY to make that slide look smooth across tmux's
delivery delay. That machinery generated every recent switch bug. It is not
required to switch windows. Delete it.

## What the switch becomes

```
horizontal swipe passes the commit threshold (on release)
  -> onSwitchWindow(delta)  -> tmux select-window
  -> tmux delivers the new window's state
  -> apply(state:) builds/updates panes; they render as %output arrives
  -> done. A blank beat while tmux repaints is acceptable (it is a terminal).
```

- Trigger: **on release**, if the drag passed the existing distance/flick threshold
  (`SwitchCommitDecision`). During the drag, NOTHING visible happens.
- No live finger-tracking, no peek, no dim, no slide.

## KEEP (unchanged)

- **Gesture detection deciders (pure, Kit, Linux-tested):** `DragAxisLock`
  (horizontal vs vertical vs pending) and `SwitchCommitDecision` (distance/flick).
  These ARE the switch-case. Their tests stay green.
- **The action wiring:** `handleScrollViewPan` / `handleAltScreenPan` detect the
  horizontal drag and, on release past threshold, call `onSwitchWindow(delta)` ->
  the existing tmux `select-window` path.
- Everything unrelated: native vertical scroll (+ momentum), long-press pane-zoom,
  taps (cursor/word/line select), pinch font-zoom, alt-screen arrow-scroll pan,
  the selection-pan subordination (helps scroll-vs-selection reliability, not
  swipe-specific), the `WindowTabStrip` tap fallback.
- Normal pane rendering: `apply(state:)` builds the new window's panes and tmux
  repaints them. With NO hiding, NO gate, NO animation.

## DELETE (the ceremony) — all in App/TmuxPaneContainer.swift + App/TerminalGestureController.swift

Coordinator (switch animation + async-handoff machinery):
- `beginSwitchReveal`, `updateSwitchDrag`, `updateCardDim`, `clearCardDim`,
  `commitSwitchDrag`, `cancelSwitchDrag`, `clearPendingSwitch`,
  `discardCommittedSnapshot`, `failPendingSwitch`, `finishSwitchHandoffIfReady`,
  `completePendingSwitchIfNeeded`.
- State: `pendingSwitchTimeout`, `pendingSwitchWindow`, `switchAnimDone`,
  `switchDelivered`, `switchGeneration`, `hasPendingSwitch`, `lastLoggedDragOffset`,
  `switchSettleDelay`.
- The live-drag switch callbacks in the gesture controller: `onDragBeginSwitch`,
  `onDragUpdate`, `onDragCommit`, `onDragCancel` (in `Callbacks`), and their
  drivers `driveLiveSwitch` live-render path / `resolveLiveSwitch` -> collapse to a
  single "on release, if switch-locked past threshold, call `onSwitchWindow(delta)`".
- Offset snapshot/restore (`savedContentOffset`, `ScrollResidueDecision` call): it
  only masked the slide's dead-zone residue. With no slide, no residue to hide.
- `WindowDragModel` usage (offset/rubber-band/exposed-neighbor: animation-only).
- ContainerView: `cardDimView` / `cardDimOverlay` / `ensureCardDimInstalled`,
  `revealSwitchedPanes`, panes-created-`isHidden` logic.

### paneContentView: KEEP or inline?
`paneContentView` currently exists to be the single view the slide transform was
applied to. With no slide, it is just a passthrough wrapper. KEEP it as-is for this
change (panes are parented into it and `layoutSubviews` pins it to bounds); removing
the wrapper is a larger refactor and out of scope. We simply stop ever setting its
`.transform`. (A later cleanup may inline it.)

### armResizeSettle / resize-settle window
`armResizeSettle` + the `switchResizeQuiet` debounce coalesced a resize burst caused
by the switch animation's keyboard/keybar grow. With no animation, re-evaluate: the
resize burst on switch may still occur from the keybar, so KEEP `armResizeSettle`
(it is triggered from the universal active-window-change point in `apply`, not the
deleted animation) unless the plan finds it is animation-coupled. Decision deferred
to the plan's investigation step; default KEEP (it is a resize-debounce concern,
orthogonal to the switch animation).

## Data flow (after)

```
1. Finger horizontal drag -> DragAxisLock resolves .switchWindow(delta)  [KEEP]
   (nothing visible happens; no reveal, no transform)
2. Finger releases -> SwitchCommitDecision.resolve()  [KEEP]
     .commit(delta) -> onSwitchWindow(delta)  -> tmux select-window
     .springBack    -> nothing
3. tmux delivers new window -> apply(state:) rebuilds panes (no hide/gate/anim)
4. panes render as %output arrives. Done.
```

## Testing

- Kit tier: `DragAxisLock` + `SwitchCommitDecision` tests stay green (the
  detection logic is unchanged). No new Kit logic (this is a deletion). Any Kit
  test that referenced deleted animation helpers (`WindowDragModel`,
  `GapDim`, `ScrollResidueDecision`) is removed WITH its now-dead production code;
  note removed tests explicitly in the plan.
- App tier: not locally buildable; macOS CI compile + device-verify are the gates.
  Device matrix: horizontal swipe switches windows (on release, past threshold);
  short drag does nothing; vertical scroll unaffected; long-press zoom works; tab
  strip still switches; NO animation/dim/blank-hold artifacts; the switch just
  redraws. Rapid double-swipe does not corrupt (no generation machinery needed
  because there is no animation to supersede: the last select-window wins, tmux is
  authoritative).

## Out of scope (separate, still-valid follow-ups)
- **Selection-when-scrolled fix** (independent bug, fully root-caused: `cell(at:)`
  omits the `yDisp` term, correct mapping is `bufferRow = yDisp + screenRow`). Its
  own small spec/plan.
- **capture-pane on switch:** NO LONGER NEEDED for this design (there is no reveal
  to feed; the blank beat is acceptable). Shelved. If a blank-on-switch ever becomes
  a felt problem later, capture-pane is the known fix, but KISS ships without it.

## Decision log
- The gesture was never the problem; the animation + async-handoff machinery was.
- KISS: swipe -> select-window -> redraw. Delete the slide/gate/snapshot/dim/hidden-pane
  machinery. Keep DragAxisLock + SwitchCommitDecision (the switch-case) and the
  select-window action.
- Fire on release past threshold; no live finger-tracking.
- Keep the swipe (it works with content); do NOT fall back to tab-strip-only.
  capture-pane shelved (not needed without a reveal to feed).
