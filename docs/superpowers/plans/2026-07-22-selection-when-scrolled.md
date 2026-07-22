<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Selection When Scrolled Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix double/triple-tap selection on a scrolled pane by converting the gesture's content-space y to viewport space (subtract `contentOffset.y`) before mapping to a row.

**Architecture:** Extract the pure row-mapping into a Kit decider `TapRowMapping` (Linux-tested, with a scrolled case that fails against the buggy code) and call it from `cell(at:)` in the App tier, replacing the offset-omitting formula and its misleading comment.

**Tech Stack:** Swift 6, SwiftTerm (pinned 58915b1), UIKit (App tier, macOS-CI + device), XCTest (Kit tier, Linux/Docker).

## Global Constraints

- SPDX header on every source file. No em-dashes anywhere. Conventional commits.
- `Sources/SemicolynKit/`: platform-agnostic, Linux-tested, no `import UIKit`/`SwiftUI` (use `import Foundation`, plain `Double`/`Int`, no `CGFloat`/`CGPoint`).
- `App/`: Apple-only, not Linux-buildable, macOS CI + device verified.
- Tests must be real: assert exact returned rows (no tautologies); include a case that FAILS against the current code.
- Kit tests via Docker: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`.

**Spec:** `docs/superpowers/specs/2026-07-22-selection-when-scrolled-design.md`.

**Root cause (verified from SwiftTerm source):** `gesture.location(in: view)` on the UIScrollView-based `TerminalView` returns CONTENT-space coords (includes scroll offset). SwiftTerm's `calculateTapHit` + `getCharData`/`setSelectionRange` expect VIEWPORT-space screen rows (`getLine` adds `yDisp` internally). Current `cell(at:)` omits the offset entirely, so a scrolled tap's huge `point.y` clamps to the last row. Fix: subtract `contentOffset.y`; do NOT add `yDisp`.

---

### Task 1: Pure TapRowMapping decider (Kit)

**Files:**
- Create: `Sources/SemicolynKit/Terminal/TapRowMapping.swift`
- Test: `Tests/SemicolynKitTests/TapRowMappingTests.swift`

**Interfaces:**
- Produces: `struct TapRowMapping { static func row(contentY: Double, contentOffsetY: Double, cellHeight: Double, rows: Int) -> Int }`.

- [ ] **Step 1: Write the failing test**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Tap-to-row must convert a CONTENT-space y (a scrolled UIScrollView location) to a
/// VIEWPORT screen row by subtracting the scroll offset. It must NOT add yDisp (SwiftTerm's
/// getLine adds that internally), and must clamp into 0..<rows.
final class TapRowMappingTests: XCTestCase {
    // EP: unscrolled (offset 0) still maps directly (baseline unchanged).
    func testUnscrolledMapsDirectly() {
        XCTAssertEqual(
            TapRowMapping.row(contentY: 105, contentOffsetY: 0, cellHeight: 10, rows: 33),
            10)
    }

    // EP + the fix: scrolled tap must subtract the offset, NOT clamp to the last row.
    // contentY 5255, offset 5000 -> viewportY 255 -> row 25 (the current buggy code yields 32).
    func testScrolledSubtractsOffset() {
        XCTAssertEqual(
            TapRowMapping.row(contentY: 5255, contentOffsetY: 5000, cellHeight: 10, rows: 33),
            25)
    }

    // BVA: viewportY exactly at the last row's top maps to rows-1.
    func testLastRowBoundary() {
        // rows=33 -> last row index 32; viewportY 320 -> Int(320/10)=32.
        XCTAssertEqual(
            TapRowMapping.row(contentY: 320, contentOffsetY: 0, cellHeight: 10, rows: 33),
            32)
    }

    // BVA: viewportY past the bottom clamps to rows-1 (not beyond).
    func testPastBottomClampsToLastRow() {
        XCTAssertEqual(
            TapRowMapping.row(contentY: 999, contentOffsetY: 0, cellHeight: 10, rows: 33),
            32)
    }

    // BVA: negative viewportY (tap above content top after over-scroll) clamps to 0.
    func testNegativeViewportClampsToZero() {
        XCTAssertEqual(
            TapRowMapping.row(contentY: 10, contentOffsetY: 50, cellHeight: 10, rows: 33),
            0)
    }

    // Degenerate: non-positive cellHeight or rows returns 0, no crash / no divide-by-zero.
    func testDegenerateInputsReturnZero() {
        XCTAssertEqual(TapRowMapping.row(contentY: 100, contentOffsetY: 0, cellHeight: 0, rows: 33), 0)
        XCTAssertEqual(TapRowMapping.row(contentY: 100, contentOffsetY: 0, cellHeight: 10, rows: 0), 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TapRowMappingTests`
Expected: FAIL (compile error: `TapRowMapping` not defined).

- [ ] **Step 3: Write the implementation**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Maps a tap to a terminal SCREEN row (0..<rows).
///
/// The gesture point comes from `UIGestureRecognizer.location(in: terminalView)`, and the
/// terminal view is a `UIScrollView`, so that point is in CONTENT space (it includes the
/// scroll offset). SwiftTerm's own hit-test (`calculateTapHit`) and its selection /
/// `getCharData` APIs operate in VIEWPORT space: a screen row in 0..<rows, from which
/// `getLine` adds `buffer.yDisp` itself. So the correct mapping subtracts the scroll offset
/// (content -> viewport) and does NOT add `yDisp` (adding it would double-count, the prior
/// "row far above the tap" bug).
public struct TapRowMapping: Sendable {
    public static func row(contentY: Double, contentOffsetY: Double,
                           cellHeight: Double, rows: Int) -> Int {
        guard cellHeight > 0, rows > 0 else { return 0 }
        let viewportY = contentY - contentOffsetY
        let r = Int(viewportY / cellHeight)
        return min(rows - 1, max(0, r))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TapRowMappingTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Terminal/TapRowMapping.swift Tests/SemicolynKitTests/TapRowMappingTests.swift
git commit -m "feat(selection): pure TapRowMapping decider (content-space y -> viewport screen row)"
```

---

### Task 2: Use TapRowMapping in cell(at:) + fix the comment (App)

**Files:**
- Modify: `App/TerminalGestureController.swift` (`cell(at:)`, lines ~287-304).

**Interfaces:**
- Consumes: `TapRowMapping.row(contentY:contentOffsetY:cellHeight:rows:)` (Task 1).

- [ ] **Step 1: Replace the row computation + comment**

In `cell(at:)`, replace the misleading comment (lines ~294-300) and the `row` line (~302). Keep `col` (line 301) unchanged. New body from `let col` onward:

```swift
        let col = min(cols - 1, max(0, Int(point.x / cellW)))
        // `point` is `gesture.location(in: view)`, and `view` is a UIScrollView, so `point`
        // is in CONTENT space (includes the scroll offset). SwiftTerm's own `calculateTapHit`
        // and its selection / `getCharData` APIs want a VIEWPORT screen row (0..<rows); its
        // `getLine` adds `buffer.yDisp` itself. So convert content -> viewport by subtracting
        // `contentOffset.y`, and do NOT add `yDisp` (adding it double-counts: the old
        // "double/triple-tap selected a row far above the tap once scrolled" bug). Vertical
        // scroll does not affect `col`, so `point.x` is used directly above.
        let row = TapRowMapping.row(contentY: Double(point.y),
                                    contentOffsetY: Double(view.contentOffset.y),
                                    cellHeight: Double(cellH), rows: rows)
        return (col, row)
```

- [ ] **Step 2: Self-review (App tier, no local compile)**

App tier is not Linux-buildable and there is no local Swift toolchain. Confirm by re-reading: `TapRowMapping` is in `SemicolynKit` (already `import SemicolynKit` at the top of the file); `cellH` is the local `view.bounds.height / CGFloat(rows)` computed earlier in `cell(at:)` (a cell height in points); `view.contentOffset.y` is the scroll offset. The `row` is now the corrected viewport screen row; `wordBounds` and `setSelectionRange` receive it unchanged and will now expand/select the correct row. macOS CI compile + device are the gates.

- [ ] **Step 3: Commit**

```bash
git add App/TerminalGestureController.swift
git commit -m "fix(selection): map scrolled taps via TapRowMapping (subtract contentOffset, not add yDisp)"
```

---

### Task 3: Kit suite green + push (macOS CI) + device-verify

**Files:** none (verification).

- [ ] **Step 1: Full Kit suite green**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS (baseline + the 6 new TapRowMapping tests).

- [ ] **Step 2: Push + confirm CI**

```bash
git push github feat/finger-drag-window-transition
```
Confirm `lint`/`linux-rust`/`linux-swift` + the `macos` compile job all green.

- [ ] **Step 3: Device-verify**

On a scrolled pane at a plain shell: double-tap a word -> it highlights the correct word (not zero-width); triple-tap a line -> selects that line; copy + paste -> the pasted text matches the tapped line (the original failure). Also confirm UNSCROLLED selection still works (baseline not regressed), and that cursor placement (single-tap in `.localScroll`) still lands on the correct cell when scrolled.

- [ ] **Step 4: Record outcome** in `TODO.md` + memory on PASS.

---

## Self-Review

**Spec coverage:** the fix formula (subtract `contentOffset.y`, not add `yDisp`) is in Task 1's decider + Task 2's call. The scrolled-fails-pre-fix guard is `testScrolledSubtractsOffset` (row 25 vs the buggy 32). The comment rewrite is Task 2 Step 1. Kit decider + tests: Task 1. All spec points covered.

**Placeholder scan:** none. App-tier step says explicitly it cannot compile locally (correct for the tier). Every code step shows full code.

**Type consistency:** `TapRowMapping.row(contentY:contentOffsetY:cellHeight:rows:) -> Int` defined in Task 1 and called with the identical signature in Task 2 (all `Double` except `rows: Int`, matching; App passes `Double(point.y)`, `Double(view.contentOffset.y)`, `Double(cellH)`, `rows`). No `CGFloat`/`CGPoint` crosses into Kit.
