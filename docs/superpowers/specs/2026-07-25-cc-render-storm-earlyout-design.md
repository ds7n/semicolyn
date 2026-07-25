<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# tmux -CC render-storm early-out — design (2026-07-25)

## Problem

`ContainerView.layoutSubviews` (`App/TmuxPaneContainer.swift`) runs ~60×/s during
drags, keyboard show/hide, and `%output` churn (device trace: **31 `sizing:tmux`
passes in 0.5s**). Its entire body is a pure function of three inputs:

- `bounds.size`
- the measured cell metrics (`cell.w`, `cell.h`)
- the first-responder keybar height (`kbH`)

Yet on **every** pass it recomputes the grid, walks the panes to measure the keybar,
builds and emits the `sizing:tmux` log, and queues a `DispatchQueue.asyncAfter`
(re-arming the resize debounce). The tmux `refresh-client` is already coalesced by
`ResizeDebounce`, so tmux is not spammed — but the per-frame CPU (keybar walk, grid
math, ~60 queued closures/sec) is pure waste when the three inputs did not change.

This is a performance/battery issue, **not a correctness bug**: the output is right,
just computed far more often than needed.

## Fix

A single early-out at the top of `layoutSubviews`, keyed on the exact inputs the body
depends on.

1. Compute the three inputs (cheap: `resolvedCell()` is cached; `firstResponderKeybarHeight()`
   is a small pane walk).
2. Compare against a stored `lastLayoutInputs` value.
3. **Identical → return immediately**, before the grid math, the `sizing:tmux` log, and
   `noteClientSize`.
4. **Changed → store the new value and run the existing body unchanged.**

### Guard key

`(bounds.size, cell.w, cell.h, kbH)` — exact equality on all four. Any real geometry
change differs in at least one component and still recomputes:

- rotation / split / window switch → `bounds.size`
- pinch-zoom → `cell` (via `invalidateCachedCell()` clearing `cachedCell`)
- predictor strip appearing / keyboard show-hide → `kbH`

Only true no-op repeats are skipped.

### What stays exactly as-is

The grid computation, the `sizing:tmux` log, `noteClientSize` + `ResizeDebounce`,
`armResizeSettle`, and the bounds-change `relayoutExistingPaneFrames` block (its own
`lastLaidOutBounds` guard remains — now subsumed by the outer early-out but harmless).
No behavior changes; only redundant passes are elided.

### Pinch coupling

`invalidateCachedCell()` (fired on a pinch font change) already clears `cachedCell`, so
the next `resolvedCell()` returns a new value and the guard's `cell` differs → recompute
fires. Belt-and-suspenders: `invalidateCachedCell()` also resets `lastLayoutInputs = nil`
so the next pass is unconditionally forced through.

## Verification

The `sizing:tmux` log line stays and fires once per **non-skipped** pass. Skipped passes
return before it, so its frequency in a drag trace is the before/after metric (the TODO's
stated gauge). Capture a drag trace on the next TF build; the ~31-passes-in-0.5s should
drop to a handful (only real geometry changes).

## Testing

The "did inputs change" check is a trivial struct equality, not logic worth extracting to
a Kit unit. The real risk is behavioral — does it still recompute when it should — which
the guard-key design covers and the device trace confirms. App-tier → macOS CI compiles it.

## Scope

Early-out only. The ~1s tmux `list-panes` context poll that partly drives the churn is
**not** touched here (a possible separate follow-up).

## Risk

Low–moderate. It is the recently-stabilized layout/grid/pane-frame path, but the change is
purely additive: an early return on proven-redundant inputs, with every real trigger still
flowing through. The trace comparison is the safety check.
