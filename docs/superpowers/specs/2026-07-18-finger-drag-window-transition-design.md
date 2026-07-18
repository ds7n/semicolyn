<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Finger-drag window transition (design)

**Date:** 2026-07-18
**Supersedes:** the release-triggered window-switch slide (`WindowTransition`, shipped PR #102,
build 56 - user rejected the feel).
**Prior context:** `docs/superpowers/topics/2026-07-17-finger-drag-window-transition-resume.md`.

## Goal

Make switching tmux windows feel like the iOS home-screen / Photos app: the window **drags with
the finger live during a horizontal swipe**, revealing the adjacent window in the exposed gap, and
**commits the switch only when dragged past a threshold** (or flicked). A short drag springs back
to the current window. This replaces the current model, where the animation happens *after* the
switch is already decided (slide-out on release, slide-in on tmux delivery).

## The `-CC` constraint and why snapshots

Under `tmux -CC` the next window's live panes do not exist locally mid-drag: tmux destroys and
recreates panes on switch, so there is no live `TerminalView` to reveal in the gap. The revealed
area is filled with a **snapshot** of the adjacent window, captured via tmux `capture-pane`.

Feasibility is already proven (build-56 device log, resume doc): `capture-pane -p -e -S <start>
-t %<pane>` returns real bytes for panes in **non-active** windows (e.g. `%10`, `%6` while `@0`
active, 16421 / 7085 bytes). The capture mechanism (`CapturePaneCommand`, `PaneHistorySeeder`)
exists and is Kit-tested; this design points it at the transition.

## Locked decisions

1. **Reveal content:** real `capture-pane` snapshots (not dimmed placeholders).
2. **Snapshot scope:** all windows seeded (not just prev+next).
3. **Refresh policy:** capture on connect + re-capture all non-active windows at drag-start. No
   periodic timer, no `%output`-triggered recapture.
4. **Commit rule:** distance **or** velocity - commit if dragged past ~40% of pane width OR
   flicked past a velocity threshold; else spring back. The decision is a pure Kit function.
5. **Commit handoff:** snapshot settles to fully cover the pane, live panes swap in **under** it,
   then the snapshot is removed (no empty flash) + a **1.5s timeout** safety-net restores the
   current window if tmux never delivers.
6. **Axis lock:** decided once when the finger leaves the ~12pt dead-zone (still ~1.7:1 biased
   toward vertical/scroll); the axis is fixed for the whole drag (no mid-drag scroll<->switch flip).
7. **Mode coverage:** the live switch works in **all** interaction modes. Axis-lock runs first;
   a horizontal-dominant drag switches windows even on a `.appOwnsInput` (Claude/vim) or
   `.mouseReporting` pane, while a vertical drag still goes to the app (wheel/arrows) or scrolls.
8. **Edge behavior:** keep the current wrap at the ends of the window list (`stepIndex`).

## Architecture

Preserves the two-tier discipline: **decision logic in Kit (Linux-tested, `Sendable`), UIKit
motion in App (macOS-CI / device-verified).**

### New Kit units (pure, unit-tested)

| Unit | Responsibility |
|------|----------------|
| `DragAxisLock` | Given cumulative `(dx, dy)` + `isMultiWindowTmux`, resolve **once** past the 12pt dead-zone to `.scroll`, `.switchWindow(direction:)`, or `.pending` (inside dead-zone). Uses the existing 1.7 dominance ratio + multi-window gate. Replaces the release-time `GestureClassifier.classify` with an at-dead-zone lock. |
| `WindowDragModel` | Map live translation `dx` -> a clamped visual offset for the content transform (bounded to +/-width; optional rubber-band past the edge windows). Reports which neighbor (prev/next) the current offset exposes (by sign). Pure geometry. |
| `SwitchCommitDecision` | `commit(dx:width:velocity:)` -> `.commit(delta:)` \| `.springBack`. Distance (~40% width) OR velocity flick. Returns the exact `delta` sign per swipe direction (content-follows-finger: rightward -> delta -1). |

Shared constants (`deadZonePoints = 12`, `switchDominanceRatio = 1.7`) move to / are reused by
`DragAxisLock`; the content-follows-finger direction mapping stays as in `windowSlideDirection`.

### App tier

- **`TerminalGestureController`** gains a live horizontal-drag path. On a horizontal axis-lock it
  drives `paneContentView.transform` from `WindowDragModel` on each `.changed`, positions the
  exposed neighbor's snapshot in the gap, and on `.ended` runs `SwitchCommitDecision` -> commit
  animation or spring-back. The existing vertical scroll (native pan) and alt-screen arrow/wheel
  (`altScreenPan`) paths are unchanged; axis-lock chooses between them once per drag.
- **`WindowSnapshotStore`** (new, App): owns off-screen snapshot views per window, fed by
  `capture-pane`. See lifecycle below.
- **`WindowTransition`** is **removed**. Its release-triggered `slideOut` / `beginPending` /
  `consumePendingSlideIn` model is superseded by finger-driven transforms + a commit animator.
  The 1.5s **timeout** concept is carried into the commit path.
- **`paneContentView`** (the transform wrapper in `ContainerView`) is **kept** unchanged - it is
  the foundation the finger-drag rides on. `windowSlideDirection` / `SlideEdge` are kept (they
  still describe which edge reveals which neighbor).

Only `CGAffineTransform` assignment and `UIView.animate` live in App; every threshold/geometry
decision is read from a Kit unit.

## Snapshot lifecycle (`WindowSnapshotStore`)

**A snapshot** = an off-screen `TerminalView` (App) seeded via `capture-pane -p -e -S <start>
-t %<pane>` + `CapturePaneCommand.reconstructHistory`, laid out at the pane's geometry. A
multi-pane window captures each pane and places each snapshot sub-view at that pane's rect from the
window's `visibleLayout` (the same rect math `apply(state:)` already uses).

```
connect / window-list changes
  -> for every window: capture-pane all its panes -> build/refresh snapshot view
drag .began (before axis lock)
  -> re-fire capture-pane for all NON-active windows (active is already live)
  -> reply arrives async -> snapshot view's bytes updated in place
commit
  -> the new active window's snapshot is consumed (handoff, below); the window that just
     became inactive gets a fresh capture (it is now a neighbor)
```

- **Storage:** `[WindowID: SnapshotView]`.
- **Staleness:** each snapshot carries a generation tag; a late `capture-pane` reply for a window
  that is no longer relevant (window closed, generation superseded) is **dropped**, never applied
  to the wrong view.
- **Non-blocking:** a missing / not-yet-arrived snapshot at reveal time shows the last-known
  content (or empty on the very first drag before any reply lands). The drag never blocks on a
  reply.
- **Geometry:** snapshots built at the current container bounds / cell metrics. Rebuilt on a
  window-list or metrics change.
- **Cost control:** capture fires at connect + per-drag-start only. No periodic timer, no
  `%output` trigger, so a busy background window generates no capture churn.

> Non-blocking note (not a blocker for v1): "all windows" means N `capture-pane` round-trips on
> connect. For typical sessions (2-5 windows) this is negligible; a pathological 20-window session
> is 20 captures. If it ever bites, a cap / lazy-on-first-drag seeding is a later refinement.

## Gesture flow, commit / cancel, handoff

**During a horizontal-locked drag:**

```
.began   -> snapshot store refresh (non-active); position the DIRECTION neighbor's snapshot
            just off the revealing edge
.changed -> offset = WindowDragModel.offset(dx, width)
            paneContentView.transform = translate(offset)
            neighbor snapshot x tracks the exposed edge
.ended   -> SwitchCommitDecision.commit(dx, width, velocity)
```

If the finger reverses across center (drag right then left), the exposed snapshot swaps to the
other neighbor (offset sign from `WindowDragModel`).

**Commit (`.commit(delta)`):**
1. Animate `paneContentView` + the incoming snapshot the rest of the way so the snapshot fully
   covers the pane. Send `select-window` (via existing `switchToWindow` / `selectWindow`).
2. Arm a 1.5s timeout.
3. tmux delivers the new active window -> `apply(state:)` mounts the real live panes into
   `paneContentView` (transform reset to identity) **under** the covering snapshot, then removes
   the snapshot. No empty flash.
4. Timeout fires first (delivery failed / slow) -> remove snapshot, restore the current window's
   live content, refresh its snapshot.

**Spring-back (`.springBack`):** animate `paneContentView.transform` back to `.identity`, drop the
exposed snapshot, send no tmux command.

**Edge windows:** wrap is kept (`stepIndex`); the wrap neighbor is a real window, so its snapshot
reveals normally.

**Mode routing:** axis-lock runs first in every mode. Horizontal-dominant -> switch (live
transform) on any pane, including `.appOwnsInput` / `.mouseReporting`; vertical -> the existing
scroll / wheel / arrow path. The two live paths are mutually exclusive per drag (axis locked once),
so the switch transform and app-scroll arrow emission never both fire in one drag.

## Error handling / edge cases

| Case | Behavior |
|------|----------|
| tmux never delivers after commit | 1.5s timeout -> remove snapshot, restore + refresh current window |
| Late `capture-pane` reply for stale window | Dropped via generation tag; never applied to wrong view |
| Snapshot missing at reveal (first drag, reply not back) | Gap shows empty / last-known; drag never blocks on the reply |
| Single window (`isMultiWindowTmux == false`) | Switch axis never arms; drag is always scroll |
| Window count / layout changes mid-session | Store rebuilds snapshots on window-list change; multi-pane placed by `visibleLayout` rects |
| Drag reverses direction mid-flight | Exposed snapshot swaps to the other neighbor (offset sign) |
| Font pinch / rotation during a drag | Drag uses `width` snapshotted at `.began`; store rebuilds at new metrics on next capture |

## Testing

Kit units, real assertions per `2026-06-18-testing-standards-design.md` (EP + BVA, observable
values, negatives assert the specific outcome):

- **`DragAxisLock`:** dead-zone radius boundary (11.9 vs 12.1pt -> `.pending` vs resolved); 1.7
  ratio boundary (just-under -> `.scroll`, just-over -> `.switchWindow`); multi-window gate off ->
  always `.scroll` even for a clearly horizontal drag; direction sign for left vs right swipe.
- **`WindowDragModel`:** offset at dx=0 (identity), mid, =width (fully revealed), >width
  (clamp / rubber-band); exposed-neighbor sign for +dx vs -dx.
- **`SwitchCommitDecision`:** below-distance + low-velocity -> `.springBack`; past-distance ->
  `.commit` with exact `delta`; short-but-fast flick -> `.commit`; assert the exact `delta` sign
  for each swipe direction (not merely "committed").

App-tier motion (transform tracking, snapshot swap, timeout, `WindowSnapshotStore` capture wiring)
is validated on device + macOS CI, per the tier rule (App code does not compile on Linux / is
invisible to `swift test`).

## What is replaced / evolved

| Element | Fate |
|---------|------|
| `GestureClassifier.classify` (release-time) | -> `DragAxisLock` (at-dead-zone). Old file removed or reduced to shared constants `DragAxisLock` reuses. |
| `WindowTransition` (release-triggered slide) | **Removed.** Superseded by finger-driven transforms + commit animator; 1.5s timeout concept carried into commit. |
| `windowSlideDirection` / `SlideEdge` | Kept (still describe which edge reveals which neighbor). |
| `paneContentView` | Kept - the transform foundation the finger-drag rides on. |
| `capture-pane` path (`CapturePaneCommand`, `PaneHistorySeeder`) | Reused - now also feeds `WindowSnapshotStore`. |

## Out of scope (v1)

- A window-overview / grid (all-windows seeding makes it possible later, but it is not built here).
- Periodic / `%output`-driven snapshot refresh.
- Rubber-band "no more windows" bounce at the list ends (wrap is kept).
- Any change to vertical scroll / alt-screen wheel-arrow emission.
