# Cursor-Centric Interaction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the always-on cursor halo with the iOS-native model — tap = reposition, quick-drag = scrub, hold-then-drag = native selection — removing the halo machinery and adding a pure `CursorTapTarget` seam plus tap/pan gesture recognizers.

**Architecture:** Delete the halo (`CursorHaloView`, `CursorDragController`, `CursorHaloGeometry` + tests, and their wiring in `TerminalScreen`/`TmuxPaneContainer`). Add a pure Kit `CursorTapTarget` (tap cell → arrow runs, delegating to the existing `arrowEvents`). Add tap + plain-pan recognizers on the terminal view that reuse the existing `CursorDragEngine`/`CursorArrowStream` math (unchanged) and `encodeKey` emission. Long-press → SwiftTerm native selection is kept as-is.

**Tech Stack:** Swift 6 SemicolynKit (Linux-tested), XCTest via `semicolyn-dev` Docker; App tier is SwiftUI + UIKit gesture recognizers + SwiftTerm, macOS-CI + device verified.

## Global Constraints

- SPDX header on every source file: `// SPDX-FileCopyrightText: 2026 True Positive LLC` + `// SPDX-License-Identifier: GPL-3.0-only`.
- Kit code: no `import UIKit`/`SwiftUI`; public types `Sendable`; typed args/returns.
- Reuse (do NOT rewrite) `arrowEvents(cols:rows:) -> [ArrowRun]` (`CursorArrowStream.swift`) and `CursorDragEngine` (`step(fingerDelta:speed:cellW:cellH:at:)`). Their tests stay.
- `ArrowRun` = `{ direction: ArrowDirection, count: Int }`.
- Gesture rule (spec): **move fast → scrub; hold still → select; tap → place.** Same-line tap is reliable (horizontal arrows); cross-line is best-effort (row delta then col delta).
- Mouse-mode (`mouse=a`) panes suspend these gestures for that pane only (same as the halo did).
- App tier (`TerminalScreen.swift`, `TmuxPaneContainer.swift`, gesture files) does NOT build on Linux — macOS CI + device is the signal. Do NOT `swift test` App changes.
- Kit tests: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <Name>` (docker socket sandbox-blocked → `dangerouslyDisableSandbox: true`).
- Conventional commits; branch `feat/cursor-centric-interaction-impl` (create at start); squash-merge to `main`.

---

### Task 1: `CursorTapTarget` Kit seam (pure, Linux-tested)

**Files:**
- Create: `Sources/SemicolynKit/Terminal/CursorTapTarget.swift`
- Test: `Tests/SemicolynKitTests/CursorTapTargetTests.swift`

**Interfaces:**
- Consumes: `arrowEvents(cols:rows:) -> [ArrowRun]`, `ArrowRun`, `ArrowDirection` (existing in `CursorArrowStream.swift`).
- Produces: `func cursorTapArrows(fromCol: Int, fromRow: Int, toCol: Int, toRow: Int) -> [ArrowRun]`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/SemicolynKitTests/CursorTapTargetTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class CursorTapTargetTests: XCTestCase {
    // Same row, tap to the right → that many Right runs.
    func testSameRowRightMovesRight() {
        XCTAssertEqual(cursorTapArrows(fromCol: 2, fromRow: 5, toCol: 6, toRow: 5),
                       [ArrowRun(direction: .right, count: 4)])
    }
    // Same row, tap to the left → Left runs.
    func testSameRowLeftMovesLeft() {
        XCTAssertEqual(cursorTapArrows(fromCol: 8, fromRow: 5, toCol: 3, toRow: 5),
                       [ArrowRun(direction: .left, count: 5)])
    }
    // Same cell → no movement.
    func testSameCellIsEmpty() {
        XCTAssertEqual(cursorTapArrows(fromCol: 4, fromRow: 5, toCol: 4, toRow: 5), [])
    }
    // Boundary: col 0.
    func testToColZero() {
        XCTAssertEqual(cursorTapArrows(fromCol: 3, fromRow: 0, toCol: 0, toRow: 0),
                       [ArrowRun(direction: .left, count: 3)])
    }
    // Different row, best-effort: row delta (down) THEN col delta (right).
    func testDifferentRowEmitsRowThenCol() {
        XCTAssertEqual(cursorTapArrows(fromCol: 1, fromRow: 2, toCol: 4, toRow: 5),
                       [ArrowRun(direction: .down, count: 3), ArrowRun(direction: .right, count: 3)])
    }
    // Different row upward, no column change → only up runs.
    func testDifferentRowUpOnly() {
        XCTAssertEqual(cursorTapArrows(fromCol: 4, fromRow: 9, toCol: 4, toRow: 6),
                       [ArrowRun(direction: .up, count: 3)])
    }
}
```

Note: confirm `ArrowRun`'s memberwise init is `ArrowRun(direction:count:)` and `ArrowDirection` has `.left/.right/.up/.down` by reading `CursorArrowStream.swift` first. Match its exact case names.

- [ ] **Step 2: Run tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter CursorTapTargetTests` (`dangerouslyDisableSandbox: true`)
Expected: FAIL — `cannot find 'cursorTapArrows' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/SemicolynKit/Terminal/CursorTapTarget.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// The arrow-key movement to walk the terminal cursor from its current cell to a
/// tapped cell. Same row → pure horizontal (col delta as left/right). Different row
/// → best-effort: the row delta as up/down runs, THEN the col delta as left/right
/// runs (cross-line taps can misfire on wrapped lines / multi-line prompts / vim —
/// documented as best-effort; the reliable case is same-line editing). Returns `[]`
/// when the tap lands on the current cell. Delegates the signed-delta → runs step to
/// the existing `arrowEvents(cols:rows:)` so tap and drag share one arrow encoder.
public func cursorTapArrows(fromCol: Int, fromRow: Int, toCol: Int, toRow: Int) -> [ArrowRun] {
    let colDelta = toCol - fromCol
    let rowDelta = toRow - fromRow
    if rowDelta == 0 {
        return arrowEvents(cols: colDelta, rows: 0)
    }
    // Row first, then column (best-effort cross-line).
    return arrowEvents(cols: 0, rows: rowDelta) + arrowEvents(cols: colDelta, rows: 0)
}
```

Note: verify `arrowEvents`' sign convention (does positive `cols` → `.right`? positive `rows` → `.down`?) by reading `CursorArrowStream.swift`. If its convention is inverted, negate accordingly so the tests pass — the tests encode the REQUIRED behavior (tap right → Right), so make the impl match them.

- [ ] **Step 4: Run tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter CursorTapTargetTests` (`dangerouslyDisableSandbox: true`)
Expected: PASS — 6 tests.

- [ ] **Step 5: Full Kit suite**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test` (`dangerouslyDisableSandbox: true`)
Expected: PASS — all green.

- [ ] **Step 6: Commit**

```bash
git add Sources/SemicolynKit/Terminal/CursorTapTarget.swift Tests/SemicolynKitTests/CursorTapTargetTests.swift
git commit -m "feat(cursor): CursorTapTarget — tap cell → arrow runs (Kit seam)

Same-row tap = horizontal arrows (reliable); different-row = best-effort row
then col. Delegates to the existing arrowEvents so tap and drag share one arrow
encoder. Pure, Linux-tested (part of the cursor-centric redesign)."
```

---

### Task 2: Remove the halo Kit geometry + its tests

**Files:**
- Delete: `Sources/SemicolynKit/Terminal/CursorHaloGeometry.swift`
- Delete: `Tests/SemicolynKitTests/CursorHaloGeometryTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing. Removes `cursorHaloPlacement(...)` and `CursorHaloGeometry` symbols.

**Note:** Task 3/4 remove the App-side callers of `cursorHaloPlacement`. Do this Kit deletion first so the full Kit suite still builds (the App isn't Linux-built, so a lingering App caller won't break `swift test`). Confirm no OTHER Kit file references the deleted symbols before deleting.

- [ ] **Step 1: Confirm no remaining Kit references**

Run: `grep -rn "cursorHaloPlacement\|CursorHaloGeometry" Sources/ Tests/`
Expected: matches ONLY in `CursorHaloGeometry.swift` + `CursorHaloGeometryTests.swift` (the files being deleted). If any OTHER Kit file references them, STOP and report — the plan assumed the halo geometry is App-only-consumed.

- [ ] **Step 2: Delete the two files**

```bash
git rm Sources/SemicolynKit/Terminal/CursorHaloGeometry.swift Tests/SemicolynKitTests/CursorHaloGeometryTests.swift
```

- [ ] **Step 3: Full Kit suite still green**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test` (`dangerouslyDisableSandbox: true`)
Expected: PASS — the deleted tests are gone; nothing else references the geometry.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor(cursor): remove CursorHaloGeometry + tests (halo machinery)"
```

---

### Task 3: Rewrite `CursorDragController` as a halo-free tap+pan gesture controller

**Files:**
- Rewrite: `App/CursorDragController.swift` (→ tap + plain-pan, no halo; keep the drag-scrub math)
- Delete: `App/CursorHaloView.swift`

**Interfaces:**
- Consumes: `cursorTapArrows(fromCol:fromRow:toCol:toRow:)` (Task 1), `arrowEvents`, `CursorDragEngine`, `encodeKey` — all existing.
- Produces: a controller class installed per-pane exposing `active: Bool`, `suppressed: Bool`, `remove()`, and (unchanged) a `send: ([UInt8]) -> Void` init. NO halo color / refresh API.

**Note:** App-tier — macOS-CI + device only. Read the CURRENT `App/CursorDragController.swift` in full first; you are keeping `cellSize`, `engine`, `emit`, and the `handlePan` `.changed` math, and REMOVING: `halo` (`CursorHaloView`), `cursorCenter`/`cursorHaloPlacement`, `haloRadius`, the halo-gated `gestureRecognizerShouldBegin`, `configure(color:)`, `refresh()`, `setEngaged`, haptics tied to the halo (keep the lift/engage impact if trivial, or drop — see spec: halo haptics are dropped). Rename the file's type is NOT required; keep `CursorDragController`.

- [ ] **Step 1: Rewrite the controller**

Replace `App/CursorDragController.swift` with a halo-free version. Keep the SPDX header. The controller installs TWO recognizers on the `TerminalView`:
- a `UITapGestureRecognizer` → reposition: read current cell `getTerminal().buffer.x/.y`, convert the tap point to a cell via `cellSize`, call `cursorTapArrows(...)`, emit.
- a `UIPanGestureRecognizer` → scrub: the SAME `.began/.changed/.ended` body as today's `handlePan` MINUS the halo (`halo.setEngaged`, `refresh`), reusing `engine.step(...)` + `emit(...)`.

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SwiftTerm
import SemicolynKit

/// Cursor-centric touch controller (replaces the halo). Installs a tap (reposition)
/// and a plain pan (scrub) on a focused, non-mouse-mode `TerminalView`. Long-press →
/// SwiftTerm native selection is a SEPARATE existing recognizer, left untouched; the
/// pan yields to it naturally (early finger movement → pan; stay still ~0.5s → the
/// long-press fires and selection wins).
final class CursorDragController: NSObject, UIGestureRecognizerDelegate {
    /// This pane is the focused one (only the focused pane gets cursor gestures).
    var active = false
    /// The pane is in mouse-reporting mode (`mouse=a`); suspend cursor gestures so
    /// taps/drags forward as SGR mouse events instead.
    var suppressed = false

    private weak var view: TerminalView?
    private let send: ([UInt8]) -> Void
    // `var` (not `let`): CursorDragEngine is a value type whose begin()/step()/end()
    // are `mutating` — a `let` would not compile.
    private var engine = CursorDragEngine()
    private var tap: UITapGestureRecognizer?
    private var pan: UIPanGestureRecognizer?
    private var lastPoint: CGPoint = .zero
    private var emittedAny = false

    init(view: TerminalView, send: @escaping ([UInt8]) -> Void) {
        self.view = view
        self.send = send
        super.init()
        install()
    }

    private func install() {
        guard let view else { return }
        let t = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        t.delegate = self
        view.addGestureRecognizer(t)
        tap = t
        let p = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        p.delegate = self
        view.addGestureRecognizer(p)
        pan = p
    }

    func remove() {
        if let view, let t = tap { view.removeGestureRecognizer(t) }
        if let view, let p = pan { view.removeGestureRecognizer(p) }
        tap = nil; pan = nil
    }

    // MARK: cell metrics

    private func cellSize(of view: TerminalView) -> (Double, Double) {
        let f = view.font
        let w = Double("W".size(withAttributes: [.font: f]).width)
        let h = Double(f.lineHeight)
        return (w, h)
    }

    // MARK: tap → reposition

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard active, !suppressed, let view else { return }
        let term = view.getTerminal()
        let (cw, ch) = cellSize(of: view)
        guard cw > 0, ch > 0 else { return }
        let pt = g.location(in: view)
        let toCol = Int((Double(pt.x) / cw).rounded(.down))
        let toRow = Int((Double(pt.y) / ch).rounded(.down))
        let runs = cursorTapArrows(fromCol: term.buffer.x, fromRow: term.buffer.y,
                                   toCol: toCol, toRow: toRow)
        emitRuns(runs)
    }

    // MARK: pan → scrub (drag math unchanged)

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard active, !suppressed, let view else { return }
        switch g.state {
        case .began:
            engine.begin(); emittedAny = false; lastPoint = g.location(in: view)
        case .changed:
            let pt = g.location(in: view)
            let delta = (dx: Double(pt.x - lastPoint.x), dy: Double(pt.y - lastPoint.y))
            lastPoint = pt
            let v = g.velocity(in: view)
            let speed = Double(hypot(v.x, v.y))
            let (cw, ch) = cellSize(of: view)
            let move = engine.step(fingerDelta: delta, speed: speed, cellW: cw, cellH: ch, at: Date())
            emit(cols: move.cols, rows: move.rows)
        case .ended, .cancelled, .failed:
            engine.end()
        default:
            break
        }
    }

    // MARK: emit

    private func emit(cols: Int, rows: Int) { emitRuns(arrowEvents(cols: cols, rows: rows)) }

    private func emitRuns(_ runs: [ArrowRun]) {
        guard !runs.isEmpty, let view else { return }
        emittedAny = true
        let app = view.getTerminal().applicationCursor
        var bytes: [UInt8] = []
        for run in runs {
            let one = encodeKey(.arrow(run.direction), modifiers: KeyModifiers(), applicationCursorKeys: app)
            for _ in 0 ..< run.count { bytes.append(contentsOf: one) }
        }
        send(bytes)
    }

    // MARK: arbitration

    // Let the tap/pan coexist with SwiftTerm's own recognizers (scroll, the selection
    // long-press). Returning true here lets the long-press and our pan both be
    // recognized; UIKit resolves tap-vs-pan and the long-press cancels on early move.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        return true
    }
}
```

Then delete the halo view:

```bash
git rm App/CursorHaloView.swift
```

- [ ] **Step 2: Verify the reused symbols exist as used**

Run: `grep -n "func begin\|func step\|func end\|applicationCursor\|buffer.x\|buffer.y" Sources/SemicolynKit/Terminal/CursorDragEngine.swift App/*.swift | head`
Confirm `CursorDragEngine` exposes `begin()`, `step(fingerDelta:speed:cellW:cellH:at:) -> (cols:Int,rows:Int)`, `end()`; and `getTerminal().buffer.x/.y` + `.applicationCursor` are used elsewhere already (they were, by the old controller). If `step`'s return shape differs, match it.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "refactor(cursor): halo-free tap+pan controller; remove CursorHaloView

Tap = reposition (cursorTapArrows), plain pan = scrub (existing CursorDragEngine
math, halo-gating removed). Long-press → native selection is a separate existing
recognizer, untouched. App-tier: macOS-CI + device verified."
```

---

### Task 4: Rip out the halo wiring in `TmuxPaneContainer` + `TerminalScreen`

**Files:**
- Modify: `App/TmuxPaneContainer.swift` (remove `installHalo`/`removeHalo`/`refreshCursorHalos`/`setCursorDragActive` bodies' halo bits, `cursorHaloColor`, `cursorDrags` → install the new controller instead)
- Modify: `App/TerminalScreen.swift` (the `cursorDrag` install)

**Interfaces:**
- Consumes: the rewritten `CursorDragController` (Task 3).
- Produces: nothing new.

**Note:** App-tier — macOS-CI + device only. Read BOTH files' halo sections in full first (wiring points enumerated: `TmuxPaneContainer.swift` ~lines 60,70,91,106-107,134,142-201,396,415,438; `TerminalScreen.swift` ~lines 80,147). The controller is still installed per focused pane; only the halo-specific calls go away. Keep `setCursorDragActive(view, isActive)` as a thin setter of the controller's `active` (it still gates which pane gets gestures) and the mouse-mode `suppressed` wiring if present.

- [ ] **Step 1: TmuxPaneContainer — replace halo install/remove with controller install/remove**

Rewrite the coordinator's cursor section so that: creating a pane installs a `CursorDragController(view:send:)` stored in a `[ObjectIdentifier: CursorDragController]` map (keep the map, it's the per-pane controller registry — just no halo); removing a pane calls `controller.remove()`; `setCursorDragActive(view, active)` sets `controller.active` (and, where mouse-mode is known, `controller.suppressed`). DELETE: `cursorHaloColor` (property + didSet + the two assignments at ~60/134), `refreshCursorHalos()` and its call at ~70, `installHalo`/`removeHalo` halo bodies (fold into the controller install/remove), the `cursorHaloPlacement` usage. Read the file and make these edits precisely; the `cursorSend` closure the controller needs is already threaded (`CursorDragController(view: view, send: cursorSend)` existed at ~170).

Concretely, the coordinator keeps:
```swift
private var cursorControllers: [ObjectIdentifier: CursorDragController] = [:]

func installCursor(on view: TerminalView) {
    let key = ObjectIdentifier(view)
    guard cursorControllers[key] == nil else { return }
    cursorControllers[key] = CursorDragController(view: view, send: cursorSend)
}
func removeCursor(from view: TerminalView) {
    let key = ObjectIdentifier(view)
    cursorControllers[key]?.remove()
    cursorControllers[key] = nil
}
func setCursorDragActive(_ view: TerminalView, _ active: Bool) {
    cursorControllers[ObjectIdentifier(view)]?.active = active
}
```
Replace the call sites: `coordinator?.installHalo(on: t)` → `coordinator?.installCursor(on: t)`; `coordinator?.removeHalo(from: view)` → `coordinator?.removeCursor(from: view)`; delete `coordinator?.refreshCursorHalos()`; delete the `cursorHaloColor` assignment in `updateUIView`. Keep `coordinator?.setCursorDragActive(view, isActive)`.

- [ ] **Step 2: TerminalScreen — install the halo-free controller**

The single-terminal path (`TerminalScreen.swift:80`) already does `let cursorDrag = CursorDragController(view: terminal, send: cursorSend)` and stores it (`:147`). With Task 3's rewrite this now installs the tap+pan controller directly. Set `cursorDrag.active = true` (the single terminal is always the focused one) wherever the old code enabled it; remove any halo-color/refresh calls if present. Read the file's cursor section and adjust to the new API (no `configure(color:)`, no `refresh()`).

- [ ] **Step 3: Grep for any remaining halo symbols**

Run: `grep -rn "installHalo\|removeHalo\|refreshCursorHalos\|cursorHaloColor\|CursorHaloView\|cursorHaloPlacement\|CursorHaloGeometry" App/ Sources/`
Expected: ZERO matches. Any remaining reference is a missed wiring point — remove it.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor(cursor): remove halo wiring in TmuxPaneContainer + TerminalScreen

Install the halo-free tap+pan CursorDragController per focused pane; drop
cursorHaloColor / refreshCursorHalos / installHalo-removeHalo halo bodies.
setCursorDragActive now just toggles the controller's `active`. App-tier:
macOS-CI + device verified."
```

---

### Task 5: Verify loupe wiring + update the spec's decision log

**Files:**
- Verify: `Sources/SemicolynKit/Terminal/LoupeWindow.swift` is wired to the selection long-press (or note it as a deferred slice, unchanged by this work).
- Modify: `docs/brainstorming-decisions.md` (§"Cursor placement" → point to the cursor-centric spec), and move the spec onto this branch if not already present.

**Interfaces:** none.

- [ ] **Step 1: Confirm the cursor-centric spec is on this branch**

The spec `docs/superpowers/specs/2026-07-06-cursor-centric-interaction-design.md` lives on `feat/cursor-centric-interaction`. Ensure it's present on this working branch (cherry-pick its commit `5ad3b21` or copy the file). If already present, skip.

- [ ] **Step 2: Check loupe wiring**

Run: `grep -rn "LoupeWindow\|selectionLongPress\|UILongPressGestureRecognizer" App/ Sources/`
If `LoupeWindow` is already wired to the `selectionLongPress` in `TerminalScreen`/`TmuxPaneContainer`, leave it. If it was a deferred slice (defined but unwired), do NOT wire it here — that's a separate feature; just note its state in the commit message. The redesign KEEPS the existing long-press → native selection untouched.

- [ ] **Step 3: Update the decision log**

In `docs/brainstorming-decisions.md`, find the §"Cursor placement" entry (the always-on halo decision). Add a line: `**Superseded 2026-07-07** by 2026-07-06-cursor-centric-interaction-design.md — the always-on halo is replaced by the iOS-native tap/quick-drag/hold model (tap=reposition, drag=scrub, hold=select).` (Match the doc's existing entry format; read it first.)

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "docs: supersede the halo decision with the cursor-centric model; note loupe state"
```

---

## Self-Review

**Spec coverage:**
- Removed halo machinery (`CursorHaloView`, `CursorDragController` halo bits, `CursorHaloGeometry` + tests, wiring) → Tasks 2, 3, 4. ✅
- Kept & reused `CursorDragEngine`, `CursorArrowStream`, long-press selection, `LoupeWindow` → Task 3 (reuse), Task 5 (loupe verify). ✅
- Added `CursorTapTarget` Kit seam + App tap/pan recognizers → Task 1, Task 3. ✅
- Gesture arbitration (move→scrub / hold→select / tap→place) → Task 3 (recognizers + simultaneous recognition). ✅
- Mouse-mode suspension → Task 3 (`suppressed`) + Task 4 wiring. ✅
- Testing (CursorTapTarget Kit-tested; drag/arrow tests retained; halo geometry tests deleted) → Task 1, Task 2. ✅
- Decision-log update → Task 5. ✅

**Placeholder scan:** No TBD/TODO. App-tier tasks note "read the file first / match the existing API" because the exact surrounding lines shift — that's a real instruction (the wiring points are enumerated), not a placeholder. Kit tasks carry complete code + exact commands.

**Type consistency:** `cursorTapArrows(fromCol:fromRow:toCol:toRow:) -> [ArrowRun]` (Task 1) is consumed identically in Task 3. `CursorDragController(view:send:)` + `.active`/`.suppressed`/`.remove()` (Task 3) match Task 4's wiring. `arrowEvents`, `ArrowRun{direction,count}`, `engine.step(...)`, `getTerminal().buffer.x/.y`/`.applicationCursor` all reused as read from the existing code.

**Caveat noted for implementers:** Task 1's tests encode the REQUIRED behavior (tap right → `.right`); if `arrowEvents`' sign convention differs, the impl must negate to satisfy the tests — flagged in Task 1 Step 3. Tasks 3–4 are App-tier (macOS-CI + device), so the tap/pan *feel* is device-verified; only the arrow-count math is Linux-tested.
