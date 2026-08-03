<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Selection UI (Slice 2) implementation design

**Status:** DESIGN (2026-08-01). Implementation design for **Slice 2** of the
gesture-diagnostics -> selection build order in
`docs/superpowers/specs/2026-07-30-gesture-interaction-system-design.md`
(Topic 3, "Text selection, copy, paste", LOCKED). This document does NOT
re-open any locked UX decision; it specifies HOW to build the locked Topic 3
selection UI, grounded in verified SwiftTerm v1.15.0 source.

## Scope (from Topic 3, full slice)

In build-order (each device-verified before the next; all ship together as
"selection done"):

1. **Highlight fix (3g)**, make the selection highlight actually draw, including
   on the alt-screen / when scrolled.
2. **Sub-word double-tap + selection semantics (3a/3d)**, double-tap breaks on
   punctuation; selecting FOCUSES the pane; paste is bracketed at the cursor of
   the focused pane.
3. **Draggable endpoint handles (3b)**, pan over SwiftTerm's drawn handle zones
   grows/shrinks the selection; opposite end anchored.
4. **Custom magnifier loupe (3h)**, floating circular magnifier while dragging a
   handle / long-press-drag, snapshotting the region under the finger.

Out of scope (deferred per Topic 3): multi-page selection that grows across
scroll; tmux copy-mode / server-side scrollback selection.

## Root cause of the invisible highlight (VERIFIED, not guessed)

Verified against **real SwiftTerm v1.15.0** (freshly cloned; the repo's
`swiftterm-150/` clone is mis-tagged 1.5.0 and is the WRONG version, SPM
`from: "1.0.0"` resolves 1.15.0 > 1.5.0).

Three consumers read a terminal `Position.row`, in **two different row spaces**:

| Consumer | Path (v1.15.0) | Row space wanted |
|---|---|---|
| Selection **highlight draw** | `AppleTerminalView.selectedColumnsRange`: `selection.start.row == row`, where `row` is the iOS draw-loop **content** row (`Int(contentOffset.y/cellHeight)+offset`) | **Absolute** buffer/content row |
| Selection **copy text** | `getSelectedText -> getDisplayText -> getText(buffer:) -> _getSelectedLines -> buffer.lines[start.row]` | **Absolute** buffer/content row |
| **Word-boundary scan** (double-tap reads cells) | `getCharData -> getLine -> buffer.lines[row + buffer.yDisp]` | **Viewport** row (0..<rows) |

Today `cell(at:)` (`TerminalGestureController.swift`) produces a single
**viewport** row (via `TapRowMapping`, which subtracts `contentOffset.y` and does
NOT add yDisp). That is correct for `getCharData`, but WRONG for
`setSelectionRange`: on the alt-screen or any scrolled state the content-space
top row is non-zero, so the stored viewport row never matches the draw loop's
absolute `row` -> `selectedColumnsRange` returns nil for every visible row -> no
highlight fill drawn. `selection.active` stays true and the edit menu appears,
which is why the bug looked like "selects + copies but no highlight."

**Correction to the earlier note:** the copy path does NOT add yDisp
internally; `_getSelectedLines` indexes `buffer.lines[row]` absolutely, same as
the draw loop. Both selection paths want the absolute row; only `getCharData`
wants viewport. `setSelectionRange`'s own doc-comment (meshTerm fork,
`iOSTerminalView.swift:1371`) says coordinates are "buffer-relative Position
values", i.e. absolute, confirming the contract.

**`buffer.yDisp` is not public in v1.15.0.** We therefore derive the absolute row
from the same value the iOS draw loop uses: `topContentRow = Int(contentOffset.y
/ cellHeight)`. This keeps the stored selection in the draw loop's exact space
without depending on an unexposed field.

## The fix (row math)

New Kit function (pure, Linux-tested), single source of truth for the two row
spaces:

```
// SemicolynKit/Terminal/TapRowMapping.swift (extend the existing type)
// Absolute content/buffer row for a tap, = viewport row + the content row of the
// top of the viewport. Used for setSelectionRange (highlight + copy).
static func absoluteRow(contentY: Double, cellHeight: Double,
                        totalRows: Int) -> Int
```

- `viewportRow` (existing `TapRowMapping.row`, unchanged), feeds `getCharData` /
  `wordBounds` / mouse-report coordinates.
- `absoluteRow = Int(contentY / cellHeight)` clamped to `0..<totalRows` (of the
  content, i.e. `Int(contentSize.height / cellHeight)`), feeds
  `setSelectionRange`. Because `contentY = point.y` is already in content space,
  the absolute content row is just `contentY / cellHeight`; no separate
  `contentOffset` term is needed (the viewport mapping subtracts the offset,
  the absolute mapping does not).

`cell(at:)` returns BOTH rows (or a small struct). Double/triple-tap:
- `wordBounds` uses `viewportRow` (unchanged, correct).
- `setSelectionRange` uses `absoluteRow` for `start.row` and `end.row`.

The guessed `setNeedsDisplay(view.bounds)` (commit 64dc281) is REMOVED: it was a
guess and is not the fix. If a genuine repaint-coalescing race is later observed
on device, it is handled separately, not by a blanket forced redraw.

The `.selection` diagnostics instrumentation (SelectionDiagnostics.snapshot,
set/redraw/repaint phase logs) added in Slice 1 is REMOVED once the fix is
device-verified (it was scaffolding to find the cause). `InputClickFeedback.
diagnosticsEnabled` is flipped back to false before any main-merge (carry-forward
from Slice 1).

## Sub-word double-tap (3a)

Today `wordBounds` (Kit) walks over any non-whitespace, so it grabs a whole token
(`.claude-staging-oauth.json`). iOS/desktop double-click stops at a **character
class change**. Generalize the predicate from binary to class-based:

```
// SemicolynKit/Terminal/WordBounds.swift
enum CharClass { case word    // alnum + a small "identifier" set
                 case space   // space/tab/nul
                 case punct }  // . - / _ , : and similar separators

// New sub-word walker: from the tapped column, extend left/right while the
// class STAYS EQUAL to the tapped cell's class. A tap on `staging` selects
// `staging`; a tap on `-` selects the run of punctuation.
func subWordBounds(cols: Int, col: Int,
                   classOf: (Int) -> CharClass) -> (start: Int, end: Int)
```

Boundary punctuation set (locked in Topic 3): `. - / _ , :` plus similar
separators; exact set is defined in one Kit constant so it is testable and
tunable in one place. The App supplies `classOf` backed by `getCharData` on the
**viewport** row (unchanged text-read path). Triple-tap (line) is unchanged
(cols 0..<cols on the row). The existing `wordBounds` may be kept for any
whole-token caller or removed if unused; `subWordBounds` is the double-tap path.

## Focus-on-select + bracketed paste (3a/3d)

- **Selecting focuses the pane** (Topic 1 optimistic-local-then-reconcile). On
  double/triple-tap/long-press-drag start, invoke the existing focus path
  (the same `select-pane` optimistic-focus used by tap-to-focus, PR #112) for
  the pane the selection is in, BEFORE presenting the menu. This is the
  by-construction fix for paste-to-wrong-pane.
- **Paste = bracketed, at the cursor of the focused pane.** The edit menu's
  Paste action writes clipboard text wrapped in bracketed-paste markers
  (`ESC[200~` ... `ESC[201~`) to the focused pane when the app has bracketed
  paste enabled; falls back to raw bytes when it is not. Routing to the focused
  pane reuses Topic 1's focus, so paste lands where you are working.

## Draggable endpoint handles (3b)

SwiftTerm draws the highlight fill AND a 12pt handle ellipse at each end inside
its own `drawRect` when `selection.active` (`AppleTerminalView`:
`selectedTextBackgroundColor` fill; `drawSelectionHandle`), independent of
`editingInteractionConfiguration = .none`. So once the row math is correct, the
handles are DRAWN for free; we only need to make them draggable.

`SelectionService` is `internal` on the iOS view, so we cannot call
`selection.dragExtend` from the App. `setSelectionRange(start:end:)` IS public and
performs a full re-set, that is our extend primitive:

- A pan recognizer (App-owned, added to the terminal view) hit-tests its start
  point against the two handle zones (each end's cell rect, in content space, +
  a touch-slop pad). If it starts on a handle, it OWNS the drag (mutually
  exclusive with scroll/switch/selection-drag pans, same subordination machinery
  already in `TerminalGestureController`).
- During the drag, the moving end = the cell under the finger (`cell(at:)`,
  absolute row for the stored Position); the opposite end stays anchored at its
  current stored Position. Call `setSelectionRange(start:end:)` with the
  ordered pair each move. Ordering (start-before-end) is normalized in the Kit
  so a handle dragged past the other end flips correctly.
- Snapping to real cells is inherent (we work in grid Positions, not pixels),
  satisfying the "grid-aware, native can't" rationale in 3f-RESULT.

Handle hit-testing (which end, given a point + the two endpoint cell rects +
slop) is a **pure Kit function** with a test; the App supplies the rects.

## Custom magnifier loupe (3h)

A floating circular magnifier, shown while dragging a handle or during
long-press-drag, hidden on release. It is the one genuinely-custom piece (native
loupe comes from `UITextInteraction`, which `.none` disables; SwiftTerm has zero
loupe/magnifier code).

- **View:** a `UIView` overlay (circle, glass ring/shadow) added above the
  terminal view, positioned above the finger. Content = a scaled snapshot of the
  screen region centered on the contact point.
- **Snapshot source:** render the terminal view's layer region under the finger
  into an image (or use `resizableSnapshotView`/`drawViewHierarchyInRect` on the
  region), scaled ~1.25-1.5x. It magnifies the (now-correctly-drawn) highlight.
- **Perf:** must not choke on the tmux `-CC` repaint stream. Snapshot on a
  throttle (coalesce to the display link / a min interval), NOT every touch-move
  frame. Reuse one snapshot between repaints; only re-snapshot when the region
  or the underlying frame changed past the throttle window.
- The loupe tracks the finger x within the row and clamps to the pane bounds so
  it never leaves the visible area.

Loupe geometry (where the loupe center sits given the finger point + pane bounds,
clamped) is a **pure Kit function** with a test; the floating view + snapshot are
App/UIKit.

## Components & boundaries

| Unit | Tier | Responsibility | Tested |
|---|---|---|---|
| `TapRowMapping.absoluteRow` | Kit | content-space absolute row for selection | XCTest (BVA on yDisp/offset) |
| `subWordBounds` + `CharClass` | Kit | class-based sub-word boundary | XCTest (EP over word/space/punct + boundaries) |
| selection-range ordering / normalize | Kit | order (start,end) so a flipped handle drag is correct | XCTest |
| handle hit-test (point -> which end) | Kit | pick dragged handle from endpoint rects + slop | XCTest |
| loupe geometry (center, clamped) | Kit | loupe position from finger + bounds | XCTest |
| `TerminalGestureController` selection edits | App | wire the above to `setSelectionRange`, focus, menu, handle-pan, loupe view | macOS CI + device |
| loupe overlay view + snapshot | App | floating magnifier UIView, throttled snapshot | device |

Everything decision-shaped is a pure Kit function (mirrors the
`tmuxLaunchDecision`-pure pattern the repo uses); the App tier stays a thin
wiring layer, validated on macOS CI + device.

## Error handling / edge cases

- Empty / degenerate selection (tap on whitespace) -> no menu, no handles
  (existing degenerate `(col,col)` from `wordBounds`; carry into `subWordBounds`).
- Selection while scrolled up in normal-screen scrollback: `absoluteRow` uses
  content-space `point.y` directly, so it is correct for any scroll offset
  (this is the Topic 3e "one screenful incl. after scrolling" scope; multi-page
  grow is deferred).
- Alt-screen (`.appOwnsInput`): selection + handles + loupe must NOT hijack the
  content-drag (scroll->arrows). The handle-pan only engages when it STARTS on a
  handle zone; a content-drag elsewhere stays with the existing scroll/arrows
  owner (Topic 4/8 precedence, already built).
- Handle dragged past the opposite end -> Kit ordering normalizes; selection
  stays valid, never inverts visually.
- Loupe on the tmux `-CC` repaint stream -> throttled snapshot; never a
  per-frame snapshot (perf failure = the guiding-principle-3 "snappy" gate).

## Testing (real tests, per repo standard)

- `TapRowMapping.absoluteRow`: BVA, offset 0 (normal, top), offset > 0
  (scrolled), alt-screen-like large offset; assert exact expected absolute row;
  a negative/degenerate `cellHeight<=0 -> 0`.
- `subWordBounds`: EP over the three classes + boundaries, tap in `staging`
  yields `staging` (NOT the whole `.claude-staging-oauth.json`); tap on `-`
  yields the punct run; tap on a space yields degenerate; first/last column
  boundaries; assert exact `(start,end)`.
- selection ordering: start-after-end input normalizes to ordered output
  (exact positions).
- handle hit-test: point on start handle -> `.start`; on end handle -> `.end`;
  between/outside -> `nil`; slop boundary (just inside / just outside).
- loupe geometry: center above finger, clamped at each pane edge (exact CGPoint).

No tautologies; every negative test asserts the specific expected value/variant.

## Build & verify order

1. Row-math fix + Kit tests -> **device-verify highlight draws on alt-screen**
   (the whole point; do not proceed until seen).
2. Sub-word + focus-on-select + bracketed paste + Kit tests -> device-verify
   sub-word break + paste-to-focused-pane.
3. Draggable handles + Kit hit-test -> device-verify grab/grow/shrink.
4. Custom loupe + Kit geometry -> device-verify magnifier tracks + no repaint
   choke.
Each step: Kit green locally, macOS CI green, then a TestFlight device build.
Remove Slice-1 `.selection` diagnostics + flip `InputClickFeedback.
diagnosticsEnabled` false before the main-merge.

## Reconciliation

- Supersedes PR #113's guessed `setNeedsDisplay` highlight fix, whole-token
  `wordBounds`, and no-focus-on-select. Do not merge #113 as-is; these are its
  corrected re-implementations.
- Consistent with PR #112 tap-to-focus (Topic 1/2), reuses its optimistic-focus
  path for focus-on-select.
