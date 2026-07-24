<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Window-switch animation timing fix: animation owns the handoff

**Date:** 2026-07-18
**Fixes:** the slide-off + gap-dim pivot (`2026-07-18-window-switch-slideoff-pivot-design.md`,
TF59) - device-tested and found to show ZERO visible animation despite the switch working.
**Debugging:** root-caused from real device syslog (`data/syslog/semicolyn-bunknown-2026-07-18.log`),
per `superpowers:systematic-debugging`.

## Root cause (proven by device syslog, not assumed)

The switch works (window changes, correct direction) but shows no animation. The TF59 syslog
timestamps prove a timing race:

| Evidence (measured from the log) | Value |
|---|---|
| Commit slide animation duration (`withDuration: 0.18`) | 180 ms |
| tmux window delivery: `switch commit` -> `switch handoff complete` | ~100-120 ms (every swipe) |
| Drag phase | 1-2 `.changed` samples; first sample already `dx=159` (fast flick) |

Three compounding causes, all confirmed:
1. **The handoff wins the race.** tmux delivers the new window (~120 ms) BEFORE the 180 ms slide
   finishes, and `completePendingSwitchIfNeeded` resets `paneContentView.transform = .identity`
   mid-animation -> the slide is cut off ~60-80 ms into a 180 ms animation.
2. **The commit snapshot covers the pane instantly.** At commit the snapshot is added on top at the
   final full frame, so even the partial slide is hidden BEHIND it.
3. **The drag is a near-instant flick.** The whole gesture is ~100 ms with 1-2 samples, so the live
   drag phase is imperceptible too.

None of this is a wiring bug - the animation code is correct, it just never gets to play. (An
earlier reason we could not see this: there was NO per-`.changed` or handoff-timing log; the pivot's
gesture logs only recorded begin/commit/handoff, so the sub-frame race was invisible until the
timestamps were measured.)

## The fix: the ANIMATION owns the transition timing, not tmux

Invert control. The commit slide plays to completion regardless of when tmux delivers; the live
window swaps in only when BOTH the animation has finished AND tmux has delivered (a both-ready
gate). tmux delivery becomes a readiness signal, not the trigger.

### Part A - Live drag (already implemented; unmasked)

During the drag, `updateSwitchDrag` already sets `content.transform` per `.changed` and
`updateGapDim` ramps the overlay (confirmed firing in the syslog). No snapshot is shown mid-drag
(the exposed gap shows the gap-dim gradient only). A SLOW drag therefore shows the current window
sliding off + the gap darkening. No change needed here beyond ensuring the commit path no longer
stomps it prematurely (Part C).

### Part B - Commit page-turn animation (paired slide)

On commit, ONE 180 ms animation (`curveEaseOut`):
- The current window (`paneContentView`) slides fully off toward the release edge (`outX`).
- The pre-warmed NEW-window snapshot slides IN from the OPPOSITE edge: placed at its final frame via
  `WindowSnapshotStore.layout(...)`, started at `+/- width` off the incoming edge, animated to
  `.identity`. (Final-frame layout = no zoom mismatch, the pivot's core property, preserved.)
- The gap-dim rides between them (held at `GapDim.maxOpacity` for the commit, already set).

This is an iOS page-turn: old leaves one edge, new arrives from the other. The incoming edge is the
mirror of the outgoing edge (`windowSlideDirection(delta:)` gives `out`; the snapshot enters from the
`in` edge).

### Part C - Both-ready gate (the actual race fix)

Two readiness flags on the Coordinator:
- `switchAnimDone: Bool` - set true in the commit animation's completion block.
- delivery - `completePendingSwitchIfNeeded(newActive:)` fires when tmux changes the active window;
  instead of resetting transforms directly, it records delivery and calls the shared finisher.

A shared `finishSwitchHandoffIfReady()`:
- Guard: only proceed when `switchAnimDone == true` AND the switch was delivered (the pending window
  became active). Whichever of the two async events finishes LAST triggers the actual handoff.
- Teardown (unchanged content, moved here): cancel the timeout, remove the covering snapshot, reset
  `paneContentView.transform = .identity`, clear the gap-dim, reveal the live panes (which
  `apply(state:)` has already mounted UNDER the snapshot).

Orderings handled:
- tmux fast (120 ms) < anim (180 ms): delivery arrives first, holds on the snapshot until the
  animation completion sets `switchAnimDone`, then the finisher runs at ~180 ms. (This is the common
  case that was broken.)
- tmux slow > anim: the animation completes first (snapshot fully in place, `switchAnimDone` true),
  holds until delivery, then the finisher runs on delivery.
- The existing 1.5 s timeout still backstops a never-delivered switch (`failPendingSwitch` runs the
  same teardown + restores the current window).

### Coordinator state changes

| Element | Change |
|---|---|
| `switchAnimDone: Bool` (new) | Reset `false` at commit-start; set `true` in the commit animation completion. |
| `commitSwitchDrag(delta:)` | Paired slide (out + in from opposite edge); completion sets `switchAnimDone` + calls `finishSwitchHandoffIfReady()`. Snapshot placed at final frame but STARTED off the incoming edge (not instantly covering). |
| `completePendingSwitchIfNeeded(newActive:)` | No longer resets transforms directly; records delivery and calls `finishSwitchHandoffIfReady()`. |
| `finishSwitchHandoffIfReady()` (new) | Guard `switchAnimDone && delivered`; then the teardown (cancel timeout, remove snapshot, identity transform, clear dim). |
| `failPendingSwitch()` | Unchanged teardown + restore current; also resets `switchAnimDone`. |
| `discardCommittedSnapshot()` (C1) | Also resets `switchAnimDone` + delivery flag, so a new drag interrupting a pending commit starts clean. |
| `clearPendingSwitch()` | Unchanged (timer + pending window). |

Delivery tracking: `pendingSwitchWindow` already records the target; delivery is "the active window
became `pendingSwitchWindow`". `finishSwitchHandoffIfReady` checks that plus `switchAnimDone`. (No
separate `delivered` bool strictly required - `completePendingSwitchIfNeeded` is only called on a
real active-window change - but a small explicit `switchDelivered: Bool` is clearer and avoids a
stale-`pendingSwitchWindow` edge; the plan will use an explicit flag.)

## Diagnostics (this is what was missing)

Add gesture-category logs so the NEXT syslog proves the ordering directly:
- `commitSwitchDrag`: `switch anim-start delta=... dur=0.18` (already logs commit).
- Animation completion: `switch anim-done`.
- `completePendingSwitchIfNeeded`: `switch delivered active=@N animDone=<bool>`.
- `finishSwitchHandoffIfReady`: `switch finish (both-ready)` OR `switch finish WAIT anim=<bool> delivered=<bool>`.
- OPTIONAL (low-rate): sample `updateSwitchDrag` every Nth `.changed` (`drag-slide offset=... alpha=...`)
  so a future trace shows the live-drag phase actually ramping. Gate behind `.gesture` (default OFF).

These make a "no animation" report immediately diagnosable from the log (was the anim interrupted?
did delivery beat it? did the finisher run once or twice?).

## Error handling / edge cases

| Case | Behavior |
|---|---|
| tmux delivers before anim ends (common) | Delivery held; finisher runs at anim completion (both-ready). |
| tmux delivers after anim ends | Anim held on snapshot; finisher runs on delivery. |
| tmux never delivers | 1.5 s timeout -> `failPendingSwitch` teardown + restore current. |
| New drag interrupts a pending commit (C1) | `discardCommittedSnapshot` tears down snapshot + resets `switchAnimDone`/delivery + transform + dim before the new drag. |
| Snapshot not captured at commit | Slide the current window off over the dark gap; no incoming snapshot; live window draws on delivery (finisher still gated on both-ready, anim done immediately usable). |
| Fast flick (no visible drag) | The COMMIT page-turn (180 ms, plays fully now) is what the user sees - the fix's main win. |
| Slow drag | Live finger-tracking (Part A) shows the slide + darkening gap before release. |
| esc-pill switch (no drag) | `completePendingSwitchIfNeeded` guards on a pending drag-switch; a non-drag switch has none pending -> no-op (unchanged). |

## Testing

- Kit: no new pure unit (the timing/both-ready coordination is inherently UIKit-async). Existing
  `GapDim` / `WindowDragModel` / `DragAxisLock` / `SwitchCommitDecision` tests are untouched and stay
  green.
- App tier: the paired page-turn animation, the two-flag both-ready gate, and the C1 interaction are
  validated by the macOS CI compile + device retest (per the tier rule). The added diagnostics make
  the device retest self-verifying (the syslog shows the ordering).

## Out of scope

- Any Kit logic change (this is a UIKit-timing fix).
- Reintroducing the neighbor reveal DURING the drag (rejected; gap-dim only mid-drag).
- Tuning the 180 ms duration (kept; the fix is the race, not the duration - revisit only if the
  page-turn still reads too fast after the race is fixed).
- Making the commit fully finger-position-driven (interactive-percent-driven transition) - a larger
  redesign; the fixed 180 ms page-turn is sufficient once it actually plays.
