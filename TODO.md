<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Status & TODO

## Current state (2026-08-07): clean stopping point

**PR [#121](https://github.com/ds7n/semicolyn/pull/121) MERGED to main (squash `5e33989`).** All four raw-terminal issues fixed and device-confirmed on TestFlight build 119:

- **Exit flash** - cleared `output.onExit` in `teardown()` + `SessionView` renders bare `Color.clear` on `.idle` (no NavigationStack chrome painting during teardown).
- **Tap latency** - dropped the `doubleTap.require(toFail: tripleTap)` stacked-window requirement; double-tap fires at native speed, a 3rd tap upgrades word->line.
- **Scroll dead** - `handlePan` was recognizing/owning every content drag; now `isEnabled=false` at rest, armed only while a selection is active. Native scroll pan owns the swipe (device proof: `scroll-trace pan=nativePan state=2 ty=-35..-151`).
- **Keybar hid rows** - `keyboardLayoutGuide` reported window-space `1001` vs the 499pt slot; now reject out-of-range guide top and prefer the measured keybar height (`accH`).

main @ `5e33989`, working tree clean of session changes.

## Next up (user-requested resume after context clear)

**Structural container-wrap of the raw terminal path** - the deeper fix behind the whole #121 arc. The raw `PaneTerminalView` (a UIScrollView) is mounted as the SwiftUI representable LEAF, so its geometry resolves against the ~1001pt window not its 499pt slot (the shared root cause of scroll + keybar). Wrap it in a plain-UIView container like `TmuxPaneContainer` so it stops being the leaf, removing the mismatch at its source and letting the #121 workarounds be simplified. Full plan + files in the auto-memory `raw-terminal-container-wrap-followup`.

Also queued (own slices): Batch 2 = wire ET -> tmux -CC native panes (roadmap headline); on-connect per-host autorun command (transport-agnostic).
