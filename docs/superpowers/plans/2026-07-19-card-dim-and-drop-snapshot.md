<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Card-dim + drop-snapshot refactor (window-switch)

**Goal:** Replace the side-gradient gap-dim with a uniform dim ON the departing card, and
DROP the incoming-window snapshot preview entirely (slide the dimming card off over a solid
blank; the live window draws on tmux delivery).

**Why (device 2026-07-19):** (1) the side-gradient dimmed the exposed edge the user drags AWAY
from, reading backwards; a uniform dim ON the card travels with the finger and reads as "this
window is leaving". (2) The incoming snapshot flickers + is wrong-size because a `-CC` neighbor
window can have a genuinely DIFFERENT pane layout, so its `capture-pane` never reliably matches
the current window's shape. Dropping the preview removes the whole flicker/size problem class
and simplifies the commit path. The both-ready gate already draws the live window on delivery.

**Keep working:** the live-drag (`paneContentView.transform` follows finger, frame-vs-transform
fix), the both-ready gate (`switchAnimDone`/`switchDelivered`/`finishSwitchHandoffIfReady`),
generation guard (C1), the 1.5s delivery timeout, edge-wrap, axis-lock. Do NOT regress these.

## Change 1: uniform card-dim (replaces gap-dim)

- **ContainerView:** replace `gapDimView`/`gapDimGradient`/`ensureGapDimInstalled` with a
  `cardDimView` added as a subview OF `paneContentView` (so it travels with the transform),
  pinned to `paneContentView.bounds`, `backgroundColor = .black`, `alpha = 0`,
  `isUserInteractionEnabled = false`. Add `cardDimOverlay()` accessor + install in
  `layoutSubviews` (frame = paneContentView.bounds) and in `ensurePaneContentViewInstalled`.
- **Coordinator.updateSwitchDrag:** set `cardDimOverlay().alpha = GapDim.opacity(offset,width)`
  (no gradient, no endpoints). Keep the `render:gap-dim` -> rename `render:card-dim` log
  (alpha + offset only).
- **Remove:** `updateGapDim` gradient/endpoints body, `clearGapDim` -> `clearCardDim`
  (alpha 0). `commitSwitchDrag` I2 `gapDimOverlay().alpha = maxOpacity` -> `cardDimOverlay()`.
- **Kit GapDim:** DELETE `endpoints`/`Endpoints`/`ExposedNeighbor`-coupling; KEEP `opacity`
  + `maxOpacity`. Update GapDimTests (drop endpoints tests, keep opacity BVA).
- Note: `ExposedNeighbor` still used by `WindowDragModel`/gesture `onDragUpdate` signature;
  leave that enum in WindowDragModel, just stop using it for gradient direction.

## Change 2: drop the incoming snapshot preview

- **commitSwitchDrag:** remove the `host = snapshotStore?.snapshotView(...)` block (addSubview,
  layout, layoutIfNeeded, freeze, `revealedSnapshot = ...`, `host?.transform` in the animate).
  The animation becomes: `content.transform = outX` only (card slides off over the container's
  own background). Keep `pendingSwitchWindow = neighbor`, the gate, generation, timeout, log
  (`snapshot=false` -> drop that field).
- **Teardowns** (finish/cancel/timeout/discard): remove `revealedSnapshot` removal +
  `unfreezeRevealedSnapshot`. Keep the transform reset + `clearCardDim` + gate-flag resets.
- **Remove members:** `revealedSnapshot`, `unfreezeRevealedSnapshot`.
- **beginSwitchReveal:** drop `refreshNonActive` call (no snapshots needed). The method may
  become a near-noop (keep the `lastLoggedDragOffset = nil` reset + discardCommitted guard for
  a new-drag-interrupting-commit; rename intent).
- **discardCommittedSnapshot:** now only resets transform + gate + cardDim (no snapshot view).
- **ConnectionViewModel:** remove `snapshotStore` property, its `WindowSnapshotStore(...)`
  init, the `refreshNonActive` call in `onStateChanged` (line ~945), `makeSnapshotView`.
- **WindowSnapshotStore.swift:** DELETE the file (no longer referenced).
- **TmuxRuntime:** remove `captureSnapshot`/`onSnapshotCaptured`/snapshot capture-purpose
  plumbing IF only used by the store (verify; the live seeder uses a separate `captureHistory`).
- **Ensure the container background** behind `paneContentView` is a sane solid (theme bg) so
  the card slides off over a clean fill, not transparent/garbage.

## Verify
- Kit: `swift test` green (GapDim opacity tests only; drop endpoints).
- Device: slow-drag -> the CARD itself darkens uniformly with distance (travels with finger);
  commit -> card slides off over solid bg, live window draws on delivery (brief blank on slow
  link OK), NO flicker, NO wrong-size snapshot. Gate/edge-wrap/double-flick still correct.
- App-tier compiles on macOS CI (watch the @MainActor-per-method trap on any new overlay method).
