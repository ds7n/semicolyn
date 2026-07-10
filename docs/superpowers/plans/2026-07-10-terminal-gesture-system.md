<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Terminal Gesture System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace SwiftTerm's built-in terminal touch gestures with our own gesture layer so single-finger vertical drag scrolls, horizontal drag switches tmux windows, tap places the cursor, double/triple-tap select, long-press zooms a tmux pane, and two-finger tap shows a Copy/Paste menu.

**Architecture:** Pure decision logic (axis-lock pan classification, clamped window stepping) lives in `Sources/SemicolynKit/Terminal/` and `Sources/SemicolynKit/Tmux/` and is Linux-`swift test`ed. A thin App-tier `TerminalGestureController` (per `TerminalView`) disables SwiftTerm's own recognizers, installs ours, and applies effects through SwiftTerm's public API (`contentOffset` scroll, `setSelectionRange`, `clearSelection`) and the existing tmux command callbacks (`selectWindow`, `zoomActivePane`). Wired at both terminal mount sites: raw PTY (`App/TerminalScreen.swift`) and tmux panes (`App/TmuxPaneContainer.swift`).

**Tech Stack:** Swift 6 (strict concurrency in `SemicolynKit`), XCTest, UIKit gesture recognizers (App tier), SwiftTerm 1.x (`TerminalView: UIScrollView`).

## Global Constraints

- **Two-tier rule:** `Sources/SemicolynKit/` = pure logic, Linux-tested, Swift 6 `Sendable`, **no `import UIKit`/`SwiftUI`**. `App/` = Apple-only, validated only by the macOS CI job. Put every decision in SemicolynKit; keep App code a thin wiring layer. — copied from `CLAUDE.md`.
- **SPDX header** on every new source file: `// SPDX-FileCopyrightText: 2026 True Positive LLC` / `// SPDX-License-Identifier: GPL-3.0-only`.
- **Tests must be real** (per `docs/superpowers/specs/2026-06-18-testing-standards-design.md`): equivalence partitioning + boundary values, assert exact observable values (no tautologies), every negative test asserts the *specific* result (e.g. `nil`, exact case), not merely "it didn't crash".
- **Conventional commits** (`feat:`/`fix:`/`refactor:`/`docs:`). One feature branch for the whole plan: `feat/terminal-gesture-system`.
- **Linux test command:** `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <Name>`. There is **no Swift toolchain on the host** — Linux Swift runs in the `semicolyn-dev` Docker image.
- **App-tier tasks are not Linux-buildable.** Their "run the test" step is the macOS CI job on the PR, not a local command. Steps say so explicitly.
- **Locked product decisions** (from brainstorming, this session):
  - Horizontal window-switch **clamps** at the ends of the window list (no wrap).
  - Horizontal window-switch commits **one window per drag, on finger release**.
  - `CursorDragEngine` (drag-scrub gain curve) is **retired** — deleted along with its tests.

---

## File Structure

**New (SemicolynKit, Linux-tested):**
- `Sources/SemicolynKit/Terminal/GestureClassifier.swift` — pure pan → `PanGesture` axis-lock decision.
- `Tests/SemicolynKitTests/GestureClassifierTests.swift`
- `WindowNavigation.swift` gains a **`clampedStepIndex`** function (clamp variant beside the existing wrapping `stepIndex`).

**New (App, macOS-CI-only):**
- `App/TerminalGestureController.swift` — per-`TerminalView` UIKit controller: disables SwiftTerm's recognizers, installs ours, applies effects.

**Modified:**
- `App/TerminalScreen.swift` — raw-PTY mount: install `TerminalGestureController`, drop `allowMouseReporting = false` reliance for scrub.
- `App/TmuxPaneContainer.swift` — tmux mount: install `TerminalGestureController` per pane; horizontal-switch + long-press-zoom callbacks.
- `App/ConnectionViewModel.swift` — add `selectAdjacentWindowClamped(_:)` seam the controller calls (clamp, not the wrapping `selectNextWindow`).

**Deleted (retire CursorDragEngine):**
- `Sources/SemicolynKit/Terminal/CursorDragEngine.swift`
- `Tests/SemicolynKitTests/CursorDragEngineTests.swift`

**Docs:**
- `docs/brainstorming-decisions.md` — note the cursor-placement *drag* is superseded (tap retained).

---

## Task 1: `clampedStepIndex` — clamped window stepping (pure, Linux)

**Files:**
- Modify: `Sources/SemicolynKit/Tmux/WindowNavigation.swift`
- Test: `Tests/SemicolynKitTests/WindowNavigationTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `public func clampedStepIndex(current: Int, delta: Int, count: Int) -> Int?` — destination index for one step, **clamped** at the ends; returns `nil` when the step is a no-op (already at the boundary in that direction, `<2` windows, or `current` out of `0..<count`). Distinct from the existing wrapping `stepIndex`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/SemicolynKitTests/WindowNavigationTests.swift`:

```swift
    // MARK: clampedStepIndex — clamps at ends (horizontal-drag window switch)

    // EP: forward/backward within range moves one.
    func testClampedForwardStepMovesToNextIndex() {
        XCTAssertEqual(clampedStepIndex(current: 0, delta: +1, count: 3), 1)
    }

    func testClampedBackwardStepMovesToPreviousIndex() {
        XCTAssertEqual(clampedStepIndex(current: 2, delta: -1, count: 3), 1)
    }

    // BVA: at the last window, forward is a no-op (clamp, does NOT wrap to 0).
    func testClampedForwardAtLastIsNoOp() {
        XCTAssertNil(clampedStepIndex(current: 2, delta: +1, count: 3))
    }

    // BVA: at the first window, backward is a no-op (clamp, does NOT wrap to last).
    func testClampedBackwardAtFirstIsNoOp() {
        XCTAssertNil(clampedStepIndex(current: 0, delta: -1, count: 3))
    }

    // BVA: two windows — forward from 0 → 1, forward from 1 clamps (nil).
    func testClampedTwoWindows() {
        XCTAssertEqual(clampedStepIndex(current: 0, delta: +1, count: 2), 1)
        XCTAssertNil(clampedStepIndex(current: 1, delta: +1, count: 2))
    }

    // Negative: single window is a no-op.
    func testClampedSingleWindowIsNoOp() {
        XCTAssertNil(clampedStepIndex(current: 0, delta: +1, count: 1))
    }

    // Negative: zero windows is a no-op.
    func testClampedZeroWindowsIsNoOp() {
        XCTAssertNil(clampedStepIndex(current: 0, delta: +1, count: 0))
    }

    // Negative: out-of-range current is a no-op (guards stale state).
    func testClampedOutOfRangeCurrentIsNoOp() {
        XCTAssertNil(clampedStepIndex(current: 5, delta: +1, count: 3))
        XCTAssertNil(clampedStepIndex(current: -1, delta: +1, count: 3))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter WindowNavigationTests`
Expected: FAIL — `cannot find 'clampedStepIndex' in scope`.

- [ ] **Step 3: Implement `clampedStepIndex`**

Append to `Sources/SemicolynKit/Tmux/WindowNavigation.swift` (below `stepIndex`):

```swift
/// Clamped destination index for stepping between tmux windows by one (horizontal
/// drag). Unlike `stepIndex`, this does NOT wrap: at the last window a forward step
/// and at the first window a backward step both return `nil` (a no-op). Also `nil`
/// for fewer than two windows or a `current` outside `0..<count`. `delta` is ±1.
public func clampedStepIndex(current: Int, delta: Int, count: Int) -> Int? {
    guard count > 1, current >= 0, current < count else { return nil }
    let target = current + delta
    guard target >= 0, target < count else { return nil }
    return target
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter WindowNavigationTests`
Expected: PASS (all, including the pre-existing `stepIndex` tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Tmux/WindowNavigation.swift Tests/SemicolynKitTests/WindowNavigationTests.swift
git commit -m "feat(tmux): add clampedStepIndex for horizontal-drag window switch"
```

---

## Task 2: `GestureClassifier` — pan axis-lock decision (pure, Linux)

**Files:**
- Create: `Sources/SemicolynKit/Terminal/GestureClassifier.swift`
- Test: `Tests/SemicolynKitTests/GestureClassifierTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public enum PanGesture: Equatable, Sendable { case none; case scrollVertical; case switchWindow(delta: Int) }`
  - `public struct GestureClassifier: Sendable` with:
    - `public static let deadZonePoints: Double` (dead-zone radius, points)
    - `public static func classify(dx: Double, dy: Double, isMultiWindowTmux: Bool) -> PanGesture`
  - Semantics: below the dead-zone → `.none`. Past it, dominant axis wins: vertical dominant → `.scrollVertical`; horizontal dominant → `.switchWindow(delta: dx > 0 ? +1 : -1)` **only if** `isMultiWindowTmux`, else `.scrollVertical` (horizontal drag falls through to scroll in raw/single-window). `delta` sign: rightward drag (`dx > 0`) = next window (`+1`), leftward = previous (`-1`).

- [ ] **Step 1: Write the failing tests**

Create `Tests/SemicolynKitTests/GestureClassifierTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Axis-lock classification of a terminal pan: vertical → scroll, horizontal →
/// tmux window switch (only when multi-window tmux, else scroll), sub-dead-zone → none.
final class GestureClassifierTests: XCTestCase {
    private let dz = GestureClassifier.deadZonePoints

    // EP: clear vertical drag → scroll (both tmux and raw).
    func testVerticalDragScrollsInTmux() {
        XCTAssertEqual(GestureClassifier.classify(dx: 2, dy: dz + 40, isMultiWindowTmux: true),
                       .scrollVertical)
    }

    func testVerticalDragScrollsInRaw() {
        XCTAssertEqual(GestureClassifier.classify(dx: 2, dy: dz + 40, isMultiWindowTmux: false),
                       .scrollVertical)
    }

    // EP: clear rightward horizontal drag, multi-window tmux → next window (+1).
    func testHorizontalRightSwitchesNext() {
        XCTAssertEqual(GestureClassifier.classify(dx: dz + 40, dy: 2, isMultiWindowTmux: true),
                       .switchWindow(delta: +1))
    }

    // EP: clear leftward horizontal drag, multi-window tmux → previous window (-1).
    func testHorizontalLeftSwitchesPrev() {
        XCTAssertEqual(GestureClassifier.classify(dx: -(dz + 40), dy: 2, isMultiWindowTmux: true),
                       .switchWindow(delta: -1))
    }

    // EP: horizontal drag, NOT multi-window tmux → falls through to scroll.
    func testHorizontalInRawFallsThroughToScroll() {
        XCTAssertEqual(GestureClassifier.classify(dx: dz + 40, dy: 2, isMultiWindowTmux: false),
                       .scrollVertical)
    }

    // BVA: total movement below the dead-zone → none (no classification yet).
    func testSubDeadZoneIsNone() {
        XCTAssertEqual(GestureClassifier.classify(dx: dz * 0.4, dy: dz * 0.4, isMultiWindowTmux: true),
                       .none)
    }

    // BVA: just past the dead-zone on the vertical axis → scroll (boundary+1).
    func testJustPastDeadZoneVertical() {
        XCTAssertEqual(GestureClassifier.classify(dx: 0, dy: dz + 0.1, isMultiWindowTmux: true),
                       .scrollVertical)
    }

    // BVA: just past the dead-zone on the horizontal axis (tmux) → switch.
    func testJustPastDeadZoneHorizontal() {
        XCTAssertEqual(GestureClassifier.classify(dx: dz + 0.1, dy: 0, isMultiWindowTmux: true),
                       .switchWindow(delta: +1))
    }

    // Diagonal near-45°, vertical slightly dominant → scroll (axis by dominance).
    func testDiagonalVerticalDominantScrolls() {
        XCTAssertEqual(GestureClassifier.classify(dx: dz + 30, dy: dz + 45, isMultiWindowTmux: true),
                       .scrollVertical)
    }

    // Diagonal near-45°, horizontal slightly dominant (tmux) → switch.
    func testDiagonalHorizontalDominantSwitches() {
        XCTAssertEqual(GestureClassifier.classify(dx: dz + 45, dy: dz + 30, isMultiWindowTmux: true),
                       .switchWindow(delta: +1))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter GestureClassifierTests`
Expected: FAIL — `cannot find 'GestureClassifier' in scope`.

- [ ] **Step 3: Implement `GestureClassifier`**

Create `Sources/SemicolynKit/Terminal/GestureClassifier.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The action a terminal single-finger pan resolves to.
public enum PanGesture: Equatable, Sendable {
    /// Movement is still within the dead-zone — do not act yet.
    case none
    /// Scroll the scrollback (vertical drag, or horizontal fall-through).
    case scrollVertical
    /// Switch tmux window by `delta` (+1 next / −1 previous). Only produced for a
    /// horizontal-dominant drag in multi-window tmux.
    case switchWindow(delta: Int)
}

/// Pure axis-lock classifier for a terminal pan. Given the cumulative translation
/// `(dx, dy)` in points (dx>0 = rightward, dy>0 = downward) and whether the terminal
/// is a multi-window tmux session, decides scroll vs. window-switch. Vertical drags
/// always scroll; horizontal drags switch windows only under multi-window tmux and
/// otherwise fall through to scroll. Movement inside the dead-zone yields `.none`.
public struct GestureClassifier: Sendable {
    /// Radius (points) the finger must travel before the pan is classified. Tuned to
    /// avoid classifying a tap-with-jitter; feel-tuned on device.
    public static let deadZonePoints: Double = 12

    public static func classify(dx: Double, dy: Double, isMultiWindowTmux: Bool) -> PanGesture {
        // Dead-zone: require the finger to travel past the radius (Euclidean) first.
        guard (dx * dx + dy * dy) >= deadZonePoints * deadZonePoints else { return .none }

        // Dominant axis wins.
        if abs(dy) >= abs(dx) {
            return .scrollVertical
        }
        // Horizontal-dominant: switch windows only in multi-window tmux, else scroll.
        guard isMultiWindowTmux else { return .scrollVertical }
        return .switchWindow(delta: dx > 0 ? +1 : -1)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter GestureClassifierTests`
Expected: PASS (all 10).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Terminal/GestureClassifier.swift Tests/SemicolynKitTests/GestureClassifierTests.swift
git commit -m "feat(terminal): add GestureClassifier pan axis-lock decider"
```

---

## Task 3: Retire `CursorDragEngine` (delete dead code, pure, Linux)

**Files:**
- Delete: `Sources/SemicolynKit/Terminal/CursorDragEngine.swift`
- Delete: `Tests/SemicolynKitTests/CursorDragEngineTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing. Removes `CursorDragEngine`. `CursorArrowStream` (`arrowEvents`) and `CursorTapTarget` (`cursorTapArrows`) are **kept** — single-tap cursor placement still uses them.

**Precondition check (do this first):** confirm no App-tier code references `CursorDragEngine`. From Task-0 investigation, the only App reference to the cursor stack is via SwiftTerm's built-in scrub (no direct `CursorDragEngine` usage). Verify:

- [ ] **Step 1: Confirm no remaining references**

Run: `grep -rn "CursorDragEngine" Sources App Tests`
Expected: matches ONLY in `CursorDragEngine.swift` and `CursorDragEngineTests.swift` (the files being deleted). If any OTHER file references it, STOP and reconcile before deleting.

- [ ] **Step 2: Delete the files**

```bash
git rm Sources/SemicolynKit/Terminal/CursorDragEngine.swift Tests/SemicolynKitTests/CursorDragEngineTests.swift
```

- [ ] **Step 3: Run the full Kit suite to verify nothing broke**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS — the suite builds and passes without `CursorDragEngine`.

- [ ] **Step 4: Commit**

```bash
git commit -m "refactor(terminal): retire CursorDragEngine (drag-scrub superseded by scroll)"
```

---

## Task 4: `TerminalGestureController` — App-tier gesture layer (macOS-CI-only)

> **Not Linux-buildable.** `swift test` cannot see `App/`. The verification gate is the macOS CI job on the PR (see Task 6). Write the code carefully to the real SwiftTerm 1.x API confirmed below.

**SwiftTerm 1.x public API this task relies on (verified against `iOSTerminalView.swift`):**
- `TerminalView: UIScrollView` → `public override var contentOffset: CGPoint` (settable → scroll).
- `public func setSelectionRange(start: Position, end: Position)`, `public func clearSelection()`, `public var hasActiveSelection: Bool`.
- `public var allowMouseReporting: Bool`.
- `public func disableMousePanGesture()`, `public func disableSelectionPanGesture()` (the two stored pan recognizers).
- SwiftTerm's **tap/double-tap/triple-tap/long-press are UNSTORED local vars** with no public handle → they are reachable only via `view.gestureRecognizers` and disabled by `.isEnabled = false`.
- `getTerminal()` exposes public `cols`, `rows`, `getCursorLocation()` (returns a position with `.x`/`.y` = col/row — **already used in `App/SwiftTermEchoOracle.swift:31`**), and `getCharData(col:row:) -> CharData?` + `getCharacter(for: CharData) -> Character` (also used in `SwiftTermEchoOracle.swift`). `Position` = `(col: Int, row: Int)`.
- `calculateTapHit(point:)` is **internal** (not reachable) → we compute cell from `point` and the app-known cell size ourselves.
- **Do NOT use `buffer.x`/`buffer.y`** — they are `internal` in SwiftTerm and won't compile from the app; use `getCursorLocation()`.

**Files:**
- Create: `App/TerminalGestureController.swift`

**Interfaces:**
- Consumes: `TerminalView` (SwiftTerm); `GestureClassifier`, `PanGesture`, `cursorTapArrows`, `arrowEvents`, `ArrowRun`, `ArrowDirection` (SemicolynKit); callbacks supplied by the mount site.
- Produces: `final class TerminalGestureController: NSObject` with:
  - `init(terminalView: TerminalView, callbacks: Callbacks)` — installs the gesture layer.
  - `struct Callbacks` holding closures the mount site provides:
    - `isMultiWindowTmux: () -> Bool`
    - `onSwitchWindow: (Int) -> Void`  // delta ±1; mount clamps
    - `onLongPressZoom: () -> Void`     // tmux pane-zoom; raw = no-op closure
    - `onPlaceCursor: (_ toCol: Int, _ toRow: Int) -> Void` // emits arrow keys via existing stream
    - `mouseReportingActive: () -> Bool` // when true, controller yields to mouse forwarding
  - `func detach()` — removes our recognizers (called on teardown).
  - Conforms to `UIGestureRecognizerDelegate` so pinch + our recognizers coexist and SwiftTerm's disabled ones stay dead.

- [ ] **Step 1: Implement the controller**

Create `App/TerminalGestureController.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SwiftTerm
import SemicolynKit

/// Owns the terminal touch map for a single `TerminalView`, replacing SwiftTerm's
/// built-in recognizers. Single-finger vertical drag scrolls (`contentOffset`);
/// horizontal drag switches tmux windows (one per drag, on release, via
/// `GestureClassifier` + the mount's clamp); single tap places the cursor;
/// double/triple-tap word/line-select; long-press zooms the tmux pane; two-finger
/// tap shows the edit menu. A mouse-reporting pane (`mouse=a`) yields: we set
/// `allowMouseReporting = true` and let SwiftTerm forward events (our recognizers
/// still installed but no-op via the `mouseReportingActive` guard).
///
/// SwiftTerm's own tap/long-press recognizers are unstored local vars, so we disable
/// them by scanning `terminalView.gestureRecognizers` for recognizers that are not
/// ours; its two stored pan recognizers are disabled via the public
/// `disableMousePanGesture()` / `disableSelectionPanGesture()`.
final class TerminalGestureController: NSObject, UIGestureRecognizerDelegate {
    struct Callbacks {
        let isMultiWindowTmux: () -> Bool
        let onSwitchWindow: (Int) -> Void
        let onLongPressZoom: () -> Void
        let onPlaceCursor: (_ toCol: Int, _ toRow: Int) -> Void
        let mouseReportingActive: () -> Bool
    }

    private weak var terminalView: TerminalView?
    private let callbacks: Callbacks

    // Our recognizers (kept so we can identify + remove them, and so the delegate can
    // tell ours apart from SwiftTerm's).
    private var ours: [UIGestureRecognizer] = []
    private var pan: UIPanGestureRecognizer!
    private var singleTap: UITapGestureRecognizer!
    private var doubleTap: UITapGestureRecognizer!
    private var tripleTap: UITapGestureRecognizer!
    private var longPress: UILongPressGestureRecognizer!
    private var twoFingerTap: UITapGestureRecognizer!
    private var editMenu: UIEditMenuInteraction!

    init(terminalView: TerminalView, callbacks: Callbacks) {
        self.terminalView = terminalView
        self.callbacks = callbacks
        super.init()
        disableSwiftTermRecognizers(on: terminalView)
        installOurRecognizers(on: terminalView)
    }

    // MARK: Setup

    private func disableSwiftTermRecognizers(on view: TerminalView) {
        // SwiftTerm's stored pan recognizers: public disable methods.
        view.disableMousePanGesture()
        view.disableSelectionPanGesture()
        // SwiftTerm's tap/double/triple/long-press are unstored → disable everything
        // currently attached that is NOT ours. Ours aren't installed yet at this point,
        // so every existing recognizer here is SwiftTerm's (or a sibling like pinch,
        // which the mount installs AFTER this controller — order matters, see mount).
        for gr in view.gestureRecognizers ?? [] where !ours.contains(gr) {
            gr.isEnabled = false
        }
    }

    private func installOurRecognizers(on view: TerminalView) {
        pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self

        singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.delegate = self

        doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self

        tripleTap = UITapGestureRecognizer(target: self, action: #selector(handleTripleTap(_:)))
        tripleTap.numberOfTapsRequired = 3
        tripleTap.delegate = self

        longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        longPress.delegate = self

        twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.delegate = self

        // Tap disambiguation: single waits for double to fail, double waits for triple.
        singleTap.require(toFail: doubleTap)
        doubleTap.require(toFail: tripleTap)

        editMenu = UIEditMenuInteraction(delegate: self)
        view.addInteraction(editMenu)

        ours = [pan, singleTap, doubleTap, tripleTap, longPress, twoFingerTap]
        for gr in ours { view.addGestureRecognizer(gr) }
    }

    func detach() {
        guard let view = terminalView else { return }
        for gr in ours { view.removeGestureRecognizer(gr) }
        view.removeInteraction(editMenu)
        ours = []
    }

    // MARK: Cell geometry

    /// Convert a point in the terminal view to a (col, row) cell using the terminal's
    /// current grid and the view's content size (SwiftTerm lays cells out uniformly).
    private func cell(at point: CGPoint, in view: TerminalView) -> (col: Int, row: Int) {
        let term = view.getTerminal()
        let cols = max(term.cols, 1)
        let rows = max(term.rows, 1)
        let cellW = view.bounds.width / CGFloat(cols)
        let cellH = view.bounds.height / CGFloat(rows)
        guard cellW > 0, cellH > 0 else { return (0, 0) }
        let col = min(cols - 1, max(0, Int(point.x / cellW)))
        // Account for scrollback offset: the visible top row is contentOffset.y / cellH.
        let visualRow = Int((point.y + view.contentOffset.y) / cellH)
        let row = min(rows - 1, max(0, visualRow - Int(view.contentOffset.y / cellH)))
        return (col, row)
    }

    // MARK: Handlers

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard let view = terminalView else { return }
        if callbacks.mouseReportingActive() { return }  // mouse app: SwiftTerm forwards
        let t = g.translation(in: view)
        switch g.state {
        case .changed:
            // Vertical scroll tracks the finger live; horizontal-switch commits on end.
            let decision = GestureClassifier.classify(
                dx: Double(t.x), dy: Double(t.y),
                isMultiWindowTmux: callbacks.isMultiWindowTmux())
            if case .scrollVertical = decision {
                var offset = view.contentOffset
                // Dragging down (finger moves down) reveals earlier scrollback → offset up.
                offset.y = max(0, offset.y - g.translation(in: view).y)
                view.setContentOffset(offset, animated: false)
                g.setTranslation(.zero, in: view)   // incremental
            }
        case .ended, .cancelled:
            let decision = GestureClassifier.classify(
                dx: Double(t.x), dy: Double(t.y),
                isMultiWindowTmux: callbacks.isMultiWindowTmux())
            if case .switchWindow(let delta) = decision {
                callbacks.onSwitchWindow(delta)
            }
        default:
            break
        }
    }

    @objc private func handleSingleTap(_ g: UITapGestureRecognizer) {
        guard let view = terminalView else { return }
        if callbacks.mouseReportingActive() { return }
        let p = g.location(in: view)
        let target = cell(at: p, in: view)
        callbacks.onPlaceCursor(target.col, target.row)
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        guard let view = terminalView else { return }
        let p = g.location(in: view)
        let (col, row) = cell(at: p, in: view)
        // Word-select: expand from the tapped cell across non-space runs on that row.
        let (start, end) = wordBounds(col: col, row: row, in: view)
        view.setSelectionRange(start: Position(col: start, row: row), end: Position(col: end, row: row))
        presentEditMenu(at: p, in: view)
    }

    @objc private func handleTripleTap(_ g: UITapGestureRecognizer) {
        guard let view = terminalView else { return }
        let p = g.location(in: view)
        let (_, row) = cell(at: p, in: view)
        let cols = max(view.getTerminal().cols, 1)
        view.setSelectionRange(start: Position(col: 0, row: row),
                               end: Position(col: cols - 1, row: row))
        presentEditMenu(at: p, in: view)
    }

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        callbacks.onLongPressZoom()
    }

    @objc private func handleTwoFingerTap(_ g: UITapGestureRecognizer) {
        guard let view = terminalView else { return }
        presentEditMenu(at: g.location(in: view), in: view)
    }

    // MARK: Selection helpers

    /// Word bounds on a row: walk left/right from `col` over non-space glyphs.
    private func wordBounds(col: Int, row: Int, in view: TerminalView) -> (Int, Int) {
        let term = view.getTerminal()
        let cols = max(term.cols, 1)
        func isWordChar(_ c: Int) -> Bool {
            guard let cd = term.getCharData(col: c, row: row) else { return false }
            let ch = term.getCharacter(for: cd)   // Character; matches SwiftTermEchoOracle usage
            return !(ch == " " || ch == "\t" || ch == "\0")
        }
        var lo = min(max(col, 0), cols - 1)
        var hi = lo
        while lo > 0, isWordChar(lo - 1) { lo -= 1 }
        while hi < cols - 1, isWordChar(hi + 1) { hi += 1 }
        return (lo, hi)
    }

    private func presentEditMenu(at point: CGPoint, in view: TerminalView) {
        let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: point)
        editMenu.presentEditMenu(with: config)
    }

    // MARK: UIGestureRecognizerDelegate

    // Let our recognizers coexist with the mount's pinch (pinch is 2-finger, our pan is
    // 1-finger; allow simultaneous so a stray second finger doesn't kill scroll).
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        return true
    }
}

// MARK: UIEditMenuInteractionDelegate

extension TerminalGestureController: UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                             menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let view = terminalView else { return UIMenu(children: suggestedActions) }
        var items: [UIMenuElement] = []
        if view.hasActiveSelection {
            items.append(UIAction(title: "Copy") { [weak view] _ in view?.copy(nil) })
        }
        if UIPasteboard.general.hasStrings {
            items.append(UIAction(title: "Paste") { [weak view] _ in view?.paste(nil) })
        }
        return UIMenu(children: items.isEmpty ? suggestedActions : items)
    }
}
```

**Notes for the implementer (App tier, macOS-CI-verified):**
- If `term.getCharData(col:row:)` / `CharData.getCharacter()` are not the exact SwiftTerm 1.x signatures, adapt `wordBounds` to whatever the buffer read API is; the *fallback* per spec is a drag-select span. Keep the classifier/window logic (pure, already tested) unchanged.
- `view.copy(nil)` / `view.paste(nil)` are the SwiftTerm `@objc open override` methods confirmed present.
- The `cell(at:)` scrollback math simplifies to `Int(point.y / cellH)` for the visible viewport; the offset terms are written defensively. If SwiftTerm's `contentOffset` already accounts for the visible frame, simplify to visible-viewport rows during device tuning.

- [ ] **Step 2: Verify it compiles (macOS CI)**

This file cannot be built on Linux. Compilation is verified by the macOS CI job in Task 6. Do not attempt a local build. Proceed to Task 5 (wiring); commit both, then push and let CI compile.

- [ ] **Step 3: Commit**

```bash
git add App/TerminalGestureController.swift
git commit -m "feat(app): add TerminalGestureController replacing SwiftTerm's touch map"
```

---

## Task 5: Wire the controller at both mount sites + clamp seam (macOS-CI-only)

> **Not Linux-buildable** — macOS CI (Task 6) is the gate.

**Files:**
- Modify: `App/ConnectionViewModel.swift` — add clamped adjacent-window seam.
- Modify: `App/TerminalScreen.swift` — raw-PTY mount.
- Modify: `App/TmuxPaneContainer.swift` — tmux pane mount.

**Interfaces:**
- Consumes: `TerminalGestureController`, `TerminalGestureController.Callbacks` (Task 4); `clampedStepIndex` (Task 1); existing `cursorTapArrows`, `arrowEvents` (SemicolynKit).
- Produces: `ConnectionViewModel.selectAdjacentWindowClamped(_ delta: Int)` — steps one window with clamp (no wrap); no-op at the ends or when not multi-window tmux.

### 5a — Clamped seam in ConnectionViewModel

- [ ] **Step 1: Add `selectAdjacentWindowClamped`**

In `App/ConnectionViewModel.swift`, add near `stepWindow(_:)` (which wraps and stays for the Esc-pill/⌘] paths):

```swift
    /// Horizontal-drag window switch: step one window with CLAMP (no wrap). No-op at
    /// the ends of the window list, with <2 windows, or in raw-PTY mode.
    func selectAdjacentWindowClamped(_ delta: Int) {
        guard let state = tmuxState,
              let active = state.activeWindow,
              let idx = state.windows.firstIndex(where: { $0.id == active }),
              let next = clampedStepIndex(current: idx, delta: delta, count: state.windows.count)
        else { return }
        selectWindow(state.windows[next].id)
    }

    /// True when the active tmux session has more than one window (drives horizontal
    /// drag = window switch vs. scroll fall-through).
    var isMultiWindowTmux: Bool { (tmuxState?.windows.count ?? 0) > 1 }
```

### 5b — Raw-PTY mount (`TerminalScreen.swift`)

- [ ] **Step 2: Install the controller in `makeUIView`, remove scrub reliance**

In `App/TerminalScreen.swift`, replace the `allowMouseReporting = false` cursor-scrub block (around lines 87–94) and install the controller AFTER pinch + restoreTap are added (so `disableSwiftTermRecognizers` catches SwiftTerm's own recognizers but our controller's own list is excluded, and pinch/restoreTap — added before — must be re-enabled if the sweep disabled them). Concretely:

```swift
        // Install our own gesture layer (replaces SwiftTerm's built-in tap/scrub/select).
        // Raw PTY: no tmux, so horizontal drag falls through to scroll and long-press
        // zoom is a no-op.
        let gestureController = TerminalGestureController(
            terminalView: terminal,
            callbacks: .init(
                isMultiWindowTmux: { false },
                onSwitchWindow: { _ in },
                onLongPressZoom: { },
                onPlaceCursor: { [weak coordinator = context.coordinator] col, row in
                    coordinator?.placeCursor(toCol: col, toRow: row, in: terminal)
                },
                mouseReportingActive: { terminal.allowMouseReporting }
            )
        )
        context.coordinator.gestureController = gestureController
```

**Important ordering fix:** `disableSwiftTermRecognizers` disables *every* recognizer not in `ours`, which would also disable the pinch and restoreTap added just before. After constructing the controller, RE-ENABLE those two:

```swift
        // The controller's sweep disabled all pre-existing recognizers (SwiftTerm's +
        // ours-that-aren't). Re-enable the app's own pinch and keyboard-restore taps.
        pinch.isEnabled = true
        restoreTap.isEnabled = true
```

- [ ] **Step 3: Add `gestureController` storage + `placeCursor` on the Coordinator**

In the `Coordinator` class of `TerminalScreen.swift`, add:

```swift
        /// Retains the gesture layer for this terminal (replaces SwiftTerm's built-ins).
        var gestureController: TerminalGestureController?

        /// Place the terminal cursor at (toCol,toRow) by emitting arrow keys from the
        /// current cursor cell (single-tap cursor placement — reuses the pure encoders).
        func placeCursor(toCol: Int, toRow: Int, in view: TerminalView) {
            let term = view.getTerminal()
            let cur = term.getCursorLocation()   // .x = col, .y = row (see SwiftTermEchoOracle)
            let runs = cursorTapArrows(fromCol: cur.x, fromRow: cur.y, toCol: toCol, toRow: toRow)
            for run in runs {
                let bytes = encodeArrowRun(run)
                if !bytes.isEmpty { sendTerminalInput(bytes) }
            }
        }
```

- [ ] **Step 4: Add the arrow-run encoder helper (shared)**

If not already present, add a small encoder near the Coordinator (or reuse the existing `encodeKey(.arrow(...))` path if one exists — check `grep -n "encodeKey\|arrow" App/*.swift` and prefer the existing encoder). Minimal fallback:

```swift
        /// Encode one ArrowRun to its CSI escape bytes, repeated `count` times.
        private func encodeArrowRun(_ run: ArrowRun) -> [UInt8] {
            let tail: [UInt8]
            switch run.direction {
            case .up:    tail = [0x1b, 0x5b, 0x41]   // ESC [ A
            case .down:  tail = [0x1b, 0x5b, 0x42]   // ESC [ B
            case .right: tail = [0x1b, 0x5b, 0x43]   // ESC [ C
            case .left:  tail = [0x1b, 0x5b, 0x44]   // ESC [ D
            }
            return Array(repeating: tail, count: run.count).flatMap { $0 }
        }
```

**Implementer note:** a grep for an existing App-tier arrow-CSI encoder found none, so this `encodeArrowRun` helper is the encoder to add. `sendTerminalInput` is the existing send path used by `pasteFromClipboard`. `ArrowRun`/`ArrowDirection` come from SemicolynKit (`CursorArrowStream.swift`).

### 5c — tmux pane mount (`TmuxPaneContainer.swift`)

- [ ] **Step 5: Install a controller per pane in `registerPane`**

In `App/TmuxPaneContainer.swift`, in the pane-registration path (around line 200, where `view.allowMouseReporting = false` is set and pinch is attached), add after pinch is installed:

```swift
            // Replace SwiftTerm's built-in touch map with ours (per pane). Horizontal
            // drag switches tmux windows (clamped, one per drag); long-press zooms the
            // pane; tap places the cursor in this pane.
            let controller = TerminalGestureController(
                terminalView: view,
                callbacks: .init(
                    isMultiWindowTmux: { [weak self] in self?.onIsMultiWindowTmux() ?? false },
                    onSwitchWindow:    { [weak self] delta in self?.onSwitchWindow(delta) },
                    onLongPressZoom:   { [weak self] in self?.onZoomActivePane() },
                    onPlaceCursor:     { [weak self] col, row in self?.onPlaceCursor(view, col, row) },
                    mouseReportingActive: { view.allowMouseReporting }
                )
            )
            gestureControllers[key] = controller
            // Re-enable pinch after the controller's sweep disabled pre-existing recognizers.
            pinch.isEnabled = true
```

- [ ] **Step 6: Add controller storage + the callback closures to the coordinator**

In the same coordinator, add storage and closures (wired to the VM at container construction, mirroring the existing `onSelectWindow`/`send` closures):

```swift
        /// Per-pane gesture layer (replaces SwiftTerm's built-ins).
        private var gestureControllers: [ObjectIdentifier: TerminalGestureController] = [:]

        /// Callbacks supplied by the container/VM (set at construction).
        var onIsMultiWindowTmux: () -> Bool = { false }
        var onSwitchWindow: (Int) -> Void = { _ in }
        var onZoomActivePane: () -> Void = { }
        var onPlaceCursor: (TerminalView, Int, Int) -> Void = { _, _, _ in }
```

And in `removeHalo(from:)` (teardown), detach:

```swift
            gestureControllers[key]?.detach()
            gestureControllers[key] = nil
```

- [ ] **Step 7: Wire the container's callbacks to the VM**

Where `TmuxPaneContainer` is constructed in `SessionView.swift` (near `onSelect: { vm.selectWindow($0) }`), pass the new closures. Set on the coordinator in `makeUIView`/`updateUIView` (follow the existing pattern for how `onSelect`/`send` reach the coordinator):

```swift
        coordinator.onIsMultiWindowTmux = { [weak vm] in vm?.isMultiWindowTmux ?? false }
        coordinator.onSwitchWindow      = { [weak vm] delta in vm?.selectAdjacentWindowClamped(delta) }
        coordinator.onZoomActivePane    = { [weak vm] in vm?.zoomActivePane() }
        coordinator.onPlaceCursor       = { [weak vm] view, col, row in vm?.placeTmuxCursor(view, toCol: col, toRow: row) }
```

- [ ] **Step 8: Add `placeTmuxCursor` to the VM**

In `App/ConnectionViewModel.swift`:

```swift
    /// Single-tap cursor placement inside a tmux pane: emit arrow keys from the pane's
    /// current cursor to the tapped cell (reuses the pure encoders).
    func placeTmuxCursor(_ view: TerminalView, toCol: Int, toRow: Int) {
        let term = view.getTerminal()
        let cur = term.getCursorLocation()   // .x = col, .y = row
        let runs = cursorTapArrows(fromCol: cur.x, fromRow: cur.y,
                                   toCol: toCol, toRow: toRow)
        var bytes: [UInt8] = []
        for run in runs {
            let tail: [UInt8]
            switch run.direction {
            case .up: tail = [0x1b,0x5b,0x41]; case .down: tail = [0x1b,0x5b,0x42]
            case .right: tail = [0x1b,0x5b,0x43]; case .left: tail = [0x1b,0x5b,0x44]
            }
            bytes += Array(repeating: tail, count: run.count).flatMap { $0 }
        }
        guard !bytes.isEmpty else { return }
        sendTerminalInput(bytes)   // routes to the active pane via the existing tmux send path
    }
```

**Implementer note:** confirm `sendTerminalInput` targets the active pane in tmux mode; if tmux input must go through `tmux?.sendKeys(target:bytes:)` for a *specific* pane, route to the pane matching `view` (look up its `PaneID` via the existing `paneViews`/`paneLastTitles` reverse-lookup already used in `setTmuxTitle`).

- [ ] **Step 9: Commit**

```bash
git add App/ConnectionViewModel.swift App/TerminalScreen.swift App/TmuxPaneContainer.swift App/SessionView.swift
git commit -m "feat(app): wire TerminalGestureController into raw + tmux terminal mounts"
```

---

## Task 6: Push, verify on macOS CI, open PR

**Files:** none (CI + docs).

- [ ] **Step 1: Run the full Linux Kit suite (pure tasks) one more time**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS — `GestureClassifier` + `WindowNavigation` (incl. clamp) green; `CursorDragEngine` gone with no build break.

- [ ] **Step 2: Run `swift-format`/lint if the repo gates it**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test` already compiles Kit. (No Rust changed → no `cargo fmt` needed.)

- [ ] **Step 3: Push the branch and open the PR**

```bash
git push github feat/terminal-gesture-system
gh pr create --repo ds7n/semicolyn --title "feat: terminal gesture system (scroll / window-switch / cursor / select / zoom / menu)" --body "Replaces SwiftTerm's built-in terminal touch map with our own gesture layer. Pure deciders (GestureClassifier, clampedStepIndex) Linux-tested; App-tier TerminalGestureController wired into raw + tmux mounts. Supersedes the cursor-placement drag (tap retained; CursorDragEngine retired). Verified: Linux Kit green; App tier gated on macOS CI + device pass.

https://claude.ai/code/session_01VxDe5tUsrrkhgX9SSADJPp"
```

- [ ] **Step 4: Wait for macOS CI — the ONLY gate for the App tier**

Run: `gh run watch --repo ds7n/semicolyn` (or `gh run list --repo ds7n/semicolyn --limit 5`).
Expected: the `macos` job compiles `TerminalGestureController.swift` + both mounts. If it fails on a SwiftTerm API mismatch (e.g. `getCharData`, `buffer.x`, `disableMousePanGesture`), fix to the real 1.x signature (the pure logic is already proven) and re-push. This is the load-bearing risk from the spec — SwiftTerm recognizer disabling + selection API are only verifiable here.

- [ ] **Step 5: Update the decision log**

Edit `docs/brainstorming-decisions.md` §"Cursor placement": note the drag-to-scrub interaction is superseded by the gesture system (single-tap placement retained; `CursorDragEngine` retired). Commit:

```bash
git add docs/brainstorming-decisions.md
git commit -m "docs: cursor-placement drag superseded by terminal gesture system"
git push github feat/terminal-gesture-system
```

- [ ] **Step 6: Device pass (owed after CI green + merge → next TestFlight build)**

On device, verify: vertical drag scrolls; horizontal drag switches tmux windows (clamps at ends, one per drag); single tap places cursor; double-tap word-select + Copy menu; triple-tap line-select + Copy menu; long-press zooms the tmux pane (restores on second long-press); two-finger tap shows Copy/Paste menu; pinch still zooms; a `mouse=a` pane (vim) still forwards events. Record results in the session-resume memory.

---

## Self-Review

**Spec coverage** (each spec section → task):
- Gesture map (scroll / window-switch / tap / double / triple / long-press / two-finger / pinch) → Task 2 (classifier) + Task 4 (handlers) + Task 5 (wiring). Pinch unchanged (kept). ✓
- Architecture: pure deciders in SemicolynKit → Task 1 (`clampedStepIndex`) + Task 2 (`GestureClassifier`); thin App shell → Task 4/5. ✓
- Reuse `CursorArrowStream`/`cursorTapArrows` for single-tap → Task 4 `onPlaceCursor` + Task 5 `placeCursor`/`placeTmuxCursor`. ✓
- Retire `CursorDragEngine` → Task 3 (user-confirmed). ✓
- Mouse-reporting coexistence → Task 4 `mouseReportingActive` guard + `allowMouseReporting` reconciliation retained at mounts. ✓
- Error handling: no-other-window switch → `clampedStepIndex` returns `nil` (Task 1); single-pane zoom harmless (tmux no-op); empty-clipboard paste omitted (edit-menu delegate filters on `hasStrings`). ✓
- Testing: `GestureClassifier` EP+BVA+diagonal boundary (Task 2, 10 cases); `WindowNavigation` clamp EP+BVA+negatives (Task 1, 8 cases); App layer = macOS CI + device (Task 6). ✓
- Risks: disable-not-fight SwiftTerm recognizers (Task 4 sweep + public pan-disable; Task 5 re-enable pinch/restoreTap); selection API fallback noted (Task 4 implementer note). ✓
- Open items resolved: wrap-vs-clamp = **clamp** (Task 1); continuous-vs-commit = **one-per-drag on release** (Task 4 `handlePan`); CursorDragEngine = **retire** (Task 3); selection API = verified public `setSelectionRange` + word-bounds helper w/ fallback; two-finger-tap menu = kept. ✓

**Placeholder scan:** no "TBD"/"add error handling"/"similar to Task N" — each code step shows real code. Two implementer notes flag *verify-on-macOS-CI* adaptation points (SwiftTerm buffer-read API, existing arrow encoder reuse) — these are genuine "the exact 1.x signature is only knowable on macOS" seams, not placeholders; the logic they'd call is fully specified.

**Type consistency:** `clampedStepIndex(current:delta:count:) -> Int?` (Task 1) used identically in Task 5a. `PanGesture` cases `.none/.scrollVertical/.switchWindow(delta:)` (Task 2) matched in Task 4 `handlePan`. `TerminalGestureController.Callbacks` fields (Task 4) supplied 1:1 at both mounts (Task 5b/5c). `cursorTapArrows(fromCol:fromRow:toCol:toRow:)` (existing) called with those labels in Task 5. `ArrowRun.direction/.count` (existing) consumed by the encoders in Task 5.
