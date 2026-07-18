<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Finger-drag Window Transition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the release-triggered window-switch slide with a live finger-drag transition: the window tracks the finger during a horizontal swipe, reveals the adjacent window via a `capture-pane` snapshot, and commits the switch past a distance/velocity threshold (else springs back).

**Architecture:** Three pure Kit units (`DragAxisLock`, `WindowDragModel`, `SwitchCommitDecision`) own every threshold/geometry decision and are Linux-unit-tested. The App tier (`TerminalGestureController`, new `WindowSnapshotStore`, and the pane container coordinator) drives `paneContentView.transform` from those decisions and manages the off-screen snapshot views + the commit/timeout handoff. `WindowTransition` is removed.

**Tech Stack:** Swift 6 (strict concurrency, `Sendable`), XCTest (Kit, run in the `semicolyn-dev` Docker image), UIKit + SwiftTerm (App tier, macOS-CI / device only), tmux `-CC` control mode (`capture-pane`).

**Spec:** `docs/superpowers/specs/2026-07-18-finger-drag-window-transition-design.md`

## Global Constraints

- **Two tiers:** `Sources/SemicolynKit/` = pure logic, Linux-tested, Swift 6 strict-concurrency, `Sendable`, NO `import UIKit`/`SwiftUI`/`CryptoKit`. `App/` = Apple-only, macOS-CI-verified, does NOT compile on Linux / is invisible to `swift test`.
- **Every source file carries an SPDX header:** `// SPDX-FileCopyrightText: 2026 True Positive LLC` + `// SPDX-License-Identifier: GPL-3.0-only` (Swift). Markdown/docs use the `<!-- ... -->` form.
- **Tests must be real** (`docs/superpowers/specs/2026-06-18-testing-standards-design.md`): equivalence-partitioning + boundary values, assert observable values (no tautologies), a negative test asserts the *specific* failure.
- **Conventional commits** (`feat:`/`fix:`/`refactor:`/`docs:`).
- **Kit build/test command** (host has NO Swift toolchain): `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <TestClass>`.
- **No em-dashes** in any generated output (prose, code, comments, commit messages).
- **Direction convention (content-follows-finger, locked, matches shipped `windowSlideDirection`):** rightward swipe (`dx > 0`) selects the PREVIOUS window (`delta = -1`); leftward swipe selects the NEXT window (`delta = +1`).
- **Existing constants to reuse verbatim:** `deadZonePoints = 12`, `switchDominanceRatio = 1.7` (currently on `GestureClassifier`).
- **Kit tests live flat** in `Tests/SemicolynKitTests/` (not in subfolders).

---

## File Structure

**Kit (new, pure, tested):**
- `Sources/SemicolynKit/Terminal/DragAxisLock.swift` - at-dead-zone axis lock -> scroll / switch / pending.
- `Sources/SemicolynKit/Terminal/WindowDragModel.swift` - live translation -> clamped content offset + exposed-neighbor sign.
- `Sources/SemicolynKit/Terminal/SwitchCommitDecision.swift` - distance/velocity -> commit(delta) / springBack.

**Kit (modified):**
- `Sources/SemicolynKit/Terminal/GestureClassifier.swift` - reduced to shared constants reused by `DragAxisLock` (release-time `classify` removed).

**Kit tests (new):**
- `Tests/SemicolynKitTests/DragAxisLockTests.swift`
- `Tests/SemicolynKitTests/WindowDragModelTests.swift`
- `Tests/SemicolynKitTests/SwitchCommitDecisionTests.swift`

**App (new):**
- `App/WindowSnapshotStore.swift` - off-screen snapshot `TerminalView`s per window, fed by `capture-pane`.

**App (modified):**
- `App/TmuxRuntime.swift` - tag capture correlation ids by purpose (seed vs snapshot) so snapshot captures don't steal the seeder's `onHistoryCaptured`; add `captureSnapshot(pane:lines:)` + `onSnapshotCaptured`.
- `App/TerminalGestureController.swift` - live horizontal-drag path (drive transform, position snapshot, commit/spring on release); replace the release-time `GestureClassifier.classify` call.
- `App/TmuxPaneContainer.swift` - wire the snapshot store + commit handoff; remove the `WindowTransition` slide wiring; consume the finger-driven callbacks.
- `App/ConnectionViewModel.swift` - own the `WindowSnapshotStore`, refresh captures on connect + drag-start, expose window ordering/neighbors to the container.

**App (removed):**
- `App/WindowTransition.swift` - superseded.

---

## Task 1: `DragAxisLock` (Kit)

**Files:**
- Create: `Sources/SemicolynKit/Terminal/DragAxisLock.swift`
- Modify: `Sources/SemicolynKit/Terminal/GestureClassifier.swift` (reduce to shared constants)
- Test: `Tests/SemicolynKitTests/DragAxisLockTests.swift`

**Interfaces:**
- Consumes: nothing (pure).
- Produces:
  - `public enum DragAxis: Equatable, Sendable { case pending; case scroll; case switchWindow(delta: Int) }`
  - `public struct DragAxisLock: Sendable { public static let deadZonePoints: Double; public static let switchDominanceRatio: Double; public static func resolve(dx: Double, dy: Double, isMultiWindowTmux: Bool) -> DragAxis }`

- [ ] **Step 1: Write the failing test**

Create `Tests/SemicolynKitTests/DragAxisLockTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// At-dead-zone axis lock: inside dead-zone -> pending; vertical -> scroll;
/// clearly-horizontal in multi-window tmux -> switch; else scroll.
final class DragAxisLockTests: XCTestCase {
    private let dz = DragAxisLock.deadZonePoints

    // BVA: total movement below the dead-zone -> pending (not yet locked).
    func testSubDeadZoneIsPending() {
        XCTAssertEqual(DragAxisLock.resolve(dx: dz * 0.4, dy: dz * 0.4, isMultiWindowTmux: true),
                       .pending)
    }

    // BVA: just past the dead-zone on a pure vertical axis -> scroll.
    func testJustPastDeadZoneVerticalScrolls() {
        XCTAssertEqual(DragAxisLock.resolve(dx: 0, dy: dz + 0.1, isMultiWindowTmux: true),
                       .scroll)
    }

    // EP: clear rightward horizontal drag, multi-window -> PREVIOUS window (-1).
    func testHorizontalRightSwitchesPrev() {
        XCTAssertEqual(DragAxisLock.resolve(dx: dz + 40, dy: 2, isMultiWindowTmux: true),
                       .switchWindow(delta: -1))
    }

    // EP: clear leftward horizontal drag, multi-window -> NEXT window (+1).
    func testHorizontalLeftSwitchesNext() {
        XCTAssertEqual(DragAxisLock.resolve(dx: -(dz + 40), dy: 2, isMultiWindowTmux: true),
                       .switchWindow(delta: +1))
    }

    // EP: clearly-horizontal drag but NOT multi-window -> scroll (switch gated).
    func testHorizontalSingleWindowScrolls() {
        XCTAssertEqual(DragAxisLock.resolve(dx: dz + 40, dy: 2, isMultiWindowTmux: false),
                       .scroll)
    }

    // BVA: just BELOW the switch-dominance ratio -> scroll.
    func testJustBelowSwitchRatioScrolls() {
        let r = DragAxisLock.switchDominanceRatio
        XCTAssertEqual(DragAxisLock.resolve(dx: 30 * r - 3, dy: 30, isMultiWindowTmux: true),
                       .scroll)
    }

    // BVA: just ABOVE the switch-dominance ratio -> switch (rightward -> previous).
    func testJustAboveSwitchRatioSwitches() {
        let r = DragAxisLock.switchDominanceRatio
        XCTAssertEqual(DragAxisLock.resolve(dx: 30 * r + 3, dy: 30, isMultiWindowTmux: true),
                       .switchWindow(delta: -1))
    }

    // Constants match the shipped GestureClassifier values (no silent retune).
    func testConstantsMatchShippedValues() {
        XCTAssertEqual(DragAxisLock.deadZonePoints, 12)
        XCTAssertEqual(DragAxisLock.switchDominanceRatio, 1.7)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter DragAxisLockTests`
Expected: FAIL to compile ("cannot find 'DragAxisLock' in scope").

- [ ] **Step 3: Write the implementation**

Create `Sources/SemicolynKit/Terminal/DragAxisLock.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The axis a live terminal pan has locked to, decided ONCE when the finger first
/// leaves the dead-zone (unlike the release-time `GestureClassifier`, which classified
/// on `.ended`). A live finger-drag must know at that moment whether the window should
/// start tracking the finger (`.switchWindow`) or the drag should scroll (`.scroll`);
/// inside the dead-zone it is `.pending` (do not act yet). Fixed for the whole drag so a
/// single gesture never flips between scroll and switch mid-flight.
public enum DragAxis: Equatable, Sendable {
    case pending
    case scroll
    /// Content-follows-finger: rightward swipe (dx>0) -> previous window (-1),
    /// leftward -> next (+1). Matches `windowSlideDirection`.
    case switchWindow(delta: Int)
}

/// Pure axis-lock decision for a live terminal pan. Reuses the dead-zone radius and the
/// switch-dominance ratio (biased toward scroll, so a vertical scroll that drifts
/// sideways does not fling into the wrong window). Window-switch is gated on multi-window
/// tmux; every other drag scrolls.
public struct DragAxisLock: Sendable {
    /// Radius (points) the finger must travel (Euclidean) before the pan locks an axis.
    public static let deadZonePoints: Double = 12
    /// |dx| >= ratio * |dy| for a drag to count as a window switch rather than a scroll.
    public static let switchDominanceRatio: Double = 1.7

    public static func resolve(dx: Double, dy: Double, isMultiWindowTmux: Bool) -> DragAxis {
        guard (dx * dx + dy * dy) >= deadZonePoints * deadZonePoints else { return .pending }
        if isMultiWindowTmux, abs(dx) >= abs(dy) * switchDominanceRatio {
            return .switchWindow(delta: dx > 0 ? -1 : +1)
        }
        return .scroll
    }
}
```

- [ ] **Step 4: Reduce `GestureClassifier` to shared constants**

The release-time `classify`/`PanGesture` are superseded by `DragAxisLock`. Its call site
(`TerminalGestureController.resolveWindowSwitch`) is removed in Task 6, so delete the
release-time API now and keep only what other code still references. Replace the entire
body of `Sources/SemicolynKit/Terminal/GestureClassifier.swift` with:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Shared terminal-pan tuning constants. The release-time `classify` classifier this
/// file once held is superseded by `DragAxisLock` (at-dead-zone lock for the live
/// finger-drag transition). These constants are kept as the single source both the live
/// lock and any future gesture code read from.
public enum GestureTuning {
    /// Radius (points) the finger must travel before a pan is classified.
    public static let deadZonePoints: Double = 12
    /// |dx| >= ratio * |dy| for a horizontal drag to count as a window switch.
    public static let switchDominanceRatio: Double = 1.7
}
```

Then delete `Tests/SemicolynKitTests/GestureClassifierTests.swift` (it tests the removed
`classify`; `DragAxisLockTests` covers the replacement).

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift build 2>&1 | grep -i "GestureClassifier\|PanGesture" || echo "no lingering references"`
Expected: `no lingering references` (nothing else in Kit imports `classify`/`PanGesture`; App references are removed in Task 6). If a Kit reference appears, it is only `GestureSimultaneityTests`/`WindowSlideTests` which do not use `classify` - confirm and move on.

- [ ] **Step 5: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter DragAxisLockTests`
Expected: PASS (8 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/SemicolynKit/Terminal/DragAxisLock.swift \
        Sources/SemicolynKit/Terminal/GestureClassifier.swift \
        Tests/SemicolynKitTests/DragAxisLockTests.swift
git rm Tests/SemicolynKitTests/GestureClassifierTests.swift
git commit -m "feat(terminal): DragAxisLock at-dead-zone axis lock (replaces release-time classify)"
```

---

## Task 2: `WindowDragModel` (Kit)

**Files:**
- Create: `Sources/SemicolynKit/Terminal/WindowDragModel.swift`
- Test: `Tests/SemicolynKitTests/WindowDragModelTests.swift`

**Interfaces:**
- Consumes: nothing (pure).
- Produces:
  - `public enum ExposedNeighbor: Equatable, Sendable { case none; case previous; case next }`
  - `public struct WindowDragModel: Sendable`
    - `public static func offset(dx: Double, width: Double) -> Double` - clamped/rubber-banded content translation.
    - `public static func exposedNeighbor(dx: Double) -> ExposedNeighbor` - which neighbor the gap reveals (by sign).

- [ ] **Step 1: Write the failing test**

Create `Tests/SemicolynKitTests/WindowDragModelTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Live-drag geometry: translation -> clamped content offset (rubber-band past +/-width),
/// and which neighbor the exposed gap reveals (by drag-direction sign).
final class WindowDragModelTests: XCTestCase {
    private let width = 400.0

    // EP: no drag -> no offset (identity).
    func testZeroDragIsIdentity() {
        XCTAssertEqual(WindowDragModel.offset(dx: 0, width: width), 0, accuracy: 0.0001)
    }

    // EP: mid-drag within bounds passes through unchanged.
    func testMidDragPassesThrough() {
        XCTAssertEqual(WindowDragModel.offset(dx: 120, width: width), 120, accuracy: 0.0001)
    }

    // BVA: at exactly +width the content is fully off (fully reveals prev on the left).
    func testAtWidthIsFullyRevealed() {
        XCTAssertEqual(WindowDragModel.offset(dx: width, width: width), width, accuracy: 0.0001)
    }

    // BVA: past +width rubber-bands (moves less than 1:1, stays below 2*width).
    func testPastWidthRubberBands() {
        let o = WindowDragModel.offset(dx: width + 200, width: width)
        XCTAssertGreaterThan(o, width)            // still past the edge
        XCTAssertLessThan(o, width + 200)          // but resisted (rubber-band)
        XCTAssertLessThan(o, 2 * width)            // never runs away
    }

    // Symmetry: past -width rubber-bands the same way on the negative side.
    func testPastNegativeWidthRubberBands() {
        let o = WindowDragModel.offset(dx: -(width + 200), width: width)
        XCTAssertLessThan(o, -width)
        XCTAssertGreaterThan(o, -(width + 200))
    }

    // Exposed neighbor: rightward drag (dx>0) reveals the PREVIOUS window.
    func testRightDragExposesPrevious() {
        XCTAssertEqual(WindowDragModel.exposedNeighbor(dx: 50), .previous)
    }

    // Exposed neighbor: leftward drag (dx<0) reveals the NEXT window.
    func testLeftDragExposesNext() {
        XCTAssertEqual(WindowDragModel.exposedNeighbor(dx: -50), .next)
    }

    // Exposed neighbor: no horizontal drag reveals nothing.
    func testZeroDragExposesNone() {
        XCTAssertEqual(WindowDragModel.exposedNeighbor(dx: 0), .none)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter WindowDragModelTests`
Expected: FAIL to compile ("cannot find 'WindowDragModel' in scope").

- [ ] **Step 3: Write the implementation**

Create `Sources/SemicolynKit/Terminal/WindowDragModel.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Which adjacent window the exposed gap reveals during a live horizontal drag.
public enum ExposedNeighbor: Equatable, Sendable {
    case none
    case previous   // rightward drag (dx > 0): content-follows-finger reveals the window to the left
    case next       // leftward drag (dx < 0)
}

/// Pure geometry for the live finger-drag window transition. Maps the pan's horizontal
/// translation to the content view's visual offset (identity at rest, clamped/rubber-
/// banded past a full window width so an over-drag past the edge windows resists instead
/// of running off), and reports which neighbor the resulting gap exposes.
public struct WindowDragModel: Sendable {
    /// Resistance applied to over-drag past +/- one window width (0 = free, 1 = locked).
    /// 0.5 gives the standard iOS rubber-band feel.
    private static let rubberBandResistance: Double = 0.5

    /// Content translation (points) for a drag of `dx` over a pane of `width`. Within
    /// +/-width it is `dx` unchanged; past the edge it moves at reduced rate so an
    /// over-drag past the first/last-revealed window resists (rubber-band) and never
    /// exceeds ~2*width.
    public static func offset(dx: Double, width: Double) -> Double {
        guard width > 0 else { return 0 }
        if abs(dx) <= width { return dx }
        let over = abs(dx) - width
        let resisted = width + over * rubberBandResistance
        return dx > 0 ? resisted : -resisted
    }

    /// The neighbor the exposed gap reveals, by drag-direction sign (content-follows-
    /// finger). No horizontal movement reveals nothing.
    public static func exposedNeighbor(dx: Double) -> ExposedNeighbor {
        if dx > 0 { return .previous }
        if dx < 0 { return .next }
        return .none
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter WindowDragModelTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Terminal/WindowDragModel.swift \
        Tests/SemicolynKitTests/WindowDragModelTests.swift
git commit -m "feat(terminal): WindowDragModel live-drag offset + exposed-neighbor geometry"
```

---

## Task 3: `SwitchCommitDecision` (Kit)

**Files:**
- Create: `Sources/SemicolynKit/Terminal/SwitchCommitDecision.swift`
- Test: `Tests/SemicolynKitTests/SwitchCommitDecisionTests.swift`

**Interfaces:**
- Consumes: nothing (pure).
- Produces:
  - `public enum SwitchOutcome: Equatable, Sendable { case commit(delta: Int); case springBack }`
  - `public struct SwitchCommitDecision: Sendable`
    - `public static let distanceFraction: Double` (0.4)
    - `public static let velocityThreshold: Double` (points/sec)
    - `public static func resolve(dx: Double, width: Double, velocity: Double) -> SwitchOutcome`

- [ ] **Step 1: Write the failing test**

Create `Tests/SemicolynKitTests/SwitchCommitDecisionTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Release decision: commit the switch if dragged past the distance fraction OR flicked
/// past the velocity threshold; otherwise spring back. Direction sign is content-follows-
/// finger (rightward -> previous / -1, leftward -> next / +1).
final class SwitchCommitDecisionTests: XCTestCase {
    private let width = 400.0
    private let vel0 = 0.0   // no flick

    // EP: short slow drag (below distance, no velocity) -> spring back.
    func testShortSlowDragSpringsBack() {
        XCTAssertEqual(SwitchCommitDecision.resolve(dx: 40, width: width, velocity: vel0),
                       .springBack)
    }

    // EP: dragged well past the distance fraction, rightward -> commit PREVIOUS (-1).
    func testPastDistanceRightCommitsPrev() {
        XCTAssertEqual(SwitchCommitDecision.resolve(dx: 0.6 * width, width: width, velocity: vel0),
                       .commit(delta: -1))
    }

    // EP: dragged well past the distance fraction, leftward -> commit NEXT (+1).
    func testPastDistanceLeftCommitsNext() {
        XCTAssertEqual(SwitchCommitDecision.resolve(dx: -0.6 * width, width: width, velocity: vel0),
                       .commit(delta: +1))
    }

    // Distance-or-velocity: a SHORT but FAST leftward flick still commits NEXT (+1).
    func testShortFastFlickCommits() {
        let v = SwitchCommitDecision.velocityThreshold + 100   // clearly past
        XCTAssertEqual(SwitchCommitDecision.resolve(dx: -0.1 * width, width: width, velocity: -v),
                       .commit(delta: +1))
    }

    // BVA: just BELOW the distance fraction with no flick -> spring back.
    func testJustBelowDistanceSpringsBack() {
        let dx = SwitchCommitDecision.distanceFraction * width - 1
        XCTAssertEqual(SwitchCommitDecision.resolve(dx: dx, width: width, velocity: vel0),
                       .springBack)
    }

    // BVA: just ABOVE the distance fraction (rightward) -> commit previous (-1).
    func testJustAboveDistanceCommits() {
        let dx = SwitchCommitDecision.distanceFraction * width + 1
        XCTAssertEqual(SwitchCommitDecision.resolve(dx: dx, width: width, velocity: vel0),
                       .commit(delta: -1))
    }

    // A flick BELOW the velocity threshold AND below distance -> spring back (neither trips).
    func testSlowShortDragBelowBothSpringsBack() {
        let v = SwitchCommitDecision.velocityThreshold - 50
        XCTAssertEqual(SwitchCommitDecision.resolve(dx: -20, width: width, velocity: -v),
                       .springBack)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter SwitchCommitDecisionTests`
Expected: FAIL to compile ("cannot find 'SwitchCommitDecision' in scope").

- [ ] **Step 3: Write the implementation**

Create `Sources/SemicolynKit/Terminal/SwitchCommitDecision.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The result of releasing a live window-switch drag.
public enum SwitchOutcome: Equatable, Sendable {
    /// Commit the switch by `delta` (rightward release -> previous / -1, leftward -> next / +1).
    case commit(delta: Int)
    /// Snap the current window back (drag too short and not flicked).
    case springBack
}

/// Pure release decision for the live finger-drag window switch. Commit if the drag
/// travelled past `distanceFraction` of the pane width OR was released with speed past
/// `velocityThreshold` (a short fast flick still switches, matching iOS paging); else
/// spring back. Direction is content-follows-finger.
public struct SwitchCommitDecision: Sendable {
    /// Fraction of pane width the drag must pass to commit on distance alone.
    public static let distanceFraction: Double = 0.4
    /// Release speed (points/sec, absolute) that commits regardless of distance.
    public static let velocityThreshold: Double = 500

    public static func resolve(dx: Double, width: Double, velocity: Double) -> SwitchOutcome {
        guard width > 0, dx != 0 else { return .springBack }
        let pastDistance = abs(dx) >= distanceFraction * width
        // Only a flick IN THE DRAG DIRECTION counts (sign agreement); a fast bounce-back
        // in the opposite direction must not commit.
        let flicked = abs(velocity) >= velocityThreshold && (velocity < 0) == (dx < 0)
        guard pastDistance || flicked else { return .springBack }
        return .commit(delta: dx > 0 ? -1 : +1)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter SwitchCommitDecisionTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Run the full Kit suite (regression)**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS (all existing tests + the 3 new files; `GestureClassifierTests` gone).

- [ ] **Step 6: Commit**

```bash
git add Sources/SemicolynKit/Terminal/SwitchCommitDecision.swift \
        Tests/SemicolynKitTests/SwitchCommitDecisionTests.swift
git commit -m "feat(terminal): SwitchCommitDecision distance-or-velocity commit rule"
```

---

## Task 4: Snapshot capture routing in `TmuxRuntime` (App)

**Why:** `capture-pane` replies currently route through the single `onHistoryCaptured` closure, owned by `PaneHistorySeeder`. The snapshot store needs its OWN capture bytes without stealing the seeder's. Tag each in-flight capture by purpose so the reply fans out to the right consumer.

**Files:**
- Modify: `App/TmuxRuntime.swift`
- Test: none (App tier - not Linux-buildable; validated by macOS CI compile + device). Kit stays green.

**Interfaces:**
- Consumes: existing `writeTracked`, `capturePaneCommand`, `reconstructHistory`.
- Produces (new on `TmuxRuntime`):
  - `var onSnapshotCaptured: ((PaneID, [UInt8]) -> Void)?`
  - `@discardableResult func captureSnapshot(pane: PaneID, lines: Int) -> UInt64?`

- [ ] **Step 1: Tag the capture correlation map by purpose**

In `App/TmuxRuntime.swift`, replace the seed-only correlation map:

```swift
    /// Correlation ids for in-flight `capture-pane` history seeds, keyed to the pane.
    private var historyCaptureIDs: [UInt64: PaneID] = [:]
```

with a purpose-tagged map (keep the seed callback name for zero churn in the seeder):

```swift
    /// Purpose of an in-flight `capture-pane`: a scrollback SEED (feeds `PaneHistorySeeder`
    /// via `onHistoryCaptured`) or a window-transition SNAPSHOT (feeds `WindowSnapshotStore`
    /// via `onSnapshotCaptured`). Tagged so one reply routes to exactly one consumer.
    private enum CapturePurpose { case seed, snapshot }
    /// Correlation ids for in-flight `capture-pane` requests, keyed to (pane, purpose).
    private var captureIDs: [UInt64: (pane: PaneID, purpose: CapturePurpose)] = [:]
```

- [ ] **Step 2: Add the snapshot callback next to `onHistoryCaptured`**

Directly after the `var onHistoryCaptured: ((PaneID, [UInt8]) -> Void)?` declaration, add:

```swift
    /// Fired when a SNAPSHOT capture resolves: (pane, reconstructed bytes). Consumed by
    /// `WindowSnapshotStore` to render an off-screen preview of a non-active window.
    var onSnapshotCaptured: ((PaneID, [UInt8]) -> Void)?
```

- [ ] **Step 3: Update the reply-routing branch**

In `ingest(_:)`, replace the seed-reply branch:

```swift
            } else if let pane = historyCaptureIDs.removeValue(forKey: resolved.id) {
                if case .ok(let lines) = resolved.outcome {
                    let bytes = reconstructHistory(fromLines: lines)
                    DebugLog.shared.log(.tmux, "tmux capture REPLY: pane=%\(pane.raw) lines=\(lines.count) bytes=\(bytes.count)")
                    onHistoryCaptured?(pane, bytes)
                } else {
                    DebugLog.shared.log(.tmux, "tmux capture REPLY: pane=%\(pane.raw) NOT .ok (capture errored)")
                    onHistoryCaptured?(pane, [])
                }
            }
```

with the purpose-aware version:

```swift
            } else if let entry = captureIDs.removeValue(forKey: resolved.id) {
                let bytes: [UInt8]
                if case .ok(let lines) = resolved.outcome {
                    bytes = reconstructHistory(fromLines: lines)
                    DebugLog.shared.log(.tmux, "tmux capture REPLY: pane=%\(entry.pane.raw) purpose=\(entry.purpose) lines=\(lines.count) bytes=\(bytes.count)")
                } else {
                    bytes = []
                    DebugLog.shared.log(.tmux, "tmux capture REPLY: pane=%\(entry.pane.raw) purpose=\(entry.purpose) NOT .ok (capture errored)")
                }
                switch entry.purpose {
                case .seed:     onHistoryCaptured?(entry.pane, bytes)   // seed fails toward live-only ([])
                case .snapshot: onSnapshotCaptured?(entry.pane, bytes)
                }
            }
```

- [ ] **Step 4: Update `captureHistory` + add `captureSnapshot`**

Replace `captureHistory`:

```swift
    func captureHistory(pane: PaneID, lines: Int) -> UInt64? {
        guard let cmd = capturePaneCommand(paneID: pane, lines: lines),
              let id = writeTracked(cmd) else { return nil }
        historyCaptureIDs[id] = pane
        DebugLog.shared.log(.tmux, "tmux capture: pane=%\(pane.raw) lines=\(lines) id=\(id)")
        return id
    }
```

with:

```swift
    func captureHistory(pane: PaneID, lines: Int) -> UInt64? {
        guard let cmd = capturePaneCommand(paneID: pane, lines: lines),
              let id = writeTracked(cmd) else { return nil }
        captureIDs[id] = (pane, .seed)
        DebugLog.shared.log(.tmux, "tmux capture: pane=%\(pane.raw) purpose=seed lines=\(lines) id=\(id)")
        return id
    }

    /// Send a `capture-pane` for the window-transition SNAPSHOT of `pane` (which may be in
    /// a NON-active window). Reply routes to `onSnapshotCaptured`. No-op / nil if seeding
    /// is disabled (lines <= 0) or not attached.
    @discardableResult
    func captureSnapshot(pane: PaneID, lines: Int) -> UInt64? {
        guard let cmd = capturePaneCommand(paneID: pane, lines: lines),
              let id = writeTracked(cmd) else { return nil }
        captureIDs[id] = (pane, .snapshot)
        DebugLog.shared.log(.tmux, "tmux capture: pane=%\(pane.raw) purpose=snapshot lines=\(lines) id=\(id)")
        return id
    }
```

- [ ] **Step 5: Verify Kit still builds/tests (no App regressions reach Linux)**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS (App changes are invisible to Linux; this confirms nothing Kit-side broke).

- [ ] **Step 6: Commit**

```bash
git add App/TmuxRuntime.swift
git commit -m "feat(terminal): tag capture-pane replies by purpose (seed vs snapshot)"
```

---

## Task 5: `WindowSnapshotStore` (App)

**Why:** Owns one off-screen `TerminalView` per tmux window, fed by `captureSnapshot`, so the live drag can reveal a real preview of the adjacent window.

**Files:**
- Create: `App/WindowSnapshotStore.swift`
- Modify: `App/ConnectionViewModel.swift` (own the store; refresh on connect + drag-start; expose neighbors)
- Test: none (App tier); Kit stays green.

**Interfaces:**
- Consumes: `TmuxRuntime.captureSnapshot(pane:lines:)`, `TmuxRuntime.onSnapshotCaptured`, `TmuxSessionState` (`windows`, `activeWindow`, `window(_:)`, `visibleLayout`), `WindowID`, `PaneID`, `PaneRect`, SwiftTerm `TerminalView`.
- Produces (on `WindowSnapshotStore`):
  - `init(runtime: TmuxRuntime, scrollbackLines: @escaping () -> Int, makeSnapshotView: @escaping (PaneID) -> TerminalView)`
  - `func refreshNonActive(state: TmuxSessionState)` - fire `captureSnapshot` for every pane in every NON-active window.
  - `func snapshotView(for window: WindowID) -> UIView?` - a container UIView hosting that window's pane snapshot view(s), or nil if not captured yet.
  - `func rebuild(state: TmuxSessionState)` - drop views for closed windows, invalidate generations on a window-list change.

- [ ] **Step 1: Write the implementation**

Create `App/WindowSnapshotStore.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SwiftTerm
import SemicolynKit

/// Off-screen `capture-pane` snapshots of tmux windows, so the live finger-drag window
/// transition can reveal a real preview of an adjacent window (whose live panes do not
/// exist locally under `-CC` until the switch commits). One hosting `UIView` per window;
/// each holds a SwiftTerm `TerminalView` per pane, positioned from the window's
/// `visibleLayout`. Fed by `TmuxRuntime.captureSnapshot` -> `onSnapshotCaptured`.
///
/// A per-pane `generation` counter drops a late reply for a pane whose window was closed
/// or re-captured, so stale bytes never land in the wrong view.
@MainActor
final class WindowSnapshotStore {
    private let runtime: TmuxRuntime
    private let scrollbackLines: () -> Int
    private let makeSnapshotView: (PaneID) -> TerminalView

    /// Hosting container per window (holds that window's pane snapshot views).
    private var windowViews: [WindowID: UIView] = [:]
    /// The snapshot TerminalView per pane, and which window it belongs to.
    private var paneViews: [PaneID: TerminalView] = [:]
    private var paneWindow: [PaneID: WindowID] = [:]
    /// Monotonic capture generation per pane; a reply is applied only if it matches.
    private var generation: [PaneID: Int] = [:]

    init(runtime: TmuxRuntime,
         scrollbackLines: @escaping () -> Int,
         makeSnapshotView: @escaping (PaneID) -> TerminalView) {
        self.runtime = runtime
        self.scrollbackLines = scrollbackLines
        self.makeSnapshotView = makeSnapshotView
        runtime.onSnapshotCaptured = { [weak self] pane, bytes in
            self?.applyCapture(pane, bytes)
        }
    }

    /// Fire a fresh `capture-pane` for every pane in every NON-active window. Called on
    /// connect and at each drag-start. The active window is already live, so it is skipped.
    func refreshNonActive(state: TmuxSessionState) {
        let lines = scrollbackLines()
        guard lines > 0 else { return }
        for window in state.windows where window.id != state.activeWindow {
            // `visibleLayout?.panes` yields (pane: PaneID, geometry: Geometry) leaves.
            for leaf in window.visibleLayout?.panes ?? [] {
                bumpGeneration(leaf.pane, window: window.id)
                runtime.captureSnapshot(pane: leaf.pane, lines: lines)
            }
        }
    }

    /// Drop hosting views for windows that no longer exist; invalidate their generations
    /// so any in-flight reply is ignored. Called on a window-list change.
    func rebuild(state: TmuxSessionState) {
        let live = Set(state.windows.map(\.id))
        for (win, view) in windowViews where !live.contains(win) {
            view.removeFromSuperview()
            windowViews[win] = nil
        }
        let livePanes = Set(state.windows.flatMap { win in
            (win.visibleLayout?.panes ?? []).map { $0.pane }
        })
        for pane in paneViews.keys where !livePanes.contains(pane) {
            paneViews[pane] = nil
            paneWindow[pane] = nil
            generation[pane] = (generation[pane] ?? 0) + 1   // invalidate in-flight
        }
    }

    /// The hosting view for `window`'s snapshot, or nil if nothing captured yet.
    func snapshotView(for window: WindowID) -> UIView? { windowViews[window] }

    private func bumpGeneration(_ pane: PaneID, window: WindowID) {
        generation[pane] = (generation[pane] ?? 0) + 1
        paneWindow[pane] = window
    }

    /// Apply a snapshot capture reply: feed the bytes into the pane's snapshot TerminalView,
    /// creating the view + its window host on first sight. Ignores a pane whose window is
    /// gone (dropped in `rebuild`).
    private func applyCapture(_ pane: PaneID, _ bytes: [UInt8]) {
        guard let window = paneWindow[pane] else { return }   // pane retired
        let host = windowViews[window] ?? {
            let v = UIView(); windowViews[window] = v; return v
        }()
        let view = paneViews[pane] ?? {
            let v = makeSnapshotView(pane)
            paneViews[pane] = v
            host.addSubview(v)
            return v
        }()
        // A snapshot view is a fresh, never-live preview and each capture REPLACES the
        // whole buffer, so a full clear before feeding is correct here (unlike the live
        // seeder, which must preserve the on-screen content and instead feeds ESC[3J).
        // Clear via the scrollback-erase escape (`feed` is the confirmed public path;
        // `feed(byteArray:)` is used by PaneHistorySeeder). Feeding a full capture over a
        // cleared buffer yields the previewed screen.
        view.feed(byteArray: [0x1b, 0x5b, 0x33, 0x4a][...])   // ESC [ 3 J (erase scrollback)
        if !bytes.isEmpty { view.feed(byteArray: bytes[...]) }
        DebugLog.shared.log(.seed, "snapshot applied pane=%\(pane.raw) win=@\(window.raw) bytes=\(bytes.count)")
    }

    /// Lay out `window`'s pane snapshot views inside its host at `bounds`, using the pane
    /// rects from `state`. Call right before revealing the host in the drag gap so the
    /// snapshot matches the current container geometry.
    func layout(window: WindowID, in state: TmuxSessionState, bounds: CGRect,
                cellWidth: Double, cellHeight: Double) {
        guard let host = windowViews[window], let win = state.window(window),
              let layout = win.visibleLayout else { return }
        host.frame = bounds
        // Reuse the same Kit helper the live container uses to place panes: it maps each
        // leaf's cell geometry to a pixel rect (top-left origin) via the cell metrics.
        for rect in paneRects(in: layout, cellWidth: cellWidth, cellHeight: cellHeight) {
            guard let view = paneViews[rect.pane] else { continue }
            view.frame = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        }
    }
}
```

> **Grounded (already verified against source):** `visibleLayout?.panes` yields
> `(pane: PaneID, geometry: Geometry)` leaves (`geometry` is `w/h/x/y: UInt16` in CELLS);
> the pixel-rect placement reuses the Kit free function
> `paneRects(in: PaneLayout, cellWidth:cellHeight:) -> [PaneRect]` (members `pane`, `x`,
> `y`, `width`, `height`, in pixels), the SAME helper the live container uses. Do NOT
> hand-roll cell math.
> **Grounded:** `TerminalView.feed(byteArray:)` is the confirmed public feed path
> (`PaneHistorySeeder.applyHistory` uses `view.feed(byteArray: flush[...])`). Clearing a
> snapshot view before re-feeding uses the same `ESC [ 3 J` scrollback-erase escape
> `PaneHistorySeeder.clearScrollback` feeds - no direct `resetToInitialState()` call needed.

- [ ] **Step 2: Own the store in `ConnectionViewModel` + refresh on connect**

In `App/ConnectionViewModel.swift`, near the `historySeeder` property, add:

```swift
    /// Off-screen capture-pane snapshots of non-active windows for the finger-drag
    /// window transition.
    private(set) var snapshotStore: WindowSnapshotStore?
```

Where the tmux runtime + seeder are constructed (search for `historySeeder =` /
`PaneHistorySeeder(`), construct the store alongside, reusing the same scrollback source
the seeder uses:

```swift
        snapshotStore = WindowSnapshotStore(
            runtime: tmux,
            scrollbackLines: { [weak self] in self?.scrollbackLines() ?? 0 },
            makeSnapshotView: { _ in
                let v = TerminalView(frame: .zero)
                v.isUserInteractionEnabled = false   // a static preview, never interactive
                return v
            })
```

> **Verify:** confirm the exact name of the seeder's scrollback closure (grep
> `scrollbackLines` in `ConnectionViewModel.swift` / `PaneHistorySeeder.swift`). Reuse it so
> the snapshot uses the same N as the live seed. If it is a different symbol, call that.

Then, at the point the seeder first learns the state (search where `onStateChanged` is
handled in the VM, around the `tmux:activeWindow=` log), call the store so it prunes closed
windows and seeds the initial snapshots:

```swift
            snapshotStore?.rebuild(state: state)
            snapshotStore?.refreshNonActive(state: state)
```

- [ ] **Step 3: Verify Kit still builds/tests**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS (App changes invisible to Linux).

- [ ] **Step 4: Commit**

```bash
git add App/WindowSnapshotStore.swift App/ConnectionViewModel.swift
git commit -m "feat(terminal): WindowSnapshotStore off-screen capture-pane window previews"
```

---

## Task 6: Live drag path in `TerminalGestureController` (App)

**Why:** Turn the horizontal drag into a live transform of `paneContentView`, replacing the release-time `GestureClassifier.classify` one-shot. Emit new callbacks the container wires in Task 7.

**Files:**
- Modify: `App/TerminalGestureController.swift`
- Test: none (App tier); Kit stays green.

**Interfaces:**
- Consumes: `DragAxisLock`, `WindowDragModel`, `SwitchCommitDecision`, `ExposedNeighbor`.
- Produces (new `Callbacks` fields, consumed in Task 7):
  - `let onDragBeginSwitch: () -> Void` - drag locked to the switch axis (container refreshes snapshots + prepares reveal).
  - `let onDragUpdate: (_ offset: Double, _ exposed: ExposedNeighbor) -> Void` - each `.changed`.
  - `let onDragCommit: (_ delta: Int) -> Void` - release past threshold.
  - `let onDragCancel: () -> Void` - release short (spring back).

- [ ] **Step 1: Add the four new callback fields**

In the `Callbacks` struct, alongside `onSwitchWindow`, add:

```swift
        /// The horizontal drag has locked to the window-switch axis: prepare the reveal
        /// (refresh non-active snapshots, position the neighbor host). Fires once per drag.
        let onDragBeginSwitch: () -> Void
        /// Live update on each `.changed` while switch-locked: content `offset` (points)
        /// and which neighbor the gap exposes.
        let onDragUpdate: (_ offset: Double, _ exposed: ExposedNeighbor) -> Void
        /// Release PAST threshold: commit the switch by `delta` (container runs the settle
        /// animation + tmux select-window + handoff).
        let onDragCommit: (_ delta: Int) -> Void
        /// Release SHORT: spring the current window back (no tmux command).
        let onDragCancel: () -> Void
```

- [ ] **Step 2: Add live-drag snapshot state**

Alongside `dragMode` / `emittedCells`, add:

```swift
    /// Axis this drag locked to (decided once past the dead-zone). `.pending` until then.
    private var dragAxis: DragAxis = .pending
    /// True once we have fired `onDragBeginSwitch` for this drag (switch axis only).
    private var switchRevealStarted = false
```

- [ ] **Step 3: Reset the new state in `beginDrag`**

In `beginDrag(_:on:)`, after `emittedCells = 0`, add:

```swift
        dragAxis = .pending
        switchRevealStarted = false
```

- [ ] **Step 4: Drive the live switch from BOTH pan handlers**

Both `handleScrollViewPan` and `handleAltScreenPan` must first give the horizontal drag a
chance to lock to the switch axis (mode coverage: switch works in all modes). Add a shared
helper and call it from each handler's `.changed`, plus resolve commit/cancel on `.ended`.

Add this helper method:

```swift
    /// Feed the drag's cumulative translation through the axis lock. Returns true if this
    /// drag is (now) switch-locked and the caller should NOT run its scroll/arrow path.
    /// On the first switch-lock it fires `onDragBeginSwitch`; every `.changed` after fires
    /// `onDragUpdate` with the clamped offset + exposed neighbor.
    private func driveLiveSwitch(_ g: UIPanGestureRecognizer, in view: TerminalView) -> Bool {
        let t = g.translation(in: view)
        if case .pending = dragAxis {
            dragAxis = DragAxisLock.resolve(dx: Double(t.x), dy: Double(t.y),
                                            isMultiWindowTmux: callbacks.isMultiWindowTmux())
        }
        guard case .switchWindow = dragAxis else { return false }
        if !switchRevealStarted {
            switchRevealStarted = true
            callbacks.onDragBeginSwitch()
            DebugLog.shared.log(.gesture, "drag-switch begin dx=\(Int(t.x))")
        }
        let width = Double(view.bounds.width)
        let offset = WindowDragModel.offset(dx: Double(t.x), width: width)
        callbacks.onDragUpdate(offset, WindowDragModel.exposedNeighbor(dx: Double(t.x)))
        return true
    }

    /// Resolve commit-vs-spring on release for a switch-locked drag. Returns true if this
    /// was a switch drag (so the caller skips its own window-switch resolution).
    private func resolveLiveSwitch(_ g: UIPanGestureRecognizer, in view: TerminalView) -> Bool {
        guard case .switchWindow = dragAxis else { return false }
        let t = g.translation(in: view)
        let v = g.velocity(in: view)
        let width = Double(view.bounds.width)
        switch SwitchCommitDecision.resolve(dx: Double(t.x), width: width, velocity: Double(v.x)) {
        case .commit(let delta):
            DebugLog.shared.log(.gesture, "drag-switch commit delta=\(delta) dx=\(Int(t.x)) vx=\(Int(v.x))")
            callbacks.onDragCommit(delta)
        case .springBack:
            DebugLog.shared.log(.gesture, "drag-switch cancel dx=\(Int(t.x)) vx=\(Int(v.x))")
            callbacks.onDragCancel()
        }
        return true
    }
```

In `handleScrollViewPan`, change `.began`/`.changed`/`.ended`:

```swift
    @objc private func handleScrollViewPan(_ g: UIPanGestureRecognizer) {
        guard let view = terminalView else { return }
        switch g.state {
        case .began:
            beginDrag("scrollPan", on: view)
        case .changed:
            // Give the horizontal drag first refusal at the switch axis; if it locks to
            // switch, the native scroll is suppressed for this drag (we drive the transform).
            _ = driveLiveSwitch(g, in: view)
        case .ended, .cancelled:
            if resolveLiveSwitch(g, in: view) { return }   // switch drag handled
            DebugLog.shared.log(.gesture,
                "drag-end owner=scrollPan imode=\(dragMode) outcome=\(dragMode == .localScroll ? "scroll" : "none")")
        default: break
        }
    }
```

> Note: the native scroll pan still scrolls vertically on its own; when `driveLiveSwitch`
> returns true we simply also drive the horizontal transform. A pure-vertical drag never
> locks to switch (`DragAxisLock` returns `.scroll`), so scrolling is unaffected. We no
> longer call `resolveWindowSwitch` here.

In `handleAltScreenPan`, insert the live-switch check at the TOP of `.changed` and `.ended`:

```swift
        case .changed:
            if driveLiveSwitch(g, in: view) { return }   // horizontal switch owns this drag
            guard dragMode == .appOwnsInput else { return }
            // ... existing wheel/arrow emission unchanged ...
```

```swift
        case .ended, .cancelled:
            if resolveLiveSwitch(g, in: view) { return }  // switch drag handled
            // ... existing emitted-cells outcome log unchanged, but delete the trailing
            //     resolveWindowSwitch(g, in: view) call ...
```

- [ ] **Step 5: Remove the dead release-time switch resolver**

Delete the `resolveWindowSwitch(_:in:)` method entirely (its only callers were the two
`.ended` branches, now replaced by `resolveLiveSwitch`). Confirm no remaining reference:

Run: `grep -n "resolveWindowSwitch\|GestureClassifier\|PanGesture" App/TerminalGestureController.swift`
Expected: no matches.

- [ ] **Step 6: Verify Kit still builds/tests**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add App/TerminalGestureController.swift
git commit -m "feat(terminal): live finger-drag switch path (axis-lock + transform + commit)"
```

---

## Task 7: Commit handoff + remove `WindowTransition` (App)

**Why:** Wire the container coordinator to the new callbacks: drive `paneContentView.transform` live, reveal the neighbor snapshot, run the settle-then-swap-under commit with a 1.5s timeout, and spring back on cancel. Remove the superseded `WindowTransition`.

**Files:**
- Modify: `App/TmuxPaneContainer.swift`
- Remove: `App/WindowTransition.swift`
- Test: none (App tier); Kit stays green.

**Interfaces:**
- Consumes: `WindowSnapshotStore` (via VM), `WindowDragModel`/`ExposedNeighbor`, `windowSlideDirection`, the VM's window-neighbor lookup.
- Produces: the wired `Callbacks` (`onDragBeginSwitch` / `onDragUpdate` / `onDragCommit` / `onDragCancel`) + a `pendingSwitchTimeout` on the coordinator.

- [ ] **Step 1: Add coordinator state for the commit handoff**

On the `Coordinator` (where `windowTransition` was declared), replace:

```swift
        let windowTransition = WindowTransition()
```

with:

```swift
        /// The neighbor snapshot host currently revealed in the drag gap (added as a
        /// sibling of `paneContentView`), and the window it previews. Cleared on
        /// commit-handoff or spring-back.
        private var revealedSnapshot: (view: UIView, window: WindowID)?
        /// Fires if a committed switch's live window never arrives (stuck switch): clears
        /// the settled snapshot and restores the current window.
        private var pendingSwitchTimeout: DispatchWorkItem?
        /// The window we are switching TO once tmux delivers it (armed at commit).
        private var pendingSwitchWindow: WindowID?
        /// Seam-dim gradient on the incoming card's leading edge (depth cue, no text-render
        /// change). Installed lazily in `updateSeamDim`, removed in `clearSeamDim`.
        private var seamDim: CAGradientLayer?
```

- [ ] **Step 2: Wire the four new callbacks**

In the `TerminalGestureController(...)` `callbacks: .init(...)` block, REMOVE the
`onSwitchWindow` slide wiring (the `windowTransition.slideOut` / `beginPending` block) and
KEEP a plain `onSwitchWindow` that just calls through (still used as the tmux select entry).
Then add the four new closures:

```swift
                        onSwitchWindow: { [weak self] delta in
                            self?.onSwitchWindow(delta)   // tmux select-window (also used by esc-pill)
                        },
                        onDragBeginSwitch: { [weak self] in
                            self?.beginSwitchReveal()
                        },
                        onDragUpdate: { [weak self] offset, exposed in
                            self?.updateSwitchDrag(offset: offset, exposed: exposed)
                        },
                        onDragCommit: { [weak self] delta in
                            self?.commitSwitchDrag(delta: delta)
                        },
                        onDragCancel: { [weak self] in
                            self?.cancelSwitchDrag()
                        },
```

- [ ] **Step 3: Implement the reveal/update/commit/cancel on the coordinator**

Add these methods to the `Coordinator` (all `@MainActor` - the coordinator already is):

```swift
        /// Drag locked to the switch axis: refresh non-active snapshots so the neighbor
        /// preview is as fresh as possible for THIS drag. The actual neighbor host is
        /// added lazily in `updateSwitchDrag` once we know the direction.
        func beginSwitchReveal() {
            guard let vm = viewModel, let state = vm.tmuxState else { return }
            vm.snapshotStore?.refreshNonActive(state: state)
            DebugLog.shared.log(.gesture, "switch-reveal begin")
        }

        /// Live `.changed`: translate `paneContentView`, and slide the exposed neighbor's
        /// snapshot host in from the opposite edge so it tracks the gap.
        func updateSwitchDrag(offset: Double, exposed: ExposedNeighbor) {
            guard let content = containerView?.paneContentView,
                  let vm = viewModel, let state = vm.tmuxState,
                  let active = state.activeWindow else { return }
            content.transform = CGAffineTransform(translationX: CGFloat(offset), y: 0)
            // Resolve the neighbor window id for the drag direction (wrap at ends).
            let delta = (exposed == .previous) ? -1 : (exposed == .next ? +1 : 0)
            guard delta != 0, let neighbor = vm.neighborWindow(of: active, delta: delta),
                  let host = vm.snapshotStore?.snapshotView(for: neighbor),
                  let container = containerView else {
                revealedSnapshot?.view.removeFromSuperview(); revealedSnapshot = nil
                return
            }
            if revealedSnapshot?.window != neighbor {
                revealedSnapshot?.view.removeFromSuperview()
                container.addSubview(host)
                revealedSnapshot = (host, neighbor)
                let cell = container.resolvedCellPublic()
                vm.snapshotStore?.layout(window: neighbor, in: state, bounds: container.bounds,
                                         cellWidth: cell.w, cellHeight: cell.h)
            }
            // Paired-card model: outgoing pane content + incoming neighbor translate as a
            // rigid pair, both tracking the finger. The neighbor sits one width off the
            // revealing edge, offset with the content.
            let w = container.bounds.width
            let base: CGFloat = (exposed == .previous) ? -w : w   // prev enters from left, next from right
            host.transform = CGAffineTransform(translationX: base + CGFloat(offset), y: 0)
            // Edge/seam dimming: fade the seam between the two cards for a depth cue with
            // NO text-render change (decided in brainstorm 2026-07-18: seam dimming, no
            // real 3D curl). See `installSeamDim` / `updateSeamDim` below.
            updateSeamDim(on: host, exposed: exposed, progress: abs(offset) / max(w, 1))
        }

        /// A thin gradient overlay on the incoming card's LEADING edge (the seam between
        /// the two cards), darkening toward the seam so the pair reads as layered depth.
        /// A `CAGradientLayer`, NOT a render transform on the text — the terminal glyphs are
        /// never distorted (brainstorm 2026-07-18: no real curl). This is also the single
        /// extension point if a parallax multiplier is added later.
        private func installSeamDim(on host: UIView, exposed: ExposedNeighbor) -> CAGradientLayer {
            let g = CAGradientLayer()
            g.frame = host.bounds
            // Horizontal gradient; opaque black at the seam edge fading to clear across ~16% of width.
            g.startPoint = CGPoint(x: exposed == .previous ? 1.0 : 0.0, y: 0.5)  // seam is the edge nearest the outgoing card
            g.endPoint   = CGPoint(x: exposed == .previous ? 0.0 : 1.0, y: 0.5)
            g.colors = [UIColor.black.withAlphaComponent(0.35).cgColor, UIColor.clear.cgColor]
            g.locations = [0.0, 0.16]
            g.isUserInteractionEnabled = false
            host.layer.addSublayer(g)
            return g
        }

        /// Update the seam-dim strength with drag progress (0 at rest -> full at a
        /// full-width reveal) and keep its frame pinned to the host. Lazily installs the
        /// gradient on first call for this reveal; tracked in `seamDim`.
        private func updateSeamDim(on host: UIView, exposed: ExposedNeighbor, progress: Double) {
            let g = seamDim ?? installSeamDim(on: host, exposed: exposed)
            seamDim = g
            g.frame = host.bounds
            // Opacity ramps with how far the reveal has progressed (clamped 0...1), so the
            // seam is subtle at the start of a drag and strongest when the card is fully in.
            g.opacity = Float(min(max(progress, 0), 1))
        }

        /// Remove the seam-dim gradient (on commit-handoff, spring-back, or timeout).
        private func clearSeamDim() {
            seamDim?.removeFromSuperlayer()
            seamDim = nil
        }

        /// Release past threshold: settle the snapshot fully over the pane, issue the tmux
        /// switch, and arm the delivery timeout. The live window swaps in UNDER the snapshot
        /// in `apply(state:)` (Step 4).
        func commitSwitchDrag(delta: Int) {
            guard let content = containerView?.paneContentView,
                  let container = containerView,
                  let dir = windowSlideDirection(delta: delta) else { cancelSwitchDrag(); return }
            let w = container.bounds.width
            let outX: CGFloat = (dir.out == .left) ? -w : w
            let host = revealedSnapshot?.view
            pendingSwitchWindow = revealedSnapshot?.window
            UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut], animations: {
                content.transform = CGAffineTransform(translationX: outX, y: 0)
                host?.transform = .identity
            })
            onSwitchWindow(delta)   // tmux select-window
            let timeout = DispatchWorkItem { [weak self] in self?.failPendingSwitch() }
            pendingSwitchTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: timeout)
            DebugLog.shared.log(.gesture, "switch commit delta=\(delta) -> pending @\(pendingSwitchWindow.map { "\($0.raw)" } ?? "nil")")
        }

        /// Release short: animate the current window back to identity, drop the snapshot.
        func cancelSwitchDrag() {
            guard let content = containerView?.paneContentView else { return }
            let host = revealedSnapshot?.view
            let w = containerView?.bounds.width ?? 0
            let exposedPrev = (host?.transform.tx ?? 0) < 0
            UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut], animations: {
                content.transform = .identity
                host?.transform = CGAffineTransform(translationX: exposedPrev ? -w : w, y: 0)
            }, completion: { [weak self] _ in
                self?.revealedSnapshot?.view.removeFromSuperview()
                self?.revealedSnapshot = nil
            })
            clearSeamDim()
            DebugLog.shared.log(.gesture, "switch cancel -> spring back")
        }

        /// Timeout: the committed switch never delivered. Restore the current content and
        /// drop the stuck snapshot.
        private func failPendingSwitch() {
            pendingSwitchTimeout = nil
            pendingSwitchWindow = nil
            containerView?.paneContentView.transform = .identity
            revealedSnapshot?.view.removeFromSuperview(); revealedSnapshot = nil
            clearSeamDim()
            DebugLog.shared.log(.gesture, "switch TIMEOUT -> restore current")
        }

        /// Called from `apply(state:)` when the active window actually changed: complete
        /// the handoff by resetting the content transform (live panes now fill it) and
        /// removing the covering snapshot. No-op if no switch was pending.
        func completePendingSwitchIfNeeded(newActive: WindowID) {
            guard pendingSwitchWindow != nil else {
                // A switch that arrived without our drag (e.g. esc-pill): nothing to hand off.
                return
            }
            pendingSwitchTimeout?.cancel(); pendingSwitchTimeout = nil
            pendingSwitchWindow = nil
            containerView?.paneContentView.transform = .identity
            revealedSnapshot?.view.removeFromSuperview(); revealedSnapshot = nil
            clearSeamDim()
            DebugLog.shared.log(.gesture, "switch handoff complete active=@\(newActive.raw)")
        }
```

> **Verify names before coding:** confirm the coordinator's back-references actually named
> `viewModel` and `containerView` (grep `containerView` / `viewModel` / `weak var` in
> `TmuxPaneContainer.swift`). If the coordinator reaches the VM by another name, use it. Add
> a small `resolvedCellPublic()` shim on `ContainerView` returning `resolvedCell()` if
> `resolvedCell` is private (it is), OR compute the cell inline from
> `paneTerminalViews.first?.getOptimalFrameSize()` the same way `resolvedCell` does.

- [ ] **Step 4: Trigger the handoff from `apply(state:)`**

At the END of `apply(state:)` where the active-window change is detected (search
`previousActiveWindow` / `consumePendingSlideIn`), REPLACE the old
`windowTransition.consumePendingSlideIn(...)` call with:

```swift
                if state.activeWindow != previousActiveWindow, let newActive = state.activeWindow {
                    coordinator?.completePendingSwitchIfNeeded(newActive: newActive)
                }
```

Keep the `previousActiveWindow = state.activeWindow` update that already follows.

- [ ] **Step 5: Add the VM neighbor lookup**

In `App/ConnectionViewModel.swift`, add (wrap at the ends, matching the shipped `stepIndex`
behavior the esc-pill switch uses):

```swift
    /// The window `delta` steps from `id` in window-list order, wrapping at the ends.
    /// nil with fewer than 2 windows. Matches the wrap the esc-pill switch uses.
    func neighborWindow(of id: WindowID, delta: Int) -> WindowID? {
        guard let windows = tmuxState?.windows, windows.count > 1,
              let idx = windows.firstIndex(where: { $0.id == id }) else { return nil }
        let n = windows.count
        let next = ((idx + delta) % n + n) % n
        return windows[next].id
    }
```

- [ ] **Step 6: Remove `WindowTransition`**

```bash
git rm App/WindowTransition.swift
```

Confirm no remaining references:

Run: `grep -rn "WindowTransition\|windowTransition\|consumePendingSlideIn\|beginPending" App/`
Expected: no matches.

- [ ] **Step 7: Verify Kit still builds/tests**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add App/TmuxPaneContainer.swift App/ConnectionViewModel.swift
git rm App/WindowTransition.swift
git commit -m "feat(terminal): finger-drag commit handoff + snapshot reveal; remove WindowTransition"
```

---

## Task 8: macOS CI validation + device retest procedure

**Why:** The App tier does not compile on Linux; the macOS CI job is the only build signal, and the feel is device-verified. This task gates the branch on CI green and records the device retest.

**Files:** none (process task).

- [ ] **Step 1: Push the branch and open a PR**

```bash
git push github HEAD
gh pr create --repo ds7n/semicolyn --fill --title "feat(terminal): finger-drag window transition (live drag + capture-pane snapshots)"
```

- [ ] **Step 2: Wait for macOS CI green**

Run: `gh run watch --repo ds7n/semicolyn` (or `gh run list --repo ds7n/semicolyn --limit 3`).
Expected: the `macos` job passes (the only Apple build signal, ~15-18 min). If `linux-rust`
flakes with "sshd fixtures not reachable", rerun that job (`gh run rerun <id> --failed`) - it
is unrelated to this change.

- [ ] **Step 3: Fix any macOS-only compile errors**

Most likely classes (fix inline, re-push):
- `@MainActor` isolation on a nonisolated delegate callback -> wrap the offending body in
  `MainActor.assumeIsolated {}` (see memory `mainactor-delegate-callback-trap`).
- A `PaneRect` / SwiftTerm member-name mismatch flagged in the Task 5 / Task 7 verify notes.
Re-run CI after each fix until the `macos` job is green.

- [ ] **Step 4: Trigger a TestFlight build**

```bash
gh workflow run "Release to TestFlight" --repo ds7n/semicolyn --ref <branch-or-main>
```

- [ ] **Step 5: Device retest checklist (record results in TODO.md / a resume doc)**

Enable Settings > Diagnostics > Gesture logging first, then verify on device:
1. Horizontal drag on a normal-shell pane: current window tracks the finger; the ADJACENT
   window's real content shows in the gap (`snapshot applied` + `switch-reveal begin` logs).
2. Drag past ~40% + release: switch commits, live window swaps in with no empty flash
   (`switch commit` -> `switch handoff complete`).
3. Short drag + release: springs back, no switch (`switch cancel`).
4. Fast short flick: commits (`drag-switch commit ... vx=`).
5. Vertical drag still scrolls (normal) / wheel-scrolls Claude (alt-screen) - unchanged.
6. Horizontal drag on a Claude/alt-screen pane also switches windows (mode coverage).
7. Reverse direction mid-drag: exposed snapshot swaps to the other neighbor.
8. Single-window session: no switch, drag always scrolls.

- [ ] **Step 6: Squash-merge once CI is green and device feel is confirmed**

Per repo convention (squash-merge to `main`). Update the resume doc + memory
`session-resume-2026-07-17` to reflect the shipped transition.

---

## Self-Review

**Spec coverage:**
- Reveal = real capture-pane snapshots -> Tasks 4, 5. ✓
- All windows seeded -> `refreshNonActive` iterates every non-active window (Task 5). ✓
- Refresh on connect + drag-start -> VM `refreshNonActive` on state change (Task 5) + `beginSwitchReveal` (Task 7). No timer / `%output` trigger. ✓
- Distance-or-velocity commit (pure Kit fn) -> `SwitchCommitDecision` (Task 3). ✓
- Handoff: settle -> swap under -> remove + 1.5s timeout -> `commitSwitchDrag`/`completePendingSwitchIfNeeded`/`failPendingSwitch` (Task 7). ✓
- Axis lock at dead-zone, fixed for the drag -> `DragAxisLock` + `dragAxis` snapshot (Tasks 1, 6). ✓
- Switch works in all modes -> `driveLiveSwitch` called from both pan handlers (Task 6). ✓
- Edge wrap kept -> `neighborWindow` wraps (Task 7). ✓
- `WindowTransition` removed, `paneContentView` kept -> Task 7. ✓
- `windowSlideDirection`/`SlideEdge` kept -> used in `commitSwitchDrag` (Task 7). ✓

**Placeholder scan:** no TBD/TODO; every code step shows the full code. The two "Verify names
before coding" notes point at exact files to confirm real member names (`PaneRect`, SwiftTerm
feed/reset, coordinator back-refs) - these are grounded verification steps, not placeholders.

**Type consistency:** `DragAxis.switchWindow(delta:)`, `ExposedNeighbor` (`.previous`/`.next`/
`.none`), `SwitchOutcome.commit(delta:)` used consistently across Tasks 1-3-6-7. `captureSnapshot`
/ `onSnapshotCaptured` names match between Task 4 (producer) and Task 5 (consumer).
`neighborWindow(of:delta:)`, `snapshotView(for:)`, `refreshNonActive(state:)`, `layout(window:in:bounds:cellWidth:cellHeight:)`
match between Task 5 (producer) and Task 7 (consumer). `completePendingSwitchIfNeeded(newActive:)`
matches between Task 7's coordinator method and its `apply(state:)` call site.

**Known verification points folded into steps (not gaps):** exact `PaneRect` member names,
SwiftTerm `feed(byteArray:)`/reset API, the coordinator's VM/container back-reference names, and
the seeder's scrollback-lines symbol. Each has an inline "Verify" note at its use site.
