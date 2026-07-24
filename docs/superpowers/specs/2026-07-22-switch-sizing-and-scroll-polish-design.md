<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Switch-Sizing + Scroll Polish (design)

**Date:** 2026-07-22
**Status:** Approved (brainstorm complete); ready for implementation plan.
**Context:** Device testing the KISS window-switch build surfaced three issues. Grounded in
the 2026-07-22 device log.

## Issue B/C: sizing thrash on switch-back (the real regression)

### Symptom
Returning to a window, the redraw is "off" / cursor top-left / "feels like the sizing
issue." Device log: on every switch in the later session, `sizing:tmux` reports ~25 DIFFERENT
transient grids per switch (`80x37 -> 38 -> ... -> 70`) while `kbH` is stuck at `40.0`, then
`kbH` snaps to `74.0` and the grid locks to the correct `80x33`. The history seed
(`PaneHistorySeeder`) paints mid-storm: `seed applyHistory pre: rows=33` while `sizing:tmux`
one line earlier said `grid=80x37`. Content DOES paint (not the -CC no-replay blank: the
seeder is active), but at a size that briefly disagrees with itself, so the cursor/viewport
lands wrong until the grid settles.

### Root cause (verified in code)
`ContainerView.firstResponderKeybarHeight()` returns `acc.intrinsicContentSize.height`, which
calls `KeybarInputAccessory.contentHeight()`:
```swift
let width = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
let fitted = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
let h = fitted.height > 0 ? fitted.height : Self.seedHeight
```
On switch, the newly-active pane's keybar accessory is freshly attached and its `bounds.width`
is still 0 (not laid out yet), so `sizeThatFits` measures at the fallback width and returns a
degenerate height (~40 / seed), not the real 74. Once the accessory gets its real
`bounds.width`, the height corrects. So `kbH` is genuinely wrong (measured at width 0), which
makes `usableH` and the grid wrong for the frames before layout settles. This is the SAME
width-0-measurement class as prior sizing bugs (hence "feels like the sizing issue").
`armResizeSettle` (retained through KISS) coalesces the tmux resize COMMAND, but nothing
guards the LOCAL pane frame / seed paint against the transient wrong `kbH`.

### Fix
Use the keybar's already-cached last VALID measurement when the current measurement is
degenerate. `KeybarInputAccessory` already stores `lastMeasuredHeight` (set in
`intrinsicContentSize`). Change `contentHeight()` so a degenerate measurement (bounds width
<= 0, i.e. not yet laid out) returns `lastMeasuredHeight` (if it holds a prior valid value)
instead of the seed default:

```swift
private func contentHeight() -> CGFloat {
    // Not yet laid out (width 0) => sizeThatFits returns a degenerate height (the seed).
    // Fall back to the last VALID measurement so a freshly-attached accessory (e.g. on a
    // window switch) reports its real settled height, not a transient wrong one. This
    // stops the switch-time grid thrash (kbH 40 -> 74) that painted the seed at the wrong
    // size (device 2026-07-22).
    guard bounds.width > 0 else {
        return lastMeasuredHeight > 0 ? lastMeasuredHeight : Self.seedHeight
    }
    let fitted = host.sizeThatFits(in: CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
    let h = fitted.height > 0 ? fitted.height : Self.seedHeight
    DebugLog.shared.log(.keybar, "keybar:contentHeight h=\(h)")
    return h
}
```

This is width-driven (the true cause), handles legitimate height changes (predictor strip /
hidden-keybar / hardware keyboard update `lastMeasuredHeight` on their real re-measures), and
needs no timing/deferral gate. Width is otherwise stable across the storm (log: `bounds.width`
= 402 throughout), so no separate width fix is needed; the guard keys on `bounds.width > 0`
which is exactly the "laid out yet?" signal.

NOTE: there is no pure-Kit seam here (it is a UIKit measurement guard). The fix is App-tier,
verified by macOS CI compile + device. Keep it minimal and behavior-obvious.

## Issue D: alt-screen scroll grit (bounded improvement)

### Symptom
Alt-screen (`.appOwnsInput`) vertical scroll feels gritty / no momentum vs the smooth native
non-alt scroll.

### Root cause (verified in code + log)
Alt-screen scroll is our SYNTHETIC emitter, not native. Momentum DOES fire (fling via
`CADisplayLink`, 18/25 releases) and correctly emits SGR wheel events (not steppy arrows).
The fling tick runs every frame (regular cadence: the log's apparent "widening ticks" is an
artifact of the `if sent > 0` log guard, which only logs frames that cross a whole cell). The
real grit: a wheel event is ONE whole line minimum (`AltScreenScroll.wheelEvents` emits only
whole-cell runs). As the fling decays below ~1 cell/frame, many frames emit nothing, then one
frame emits a single click: a slow-dribble tail of punctuated single clicks. This is inherent
to SGR wheel (cannot send a fractional line); the last few lines of any decaying fling are
discrete jumps by definition.

### Fix (honest, bounded)
Cannot make discrete wheel lines sub-pixel smooth. Instead, END the fling crisply once it
decays below a small cells-per-second threshold, so it stops cleanly instead of dribbling out
slow single clicks that read as grit. Add an early-stop in `tickAltScreenFling` /
`ScrollMomentum`: when the momentum's current velocity (or its per-frame whole-cell rate)
drops below ~1 cell per few frames, stop the fling. Tune the threshold so a fast flick still
carries meaningfully but the gritty slow tail is cut.

Mechanism: `ScrollMomentum` already models velocity decay; add `isBelowScrollFloor(at:)`
(or extend `isFinished`) that returns true when the instantaneous velocity implies fewer than
~N cells/sec, and stop there. This is a Kit-testable pure addition (the threshold logic), with
the App tick loop calling it.

## Issue A: intermittent swipe (instrumentation only this round)

### Symptom
"Frequently swipe DOES change windows at a plain shell, but not always."

### Finding
Not reproduced in the log: every `drag-axis-lock` resolved cleanly, every `switchWindow`
committed, `drag-switch short` never fired. So the misses are NOT axis-lock misclassification.
Most likely the drag loses the gesture-recognizer race before `drag-begin` is even logged
(SwiftTerm's pan winning outright), which is invisible to the current post-winner logging.

### Fix (this round = instrumentation)
Add a log point at recognizer-fail / simultaneous-recognition level so the NEXT device build
captures the invisible misses: log when our tap/pan recognizers fail, and when a stray
(SwiftTerm) pan begins on the terminal view during what should have been a switch. No behavior
change; pure instrumentation under the `.gesture` category. Diagnose the actual fix next round
from the richer log.

## Scope + structure
Three independent tasks in one plan (one device build), each with its own device-verify check:
- Task 1 (B/C): `KeybarInputAccessory.contentHeight()` width-0 fallback. App-tier.
- Task 2 (D): `ScrollMomentum` scroll-floor early-stop (pure Kit + test) + App tick call.
- Task 3 (A): recognizer-fail / stray-pan logging in `TerminalGestureController`. App-tier.
Kept separate so a regression in one is isolatable.

## Testing
- Kit: Task 2's scroll-floor threshold gets EP/BVA tests (below floor -> stop; above ->
  continue; exact boundary). Task 1 + 3 are App-tier (macOS CI compile + device).
- Device matrix:
  - B/C: switch back and forth several times; the returned window renders at the CORRECT size
    immediately (no cursor-in-corner, no mis-sized redraw, no visible grid thrash).
  - D: alt-screen (vim/htop) flick-scroll ends crisply without a gritty slow single-click tail;
    a fast flick still carries.
  - A: (no user-visible change) confirm the next log now contains recognizer-fail / stray-pan
    lines when a plain-shell swipe fails to switch.

## Decision log
- B/C root = keybar measured at bounds.width=0 on fresh attach -> degenerate kbH -> grid
  thrash -> seed paints wrong size. Fix = fall back to `lastMeasuredHeight` when width<=0.
  (NOT hardcode 74: height legitimately varies; NOT "last one" caching per se: use the
  keybar's own last-valid measurement, which updates on every real re-measure.)
- D is largely inherent to SGR wheel (1 line minimum). Best available = crisp early-stop of
  the decaying fling, not fake sub-pixel smoothness.
- A not reproducible from current logs; add recognizer-level instrumentation, diagnose next round.
