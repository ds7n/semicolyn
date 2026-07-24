<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Window-switch transition pivot: slide-off + gap-dim (prep, don't reveal)

**Date:** 2026-07-18
**Pivots:** the live paired-card reveal shipped in `2026-07-18-finger-drag-window-transition-design.md`
(PR #103, TestFlight build device-tested - user rejected the feel).
**Supersedes:** the visible-neighbor reveal portion of that design; keeps the rest.

## Why the pivot

Device test of the paired-card reveal (the neighbor window sliding in, tracking the finger):
1. The live reveal felt "weird".
2. The revealed neighbor's **zoom level was off** (the snapshot was drawn under a partial mid-drag
   transform against live metrics, so it did not match the pane).
3. The edge seam-dim never appeared - it was attached to the neighbor-snapshot host view, which
   frequently did not exist at drag time, so there was nothing to render the gradient on.

User decision: **keep the background prep** (pre-capture the target window so the post-commit
switch is instant) but **stop showing the new window during the drag**. The drag should slide the
CURRENT window off with a darkening gap behind it; the pre-warmed new window is drawn only on
commit.

This is a **simplification** of the shipped feature: it removes the live-reveal machinery and, by
construction, eliminates the zoom-mismatch bug (the snapshot is only ever drawn full-size in the
pane's final position, never under a partial drag transform).

## What is kept vs changed

| Element | Fate |
|---------|------|
| `DragAxisLock` (Kit) | **Keep as-is** - axis-lock at the 12pt dead-zone, switch vs scroll. |
| `WindowDragModel` (Kit) | **Keep** - drag offset + rubber-band at list ends. `exposedNeighbor` still used to pick the gap side + the target window. |
| `SwitchCommitDecision` (Kit) | **Keep as-is** - distance/velocity commit threshold. |
| `WindowSnapshotStore` + capture routing (`captureSnapshot`/`onSnapshotCaptured`) | **Keep** - still pre-warms all non-active windows on connect + drag-start. Consumed ONLY at commit now. |
| `updateSwitchDrag` live neighbor reveal (neighbor host add/position, `snapshotView(for:)` during drag) | **REMOVE** - no neighbor view is created or shown during the drag. |
| Seam-dim on the neighbor host (`installSeamDim`/`updateSeamDim` attached to `host`) | **REPLACE** with a gap-dim overlay on an always-present sibling view (see Mechanic 2). |
| Commit handoff (snapshot settle -> swap live under -> remove; 1.5s timeout) | **Keep**, but the snapshot is drawn ONLY here, at the pane's final full-size frame. |
| `neighborWindow(of:delta:)` wrapping | **Keep** - edge-wrap on commit. |
| `paneContentView` transform wrapper | **Keep** - the foundation the current window slides on. |

## Mechanic 1 - Drag (current window slides off, nothing revealed)

Gesture pipeline unchanged through axis-lock (`TerminalGestureController.driveLiveSwitch` ->
`DragAxisLock.resolve`). A horizontal-locked drag is a switch.

- **`.began`:** still calls `beginSwitchReveal` -> `snapshotStore.refreshNonActive(state:)` so the
  target window's panes are pre-warmed for the eventual commit. (Prep stays.)
- **`.changed`:** `paneContentView.transform = translate(WindowDragModel.offset(dx, width))` - the
  current window's content slides with the finger (unchanged). Then update the gap-dim (Mechanic 2).
  **DELETED:** the block that resolves the neighbor window, calls `snapshotStore.snapshotView(for:)`,
  adds the neighbor host as a subview, and positions it at `base + offset`. No `revealedSnapshot`
  state is set during the drag.
- The `WindowDragModel` rubber-band at the first/last window stays (drag resists past the ends).

`updateSwitchDrag(offset:exposed:)` shrinks to: set `paneContentView.transform`, then
`updateGapDim(exposed:progress:)`. It no longer touches snapshot views.

## Mechanic 2 - Gap-dim (gradient in the exposed gap)

A single dim overlay `UIView` (`gapDimView`), owned by the coordinator, is installed as a sibling
BEHIND `paneContentView` (so the sliding window reveals it), pinned to `bounds` in `layoutSubviews`,
and present for the whole session. Being always in the hierarchy is the fix for the prior
never-rendered bug (the old gradient was attached to a neighbor host that often did not exist).

- It hosts a `CAGradientLayer` sized to `bounds`. The gradient is **darkest at the edge nearest the
  departing window, fading across the gap.** Direction flips with drag direction: `exposed ==
  .previous` (rightward drag, window slides right, gap opens on the LEFT) -> dark on the gap's right
  edge (nearest the departing window); `exposed == .next` -> mirror. Set the gradient
  `startPoint`/`endPoint` from `exposed` on each `.changed` (cheap; or only when `exposed` flips).
- **Opacity ramps with drag progress:** `gapDimView.alpha = min(abs(offset) / width, 1) * maxDim`,
  `maxDim = 0.5`. At rest (offset 0) the overlay is invisible; at the commit distance it is at full
  dim. Because the current window slides off, the vacated gap is exactly where this shows through.
- Cleared (`alpha -> 0`) on spring-back and after the commit handoff completes / times out.

Pure helper (Kit-testable): `gapDimAlpha(offset:width:maxDim:) -> Double` = the clamped ramp above.
The gradient endpoints per `exposed` can also be a pure mapping (`gapDimEndpoints(exposed:)`), keeping
the direction logic Linux-tested; only the `CALayer`/`UIView` assignment is App-tier.

## Mechanic 3 - Commit + handoff (snapshot only here, full-size)

On release, `SwitchCommitDecision.resolve(dx, width, velocity)` -> `.commit(delta)` | `.springBack`
(unchanged).

**Commit (`.commit(delta)`):**
1. Animate `paneContentView` the rest of the way off-screen in the drag direction (finish the
   slide); the gap-dim holds at full.
2. Send `select-window` for `neighborWindow(of: active, delta:)` (edge-wrap kept).
3. **Draw the pre-warmed snapshot at the pane's FINAL, full-size frame** (identity transform), via
   `WindowSnapshotStore.snapshotView(for:)` + `layout(window:in:bounds:cellWidth:cellHeight:)` using
   the CURRENT container bounds + cell metrics. This is the ONLY place a snapshot is shown. It
   covers the pane so there is no blank flash. (If the snapshot is not yet captured, hold the gap
   grey - see Edge cases.)
4. Arm a 1.5s timeout.
5. When tmux delivers the new active window, `apply(state:)` mounts the real live panes UNDER the
   snapshot, resets `paneContentView.transform` to identity, removes the snapshot, and clears the
   gap-dim. No blank flash.
6. Timeout fires first (slow/failed switch) -> remove snapshot, restore the current window, clear
   the gap-dim.

**Spring-back (`.springBack`):** animate `paneContentView.transform` back to `.identity`, ramp
`gapDimView.alpha` -> 0. No tmux command.

**Zoom fix (explicit):** the snapshot is rendered exactly once, at commit, at the pane's final frame
via `layout(...)` against current metrics. It is never shown under a partial drag transform, so the
"zoom level is off" artifact (snapshot scaled/positioned mid-drag vs live metrics) cannot occur.

## Interaction / state

- Coordinator state during a switch: `switchDragActive` (axis locked to switch), `pendingSwitchWindow`
  + `pendingSwitchTimeout` (commit handoff, unchanged), and the committed covering snapshot
  (`revealedSnapshot`) which now exists ONLY between commit and handoff, never during the drag.
- The rapid-recommit timeout guard (cancel prior timeout before arming) and the
  `clearPendingSwitch()` on cancel/new-drag (both from the shipped feature's review) are retained.
- Mode coverage unchanged: switch works in `.localScroll` + `.appOwnsInput` (the two modes where our
  pan handlers own the drag); `.mouseReporting` yields the drag to the app.

## Error handling / edge cases

| Case | Behavior |
|------|----------|
| Snapshot not yet captured at commit | Hold the gap grey (gap-dim stays) until tmux delivers the live window; then draw live directly. No snapshot shown that frame. |
| tmux never delivers after commit | 1.5s timeout -> remove snapshot (if any), restore current window, clear gap-dim. |
| Single window (`isMultiWindowTmux == false`) | Switch axis never arms; drag always scrolls; no gap-dim. |
| Drag reverses across center mid-flight | Gap side flips (recompute `exposed` from offset sign); gradient endpoints flip; alpha follows `abs(offset)`. |
| Rotation / font pinch during a drag | Drag uses `width` snapshotted at `.began`; `gapDimView` re-pinned in `layoutSubviews`; snapshot (commit only) drawn at then-current metrics. |
| Rapid second commit before first delivers | Prior `pendingSwitchTimeout` cancelled before arming the new one (retained guard). |

## Testing

Kit (Linux-tested, real assertions):
- **`gapDimAlpha(offset:width:maxDim:)`:** 0 at offset 0; `maxDim` at offset == width; clamped at
  `maxDim` past width; monotonic in between; BVA at the boundary.
- **`gapDimEndpoints(exposed:)`** (if extracted): `.previous` vs `.next` produce mirrored
  start/end points; `.none` -> a defined default (no dim).
- `DragAxisLock` / `WindowDragModel` / `SwitchCommitDecision` tests are unchanged (those units are
  untouched).

App-tier (macOS-CI compile + device): the slide-off transform, the `gapDimView` install + alpha
ramp + gradient direction, and the commit snapshot-at-final-frame handoff. Per the tier rule, App
code is validated by the macOS CI job + device, not `swift test`.

## Out of scope

- Any live rendering of the neighbor window during the drag (the thing being removed).
- Real 3D curl / parallax (already rejected).
- EternalTerminal transport (a separate unmerged track: `feat/et-ios-build` /
  `docs/et-transport-spec`; the portable `eternaltermlib` is built but the semicolyn-side
  xcframework + `libetios` wrapper + Transport picker are NOT in this build - noted here only to
  record that its absence is expected, not a regression of this work).
