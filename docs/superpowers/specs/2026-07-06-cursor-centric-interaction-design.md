<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Cursor-Centric Interaction (replacing the cursor halo)

**Date:** 2026-07-06
**Status:** Design — awaiting user review
**Supersedes:** `docs/brainstorming-decisions.md` §"Cursor placement" (the always-on halo model). This design replaces that locked decision; the decision log should be updated to point here.

## Problem

The shipped cursor-placement feature draws an always-on ~60pt coral halo at the cursor (15% opacity, brightens on touch), and a drag *within the halo* synthesizes arrow keys to move the cursor. On-device this reads as awkward: a second bright object competes with the text cursor, its purpose/when-visible is unclear, and it has no coherent narrative. The halo exists to solve "touch is imprecise, how do you grab a 1-cell cursor" — but it solves it by adding a persistent visual with its own lifecycle rather than making the cursor itself the affordance.

## Narrative (the model)

**The cursor is the single affordance.** It marks where activity/typing happens, it can be moved, and it is the start anchor for text selection. There is no separate halo. Interaction follows the iOS-native text model, disambiguated by *hold*:

| Gesture | Result |
|---|---|
| **Tap** | Reposition the cursor. A tap on the cursor's current line moves horizontally (synthesize left/right arrows to that column) — reliable in shells/readline. A tap on a different line is best-effort (row delta then column delta). |
| **Quick drag** (finger moves before a hold registers) | Scrub the cursor with the finger — relative arrow synthesis. No selection. |
| **Hold, then drag** (~0.5s stationary, then move) | iOS-native text selection: loupe + drag handles + copy menu. The cursor is the selection's start anchor. |
| **Two-finger / gestures outside the cursor** | Scroll, window-switch, keybar — unchanged. |

**Why tap is same-line-reliable / cross-line best-effort:** a terminal over SSH has no absolute cursor addressing — the app can only send *arrow keys*. Same-line horizontal movement (`cols` delta → left/right arrows) is reliable. Cross-line movement (row delta → up/down arrows) can misfire on wrapped lines, multi-line prompts, or vim, because screen rows don't map cleanly to arrow presses. Cross-line taps are therefore best-effort and documented as such; the common, reliable case (fix a typo on the current command line) works precisely.

## Components

### Removed (halo machinery)
- `App/CursorHaloView.swift` — the always-on coral dot.
- `App/CursorDragController.swift` — the halo-gated pan + install/refresh/haptics.
- `Sources/SemicolynKit/Terminal/CursorHaloGeometry.swift` + `Tests/SemicolynKitTests/CursorHaloGeometryTests.swift` — halo placement math.
- Halo lifecycle wiring in `App/TmuxPaneContainer.swift` and `App/TerminalScreen.swift`: `installHalo`/`removeHalo`/`refreshCursorHalos`/`setCursorDragActive`, the `cursorHaloColor` property, and the per-pane `cursorDrags` dictionary.

### Kept & reused
- `Sources/SemicolynKit/Terminal/CursorDragEngine.swift` — finger-delta → arrow-count math (gain curve + 1.5-cell vertical dead-zone + sub-cell remainder). Exactly what quick-drag-scrub needs; survives unchanged, triggered by a plain pan instead of a halo-gated one. Its tests stay.
- `Sources/SemicolynKit/Terminal/CursorArrowStream.swift` — `arrowEvents(cols:rows:) -> [ArrowRun]` signed-delta → arrow-key runs. Reused by both tap and drag. Its tests stay.
- Long-press → SwiftTerm native selection (existing `selectionLongPress` `UILongPressGestureRecognizer` in both `TerminalScreen` and `TmuxPaneContainer`). Kept as-is.
- `Sources/SemicolynKit/Terminal/LoupeWindow.swift` — verify it is wired to the selection long-press; finish it if it was left a deferred slice. (Loupe is part of the native selection UX, not a new component.)

### Added
- **`Sources/SemicolynKit/Terminal/CursorTapTarget.swift`** (pure, Linux-tested):
  ```swift
  /// The arrow-key movement to walk the cursor from `current` to a tapped cell.
  /// Same row → pure horizontal (cols delta). Different row → best-effort
  /// (row delta as up/down, then col delta as left/right). Returns [] for no move.
  public func cursorTapArrows(fromCol: Int, fromRow: Int, toCol: Int, toRow: Int) -> [ArrowRun]
  ```
  Delegates the signed-delta → runs step to the existing `arrowEvents(cols:rows:)`.
- **App-tier gesture plumbing** (macOS-CI compile + device verified): a **tap** recognizer + a **plain pan** recognizer on the terminal view, replacing the halo-gated pan. Pixel→cell conversion uses the same measured cell metrics the halo used; current cursor cell reads `getTerminal().buffer.x/.y` (already used by the removed halo — confirmed public/working).

## Gesture arbitration

Three recognizers on the terminal `TerminalView`, resolved by priority:
1. **Long-press** (existing, ~0.5s stationary) → engages iOS selection + loupe.
2. **Pan** (new) → cursor scrub. `pan.require(toFail: longPress)` is NOT used directly; instead the natural UIKit behavior applies: the long-press cancels itself once the finger moves past its slop threshold *before* the delay fires, so early movement → pan wins (scrub); staying still past ~0.5s → long-press wins (select). If field testing shows races, add explicit `require(toFail:)`/`shouldRecognizeSimultaneously` arbitration.
3. **Tap** (new) → reposition; naturally fails if the touch becomes a pan or long-press.

Net rule: **move fast → scrub; hold still → select; tap → place.**

**Mouse-mode coexistence:** in a `mouse=a` pane, taps/drags forward as SGR mouse events and these gestures suspend for that pane only — identical to how the halo suspended (per `docs/brainstorming-decisions.md` §"Mouse mode", which stays valid).

## Testing

- **Kit (Linux, TDD):**
  - `CursorTapTarget`: same-row → exact left/right `ArrowRun` (BVA: col 0, last col, zero delta → `[]`); different-row → up/down then left/right runs; same cell → `[]`.
  - `CursorDragEngine` + `CursorArrowStream`: existing tests retained (drag math unchanged).
  - Delete `CursorHaloGeometryTests` with the geometry it covered.
- **App (macOS-CI compile + on-device feel-pass):** gesture arbitration is interaction and is verified on device — tap places on the current line; quick-drag scrubs; hold-then-drag selects with loupe; two-finger scroll and keybar unaffected; mouse-mode pane suspends the gestures. The *arrow-count math* underneath is all Kit-tested, so device verification confirms **routing/feel**, not numeric correctness.

## Out of scope / accepted limitations

- **Cross-line tap precision:** best-effort only (see Narrative). Accepted; the reliable case is same-line editing.
- **Absolute cursor addressing:** impossible over SSH; not attempted.
- The removed halo's "offscreen `⌖` indicator" and haptics are dropped with it (they were halo-specific).
