<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Selection When Scrolled: fix tap-to-row mapping (design)

**Date:** 2026-07-22
**Status:** Approved (brainstorm complete); ready for implementation plan.

## Problem

When a terminal pane is scrolled into scrollback, double-tap word-select collapses to
zero width and triple-tap line-select copies the WRONG line. Confirmed on device 2026-07-22
(user copied a triple-tap selection and pasted the wrong text; device log showed a tap at
`point.y=5255`, `cellH=10`, grid `80x33` producing `row = min(32, Int(5255/10)) = 32`, i.e.
clamped to the last visible row regardless of where the finger actually landed).

## Root cause (derived from SwiftTerm source, pinned commit 58915b1)

`cell(at:)` in `App/TerminalGestureController.swift` computes:
```swift
let row = min(rows - 1, max(0, Int(point.y / cellH)))
```
where `point = gesture.location(in: view)`.

Two facts from SwiftTerm's own source settle the correct mapping:

1. `TerminalView.calculateTapHit(point:)` (iOS/iOSTerminalView.swift ~line 668) computes
   `row = Int(point.y / cellDimension.height)` on a point clamped to `bounds` (the VIEWPORT).
   SwiftTerm feeds this screen row directly into its own selection and `getCharData`.
2. `getCharData(row:)` -> `getLine(row:)` (Terminal.swift ~line 748) indexes
   `buffer.lines[row + buffer.yDisp]`: it adds `yDisp` ITSELF. So `getCharData` /
   `setSelectionRange` expect a SCREEN row (0..<rows), and the caller must NOT add `yDisp`.

The bug: `TerminalView` is a `UIScrollView`, so `gesture.location(in: view)` returns a point
in CONTENT space (it includes the scroll offset). When scrolled, `point.y` is huge (5255),
so `Int(point.y / cellH)` far exceeds `rows` and clamps to the last row. SwiftTerm's own
`calculateTapHit` never hits this because it operates in VIEWPORT space (point clamped to
`bounds.height`, a few hundred points).

CORRECTION to an earlier research note: the fix is NOT `bufferRow = yDisp + screenRow`. That
would add `yDisp` on top of the `yDisp` that `getLine` already adds (double-count), which is
exactly the "double/triple-tap selected a row far above the tap" bug a PRIOR fix chased and
"fixed" by removing all offset arithmetic. That prior removal was HALF right (correctly does
not add `yDisp`) and HALF wrong (also stopped subtracting `contentOffset`, which is what
actually converts content-space to viewport-space).

## The fix

Convert the gesture's content-space point to viewport space by subtracting the scroll
offset, then divide by the cell height (no `yDisp`):

```swift
let viewportY = point.y - view.contentOffset.y
let row = min(rows - 1, max(0, Int(viewportY / cellH)))
```

`col` is unchanged (`point.x`, horizontal, unaffected by vertical scroll). The resulting
`row` is a screen row in 0..<rows, exactly what `setSelectionRange` and `getCharData`
(via `getLine`, which adds `yDisp` internally) expect.

The stale comment in `cell(at:)` (currently: "SwiftTerm's own tap-hit maps this DIRECTLY ...
with NO contentOffset arithmetic ... Match SwiftTerm.") must be rewritten to state the real
rule: subtract `contentOffset.y` (content -> viewport), do NOT add `yDisp` (getLine adds it).
This prevents a third whipsaw.

## Testability

Extract the pure row-mapping into a Kit decider so the scrolled case is Linux-tested and
locked against regression:

```swift
// Sources/SemicolynKit/Terminal/TapRowMapping.swift
public struct TapRowMapping: Sendable {
    /// Screen row (0..<rows) for a tap, from a CONTENT-space y (a UIScrollView
    /// location(in:) value), the scroll offset, cell height, and row count. Subtracts the
    /// offset (content -> viewport); does NOT add yDisp (SwiftTerm's getLine adds it).
    public static func row(contentY: Double, contentOffsetY: Double,
                           cellHeight: Double, rows: Int) -> Int {
        guard cellHeight > 0, rows > 0 else { return 0 }
        let viewportY = contentY - contentOffsetY
        let r = Int(viewportY / cellHeight)
        return min(rows - 1, max(0, r))
    }
}
```

`cell(at:)` calls `TapRowMapping.row(contentY:contentOffsetY:cellHeight:rows:)` for the row.

Kit tests (EP + BVA), asserting exact returned rows:
- Unscrolled (offset 0): `contentY=105, cellH=10, rows=33` -> row 10 (baseline still correct).
- Scrolled: `contentY=5255, contentOffsetY=5000, cellH=10, rows=33` -> `Int(255/10)=25`
  (NOT clamped to 32: the fix). This test FAILS against the current omit-offset code
  (which yields 32), so it is a real regression guard.
- Boundary: viewportY at the last row and just past it clamps to `rows-1`.
- Boundary: viewportY negative (tap above content top after an over-scroll) clamps to 0.
- Degenerate: `cellHeight <= 0` or `rows <= 0` -> 0 (no crash).

## Scope

- ONE App-tier edit: `cell(at:)` row computation + its comment.
- ONE new Kit decider + tests.
- Does NOT touch `col`, selection APIs, `wordBounds` logic (it will now receive the correct
  row and expand correctly), or anything else.

## Decision log
- Fix = subtract `contentOffset.y` (content -> viewport), derived from SwiftTerm's
  `calculateTapHit` + `getLine` bodies. NOT `yDisp + screenRow` (double-count / whipsaw).
- Pure Kit decider (`TapRowMapping`) + a scrolled-offset test that fails pre-fix, to lock it.
- Rewrite the misleading `cell(at:)` comment to prevent whipsaw #3.
