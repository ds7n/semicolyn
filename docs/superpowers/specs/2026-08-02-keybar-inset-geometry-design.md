<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Keybar-inset terminal geometry (systematic fix)

**Status:** DESIGN (2026-08-02). Fixes a recurring `-CC` layout bug: the bottom
rows of the terminal (the Claude Code / vim prompt + status lines) render BEHIND
the floating keybar and are unreachable on the alt-screen. Supersedes the
2026-07-27 "full-height pane" decision (which fixed the keybar GAP by hiding the
bottom rows) recorded in `TmuxPaneContainer.swift` comments and in
`docs/superpowers/topics/resume-ci-tf-watch-2026-07-25.md` /
`session-resume-2026-07-19-logging-swipe-diag.md`.

## The problem

The keybar is a floating `inputAccessoryView` (its own UIKit window, over the
bottom of the screen), NOT a view in the pane container's layout. Its height is
DYNAMIC (`firstResponderKeybarHeight()` = `KeybarInputAccessory.
intrinsicContentSize.height`, ~56pt = 18 predictor strip + 38 bar; 0 when the
keyboard is down). Because it is not in the container's layout, the container's
`bounds` INCLUDES the band the keybar floats over.

SwiftTerm's iOS view derives its grid ENTIRELY from its frame:
`processSizeChange` computes `newRows = Int(frame.height / cellDimension.height)`
(verified in SwiftTerm v1.15.0 `AppleTerminalView.swift:225`). There is NO inset
input: `contentInset` does not change the row count. So the ONLY way to make the
terminal render fewer rows (fitting above the keybar) is to shorten the pane's
FRAME height.

## Why it keeps recurring: the two horns

| Attempt | Grid + pane height | Result |
|---|---|---|
| Subtract kbH (pre 2026-07-27) | `bounds.height - kbH` | Pane shorter than container -> container background shows in the reserved band, and the floating keybar (its own window) did NOT reliably cover it -> **dead black GAP** |
| Full height (current, 2026-07-27) | `bounds.height` | Pane fills container, grid = full rows -> SwiftTerm renders all rows into the full frame; the bottom ~kbH/cellH rows draw BEHIND the floating keybar. On normal-screen you could scroll them up; on ALT-SCREEN (Claude Code / vim) content is PINNED to the grid and cannot scroll -> **bottom rows HIDDEN** |

The current code is `TmuxPaneContainer.swift`: grid from `usableH = Double(bounds.
height)` (line ~715, full) and panes from `fitPaneRects(toHeight: Double(bounds.
height))` (line ~842, full). The `contentInset.bottom` the comments claim handles
it is ZERO on device (`geo:pane ... inset=(t0,b0)`) and could not work on
alt-screen anyway (no scroll).

## Root cause (systematic)

The gap and the hidden-rows are the SAME underlying fault seen from two sides:
**the terminal's rendered grid height and the visible (above-keybar) height were
never made consistent with each other AND with the keybar's live height.** The
gap happened when the pane was shortened but not aligned to the keybar; the
hidden rows happen when the pane is full-height so the grid overshoots the
visible area.

## The fix: one live-kbH inset, applied consistently

**Model (user-chosen): the container excludes the keybar.** The terminal's usable
region is `bounds.height - kbH`, and BOTH the tmux grid rows AND the pane frames
derive from that SAME value on EVERY layout pass:

1. **Grid:** `terminalGrid(height: bounds.height - kbH, ...)` (was full `bounds.
   height`). tmux / Claude Code is told the shorter row count, so its content is
   pinned to a grid that fits above the keybar. Fixes alt-screen by construction
   (no scrolling needed).
2. **Pane frames:** `fitPaneRects(toHeight: bounds.height - kbH)` (was full
   `bounds.height`). Each pane's frame bottom sits at `bounds.height - kbH` =
   exactly the keybar's top edge. SwiftTerm then computes `frame.height /
   cellHeight` = the same shorter row count -> self-consistent with the grid we
   reported.
3. **No dead gap this time:** the previous gap was an INCONSISTENCY (pane
   shortened, grid not; or a stale kbH). Here both use the SAME live `kbH` read
   on the same pass, and the region below the pane (`[bounds.height - kbH,
   bounds.height]`) is EXACTLY where the floating keybar renders. Pane bottom ==
   keybar top by construction, so there is no uncovered band. When `kbH == 0`
   (keyboard down, no accessory), usable == full height = today's correct
   keyboard-down layout.

`kbH` is the LIVE dynamic height (predictor strip on/off, layout changes, bar
size), never a static constant, satisfying the "must track the actual keybar
height" requirement. The existing render-storm early-out already keys on `kbH`
(`LayoutInputs.keybarH`), so a keybar-height change re-runs the layout; no new
invalidation path is needed.

## Self-verifying diagnostic (added in the SAME build as the fix)

The current `geo:pane` log records the accessory HEIGHT (`accH`, `accFrameH`) but
NOT its on-screen Y position, so alignment (pane-bottom vs keybar-top) cannot be
read from logs. The current hidden-rows bug WAS diagnosable from existing logs
(pane fills container, accH=56, inset.bottom=0), but VERIFYING the fix's
alignment needs one more field. Add to `geo:pane` (`PaneTerminalView.swift`) and
to the container's `geo:layout`:

- **`paneBottomY`**: the pane frame's bottom edge in the container's coordinate
  space (`frame.maxY`).
- **`kbTopY`**: the keybar accessory's top edge (`inputAccessoryView.frame.minY`)
  CONVERTED into the same coordinate space as `paneBottomY` (via
  `superview.convert` / window coordinates), so the two numbers are directly
  comparable. (The raw path already logs `accFrame=...@y`; this brings the -CC
  `geo:pane` to parity.)
- **`gap = kbTopY - paneBottomY`**: signed. `gap == 0` = perfect (fix correct);
  `gap > 0` = dead band re-appeared (regression toward the old gap); `gap < 0` =
  pane still overlaps behind the keybar (bottom rows still hidden). One number
  tells which failure mode, if any, on the first device build.

This closes the exact logging gap the user flagged: the fix ships with the
measurement that proves it, so a device screenshot is corroborated by an
objective `gap` value, not inferred.

## Components & boundaries

| Unit | Tier | Change | Verified |
|---|---|---|---|
| `TmuxPaneContainer.ContainerView.layoutSubviews` | App | grid `usableH = bounds.height - kbH` (was full) | macOS CI + device |
| `TmuxPaneContainer.fittedPaneRects` | App | fit `toHeight: bounds.height - kbH` (was full) | macOS CI + device |
| `geo:pane` / `geo:layout` logging | App | add `paneBottomY`, `kbTopY`, `gap` | device (the verification) |
| grid-from-usable-height math (if any pure part) | Kit | if the height->rows reduction has a pure helper, unit-test the `bounds - kbH` reduction incl kbH==0 and kbH>bounds edge | Kit XCTest |

The row/height arithmetic that is pure (e.g. "usable height given bounds and
kbH", clamped so `kbH >= bounds.height` cannot yield <=0 rows) SHOULD be a small
Kit function with EP/BVA tests (kbH=0 -> full; kbH<bounds -> reduced; kbH>=bounds
-> min 1 row, never negative). The UIKit frame placement stays in the App tier.

## Edge cases

- **Keyboard down (`kbH <= 0`)**: usable == full `bounds.height`. Identical to
  today's correct keyboard-down layout. The `firstResponderKeybarHeight()` returns
  -1 when no pane is first responder; treat `<= 0` as 0 (no inset).
- **kbH >= bounds.height** (degenerate tiny pane): clamp usable height so the grid
  is at least 1 row (never 0 / negative). Pure Kit-tested.
- **Split panes**: `fitPaneRects` already fits the whole layout to the container;
  reducing the container's usable height by kbH shrinks all panes proportionally,
  and only the BOTTOM-edge panes touch the keybar. Correct by construction (the
  inset is on the container, not per-pane).
- **Keybar height change mid-session** (predictor strip appears/disappears): the
  early-out's `LayoutInputs.keybarH` differs -> layout re-runs with the new kbH ->
  grid + frames re-derived. Already handled.
- **Window switch / rotation**: bounds change -> early-out miss -> re-run. Already
  handled.

## Testing

- Kit: the pure `usableHeight(bounds:keybar:)` (or equivalent rows reduction):
  EP (kbH=0 full; 0<kbH<bounds reduced) + BVA (kbH==bounds -> min 1 row; kbH>bounds
  -> min 1 row, not negative; kbH<0 treated as 0). Exact expected values.
- App: macOS CI compile. Device: the `gap` field == 0 on a Claude Code pane, AND
  the bottom rows (prompt + status + tmux bar) are visible above the keybar, AND
  no dead band appears (matching the Blink reference). Verify keyboard-down still
  fills full height, and a split still tiles without a gap.

## Build & verify order

1. Add the `paneBottomY` / `kbTopY` / `gap` fields to `geo:pane` + `geo:layout`
   (diagnostic first, so the fix is measurable).
2. Extract the pure usable-height/rows reduction to Kit + tests.
3. Apply the inset consistently (grid + pane frames from `bounds - kbH`) in
   `TmuxPaneContainer`.
4. macOS CI green -> TestFlight -> device: confirm `gap == 0`, bottom rows
   visible, no band, keyboard-down + split still correct.

## Reconciliation

- Supersedes the 2026-07-27 "full-height, keybar floats over bottom" decision.
  The keybar STILL floats (it is an inputAccessoryView), but the pane no longer
  extends behind it: the pane bottom is pinned to the keybar top via the live-kbH
  inset, so nothing renders behind the keybar.
- Keeps all the render-storm early-out and cell-metric machinery unchanged.
- Independent of the selection-UI slice (that slice is device-confirmed and can
  squash-merge separately).
