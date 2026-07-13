<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Terminal Interaction-Mode Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the failed gesture/scroll "straddle" with a tracked, event-driven `InteractionMode` (localScroll / appOwnsInput / mouseReporting) that gives exactly one drag-owner per mode and makes alt-screen drag scroll the app via arrow keys.

**Architecture:** A pure Kit tier decides everything testable on Linux (`resolveMode`, the alt-screen drag→arrow-count math, a DECCKM-aware arrow encoder). A thin App tier wires SwiftTerm recognizers to those decisions, updates the mode from `bufferActivated`/`mouseModeChanged` delegate **events** (not render-polling), and flips per-mode drag ownership via the documented `isScrollEnabled` API. Mode + DECCKM are snapshotted at gesture-begin so a mid-drag mode flip can't corrupt an in-flight gesture.

**Tech Stack:** Swift 6 (strict concurrency in Kit), SwiftTerm (UIKit `TerminalView` = `UIScrollView`), tmux -CC, XCTest (Kit, Linux via Docker), macOS CI (App tier).

## Global Constraints

- **Two tiers, two test surfaces.** `Sources/SemicolynKit/` = pure logic, Swift-6 strict-concurrency, `Sendable`, **no `import UIKit`/`SwiftUI`/`CryptoKit`**, Linux-tested via `swift test`. `App/` = Apple-only, macOS-CI-verified, invisible to `swift test`.
- **SPDX header on every source file:** `// SPDX-FileCopyrightText: 2026 True Positive LLC` then `// SPDX-License-Identifier: GPL-3.0-only`.
- **Conventional commits** (`feat:`/`fix:`/`refactor:`/`test:`/`docs:`). Feature branch; **squash-merge** to `main`.
- **Tests must be real** (`docs/superpowers/specs/2026-06-18-testing-standards-design.md`): EP + BVA, assert observable values (no tautologies), a negative test asserts the *specific* failure.
- **Kit test command (Docker, no host Swift):** `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`. Focused: append `--filter <TestClass>`.
- **App-tier tasks are macOS-CI/device-only** — they compile and run nowhere on this host. Their "run" steps are CI + a device trace, not a local command.
- **Binding prior decisions (do not revisit):** window-nav clamps at ends via `clampedStepIndex` (⌘]/swipe still wrap via `stepIndex`); drag-switch fires once per drag on release; `CursorDragEngine` stays retired.

**Spec:** `docs/superpowers/specs/2026-07-12-terminal-interaction-mode-design.md`.

---

## File Structure

**Kit (new / changed — Linux-tested):**
- `Sources/SemicolynKit/Terminal/InteractionMode.swift` *(new)* — the `InteractionMode` enum + `resolveMode(isAltScreen:mouseReporting:)`.
- `Sources/SemicolynKit/Terminal/AltScreenScroll.swift` *(new)* — pure decider: cumulative Δy + cellHeight + last-emitted offset → incremental `[ArrowRun]` (down/up), clamped by an owned `static let maxCellsPerEmit`.
- `Sources/SemicolynKit/Terminal/ArrowEncoding.swift` *(new)* — one DECCKM-aware `encodeArrowRun(_:applicationCursorKeys:)` returning bytes, replacing the two hardcoded-CSI copies in the App tier.
- `Tests/SemicolynKitTests/InteractionModeTests.swift`, `AltScreenScrollTests.swift`, `ArrowEncodingTests.swift` *(new)*.

**App (changed — macOS-CI/device only):**
- `App/PaneModeTracker.swift` *(new)* — thin per-pane mode holder shared by both coordinators; recomputes via Kit `resolveMode`, notifies the controller.
- `App/TerminalGestureController.swift` *(modify)* — mode-driven routing; begin-time snapshot; `.changed`-phase alt-screen arrows; `isScrollEnabled` flip; byte-send callback.
- `App/TmuxPaneContainer.swift` *(modify)* — implement `bufferActivated`/`mouseModeChanged`; delete render-time mode-poll; route bytes.
- `App/TerminalScreen.swift` *(modify)* — same, single-pane; route the tap-cursor path through the new Kit encoder.
- `App/ConnectionViewModel.swift` *(modify)* — route `placeTmuxCursor` through the new Kit encoder (DRY the DECCKM encode).

**Ordering rationale:** Kit tasks (1–3) land first — pure, Linux-tested, zero App dependency. App tasks (4–8) consume them and are validated on macOS CI. Task 4 (event wiring) is an early empirical checkpoint proving the delegate-event foundation before the rest is built on it.

---

## Task 1: `InteractionMode` + `resolveMode` (Kit, pure)

**Files:**
- Create: `Sources/SemicolynKit/Terminal/InteractionMode.swift`
- Test: `Tests/SemicolynKitTests/InteractionModeTests.swift`

**Interfaces:**
- Produces: `enum InteractionMode: Equatable, Sendable { case localScroll; case appOwnsInput; case mouseReporting }` and `func resolveMode(isAltScreen: Bool, mouseReporting: Bool) -> InteractionMode`.

- [ ] **Step 1: Write the failing test**

`Tests/SemicolynKitTests/InteractionModeTests.swift`:
```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class InteractionModeTests: XCTestCase {
    // EP: the 4 combinations of (isAltScreen, mouseReporting).
    func testNormalScreenNoMouseIsLocalScroll() {
        XCTAssertEqual(resolveMode(isAltScreen: false, mouseReporting: false), .localScroll)
    }
    func testNormalScreenWithMouseIsMouseReporting() {
        XCTAssertEqual(resolveMode(isAltScreen: false, mouseReporting: true), .mouseReporting)
    }
    func testAltScreenNoMouseIsAppOwnsInput() {
        XCTAssertEqual(resolveMode(isAltScreen: true, mouseReporting: false), .appOwnsInput)
    }
    // The precedence rule: alt-screen wins over mouse (Claude Code case).
    func testAltScreenWithMouseIsAppOwnsInputNotMouseReporting() {
        XCTAssertEqual(resolveMode(isAltScreen: true, mouseReporting: true), .appOwnsInput)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter InteractionModeTests`
Expected: FAIL — `cannot find 'resolveMode' in scope`.

- [ ] **Step 3: Write minimal implementation**

`Sources/SemicolynKit/Terminal/InteractionMode.swift`:
```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// The terminal's current touch-interaction mode. Held as tracked state and
/// updated on `bufferActivated` / `mouseModeChanged` delegate events; the gesture
/// layer routes drag / tap / selection per mode. One unambiguous drag-owner each.
public enum InteractionMode: Equatable, Sendable {
    /// Normal screen, no mouse reporting — SwiftTerm's native scroll owns the drag.
    case localScroll
    /// Alternate screen (vim/htop/Claude) — we translate drag→arrows, tap→mouse.
    case appOwnsInput
    /// Normal screen, app enabled mouse reporting — forward events to the app.
    case mouseReporting
}

/// Resolve the interaction mode from terminal state. Alt-screen takes precedence
/// over mouse-mode: an alt-screen app with mouse on resolves to `.appOwnsInput`
/// (drag→arrows and tap→mouse both apply there).
public func resolveMode(isAltScreen: Bool, mouseReporting: Bool) -> InteractionMode {
    if isAltScreen { return .appOwnsInput }
    if mouseReporting { return .mouseReporting }
    return .localScroll
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter InteractionModeTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Terminal/InteractionMode.swift Tests/SemicolynKitTests/InteractionModeTests.swift
git commit -m "feat(terminal): InteractionMode enum + pure resolveMode (alt-screen precedence)"
```

---

## Task 2: `AltScreenScroll` drag→arrow-count decider (Kit, pure)

**Files:**
- Create: `Sources/SemicolynKit/Terminal/AltScreenScroll.swift`
- Test: `Tests/SemicolynKitTests/AltScreenScrollTests.swift`

**Interfaces:**
- Consumes: `ArrowRun` from `Sources/SemicolynKit/Terminal/CursorArrowStream.swift` (`public struct ArrowRun { let direction: ArrowDirection; let count: Int }`) and `arrowEvents(cols:rows:) -> [ArrowRun]`.
- Produces: `struct AltScreenScroll { static let maxCellsPerEmit: Int; static func arrows(totalDy: Double, cellHeight: Double, emittedCells: Int) -> (runs: [ArrowRun], newEmittedCells: Int) }`.

**Design note:** the App calls this on each `.changed`. `totalDy` = cumulative drag translation since `.began` (SwiftTerm `translation(in:).y`, downward positive). `emittedCells` = how many cells we've *already* turned into arrows this gesture (signed; down = negative because a downward finger drag scrolls content up = the app receives DOWN arrows... see convention below). The decider returns only the *new* runs to send plus the updated running total, so successive `.changed` samples never double-count.

**Scroll convention (fixed, tested):** dragging the finger **down** (positive Δy) reveals content **above** = sends **UP** arrows to the app (a pager scrolls back); dragging **up** (negative Δy) sends **DOWN** arrows. This matches natural-scroll touch and xterm Alternate-Scroll. We express it as: `targetCells = Int(totalDy / cellHeight)`; the delta `targetCells - emittedCells` maps to arrows via `arrowEvents(cols: 0, rows: -(delta))` (negate: +Δy → UP).

- [ ] **Step 1: Write the failing test**

`Tests/SemicolynKitTests/AltScreenScrollTests.swift`:
```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class AltScreenScrollTests: XCTestCase {
    let cell = 16.0

    // BVA: below one cell → no arrows, no progress.
    func testSubCellDragEmitsNothing() {
        let r = AltScreenScroll.arrows(totalDy: 10, cellHeight: cell, emittedCells: 0)
        XCTAssertEqual(r.runs, [])
        XCTAssertEqual(r.newEmittedCells, 0)
    }
    // Boundary: exactly one cell down → one UP arrow (natural scroll).
    func testOneCellDownEmitsOneUpArrow() {
        let r = AltScreenScroll.arrows(totalDy: 16, cellHeight: cell, emittedCells: 0)
        XCTAssertEqual(r.runs, [ArrowRun(direction: .up, count: 1)])
        XCTAssertEqual(r.newEmittedCells, 1)
    }
    // Direction: dragging up → DOWN arrows.
    func testDragUpEmitsDownArrows() {
        let r = AltScreenScroll.arrows(totalDy: -48, cellHeight: cell, emittedCells: 0)
        XCTAssertEqual(r.runs, [ArrowRun(direction: .down, count: 3)])
        XCTAssertEqual(r.newEmittedCells, -3)
    }
    // Incremental accounting: a second sample sends only the NEW delta.
    func testIncrementalDeltaOnlyNoDoubleCount() {
        let first = AltScreenScroll.arrows(totalDy: 16, cellHeight: cell, emittedCells: 0)
        XCTAssertEqual(first.newEmittedCells, 1)
        let second = AltScreenScroll.arrows(totalDy: 48, cellHeight: cell, emittedCells: first.newEmittedCells)
        XCTAssertEqual(second.runs, [ArrowRun(direction: .up, count: 2)]) // cells 2 and 3 only
        XCTAssertEqual(second.newEmittedCells, 3)
    }
    // No movement since last emit → nothing.
    func testNoNewCellsEmitsNothing() {
        let r = AltScreenScroll.arrows(totalDy: 20, cellHeight: cell, emittedCells: 1)
        XCTAssertEqual(r.runs, [])
        XCTAssertEqual(r.newEmittedCells, 1)
    }
    // Anti-flood: a huge flick is CLAMPED to maxCellsPerEmit per call (assert the exact cap).
    func testHugeFlickIsClampedToMaxPerEmit() {
        let huge = Double(AltScreenScroll.maxCellsPerEmit + 40) * cell
        let r = AltScreenScroll.arrows(totalDy: huge, cellHeight: cell, emittedCells: 0)
        XCTAssertEqual(r.runs, [ArrowRun(direction: .up, count: AltScreenScroll.maxCellsPerEmit)])
        XCTAssertEqual(r.newEmittedCells, AltScreenScroll.maxCellsPerEmit) // progress caps too
    }
    // Guard: zero/negative cellHeight can't divide-by-zero or spew.
    func testZeroCellHeightEmitsNothing() {
        let r = AltScreenScroll.arrows(totalDy: 100, cellHeight: 0, emittedCells: 0)
        XCTAssertEqual(r.runs, [])
        XCTAssertEqual(r.newEmittedCells, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter AltScreenScrollTests`
Expected: FAIL — `cannot find 'AltScreenScroll' in scope`.

- [ ] **Step 3: Write minimal implementation**

`Sources/SemicolynKit/Terminal/AltScreenScroll.swift`:
```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Pure decider that turns an in-progress alt-screen vertical drag into arrow-key
/// runs to send to the foreground app (xterm "Alternate Scroll" model). The App
/// calls `arrows(...)` on each pan `.changed`, threading the running `emittedCells`
/// so successive samples send only the NEW delta (never double-counting), and the
/// per-emit clamp bounds a fast flick so it can't flood the remote.
///
/// Convention: finger DOWN (+Δy) reveals content above → UP arrows (scroll back);
/// finger UP (−Δy) → DOWN arrows. Natural-scroll touch semantics.
public struct AltScreenScroll: Sendable {
    /// Max cells (= arrow presses) turned into arrows in a single `.changed` call.
    /// Bounds a fast flick; feel-tuned. Progress caps at this too, so the running
    /// total advances by at most this per emit.
    public static let maxCellsPerEmit: Int = 24

    public static func arrows(totalDy: Double,
                              cellHeight: Double,
                              emittedCells: Int) -> (runs: [ArrowRun], newEmittedCells: Int) {
        guard cellHeight > 0 else { return ([], emittedCells) }
        let target = Int(totalDy / cellHeight)
        var delta = target - emittedCells
        if delta == 0 { return ([], emittedCells) }
        // Clamp magnitude to the per-emit cap (preserve sign).
        if delta > maxCellsPerEmit { delta = maxCellsPerEmit }
        if delta < -maxCellsPerEmit { delta = -maxCellsPerEmit }
        // +Δy (down) → UP arrows: negate the row delta for arrowEvents.
        let runs = arrowEvents(cols: 0, rows: -delta)
        return (runs, emittedCells + delta)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter AltScreenScrollTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Terminal/AltScreenScroll.swift Tests/SemicolynKitTests/AltScreenScrollTests.swift
git commit -m "feat(terminal): AltScreenScroll pure drag->arrow-count decider (clamped, incremental)"
```

---

## Task 3: DECCKM-aware `encodeArrowRun` (Kit, pure) — DRY the two hardcoded copies

**Files:**
- Create: `Sources/SemicolynKit/Terminal/ArrowEncoding.swift`
- Test: `Tests/SemicolynKitTests/ArrowEncodingTests.swift`

**Interfaces:**
- Consumes: `ArrowRun` (Task 2 note), `ArrowDirection`, and the existing `encodeKey(_:modifiers:applicationCursorKeys:) -> [UInt8]` in `Sources/SemicolynKit/Keybar/KeyEncoding.swift` (which already emits `ESC O` prefix when `applicationCursorKeys` is true, else `ESC [`).
- Produces: `func encodeArrowRun(_ run: ArrowRun, applicationCursorKeys: Bool) -> [UInt8]`.

**Why:** the App tier currently hardcodes CSI arrows (`ESC [ A`) in *two* places (`TerminalScreen.encodeArrowRun`, `ConnectionViewModel.placeTmuxCursor`), ignoring DECCKM — a pre-existing bug the spec's DECCKM requirement fixes. One Kit encoder, reused by the tap-cursor path AND the new alt-screen drag path.

- [ ] **Step 1: Write the failing test**

`Tests/SemicolynKitTests/ArrowEncodingTests.swift`:
```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ArrowEncodingTests: XCTestCase {
    // Normal cursor-key mode (DECCKM off) → CSI: ESC [ A, repeated by count.
    func testUpTwiceNormalModeIsCSIRepeated() {
        let bytes = encodeArrowRun(ArrowRun(direction: .up, count: 2), applicationCursorKeys: false)
        XCTAssertEqual(bytes, [0x1b, 0x5b, 0x41, 0x1b, 0x5b, 0x41]) // ESC[A ESC[A
    }
    // Application cursor-key mode (DECCKM on) → SS3: ESC O B.
    func testDownOnceApplicationModeIsSS3() {
        let bytes = encodeArrowRun(ArrowRun(direction: .down, count: 1), applicationCursorKeys: true)
        XCTAssertEqual(bytes, [0x1b, 0x4f, 0x42]) // ESC O B
    }
    // Left/right map correctly (regression against a direction swap).
    func testLeftRightNormalMode() {
        XCTAssertEqual(encodeArrowRun(ArrowRun(direction: .left, count: 1), applicationCursorKeys: false),
                       [0x1b, 0x5b, 0x44]) // ESC [ D
        XCTAssertEqual(encodeArrowRun(ArrowRun(direction: .right, count: 1), applicationCursorKeys: false),
                       [0x1b, 0x5b, 0x43]) // ESC [ C
    }
    // Zero count → no bytes.
    func testZeroCountIsEmpty() {
        XCTAssertEqual(encodeArrowRun(ArrowRun(direction: .up, count: 0), applicationCursorKeys: false), [])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ArrowEncodingTests`
Expected: FAIL — `cannot find 'encodeArrowRun' in scope`.

- [ ] **Step 3: Write minimal implementation**

`Sources/SemicolynKit/Terminal/ArrowEncoding.swift`:
```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Encode one `ArrowRun` to its escape bytes, `count` times, honoring DECCKM
/// (application-cursor-keys): SS3 `ESC O A/B/C/D` when on, CSI `ESC [ A/B/C/D`
/// when off. Delegates to the shared `encodeKey(.arrow(…))` so tap-to-place and
/// alt-screen drag share one encoder (no more hardcoded-CSI copies in the App).
public func encodeArrowRun(_ run: ArrowRun, applicationCursorKeys: Bool) -> [UInt8] {
    guard run.count > 0 else { return [] }
    let one = encodeKey(.arrow(run.direction),
                        modifiers: KeyModifiers(),
                        applicationCursorKeys: applicationCursorKeys)
    var out: [UInt8] = []
    out.reserveCapacity(one.count * run.count)
    for _ in 0..<run.count { out.append(contentsOf: one) }
    return out
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ArrowEncodingTests`
Expected: PASS (4 tests). If `testUpTwiceNormalModeIsCSIRepeated` fails, open `Keybar/KeyEncoding.swift` and confirm `encodeKey(.arrow(.up), …, applicationCursorKeys: false)` returns `[0x1b,0x5b,0x41]`; adjust the test's expected bytes only if the existing encoder provably differs (it should not).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Terminal/ArrowEncoding.swift Tests/SemicolynKitTests/ArrowEncodingTests.swift
git commit -m "feat(terminal): DECCKM-aware encodeArrowRun in Kit (DRY the hardcoded-CSI copies)"
```

- [ ] **Step 6: Run the full Kit suite (no regressions across tiers)**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS (all SemicolynKit + SeedKit tests). This is the last Linux-verifiable gate; Tasks 4–8 are App-tier.

---

## Task 4: Wire mode from `bufferActivated`/`mouseModeChanged` via a `PaneTerminalView` subclass (App) — the empirical foundation checkpoint

> **CORRECTION (2026-07-12, from this task's own foundation gate):** the original plan
> implemented `bufferActivated`/`mouseModeChanged` on the mount *coordinator*. That is
> WRONG — verified against SwiftTerm `main` + v1.14.0: those two methods belong to the
> *emulator* `TerminalDelegate`, whose slot SwiftTerm wires to the `TerminalView` INSTANCE
> itself (not reassignable from app code). `TerminalViewDelegate` (what our coordinators
> conform to) does not declare them. SwiftTerm's intended extension point is to **subclass
> `TerminalView` and override the `open` methods**. This task now does that.

**Files:**
- Create: `App/PaneModeTracker.swift`
- Create: `App/PaneTerminalView.swift` (`final class PaneTerminalView: TerminalView`)
- Modify: `App/TmuxPaneContainer.swift` (construct `PaneTerminalView`; wire `onModeRelevantChange` → tracker; prime; delete poll)
- Modify: `App/TerminalScreen.swift` (same, single-pane)

**Interfaces:**
- Consumes: `resolveMode(isAltScreen:mouseReporting:)`, `InteractionMode` (Task 1); `PaneID` (`struct PaneID: Hashable, Sendable { let raw: UInt32; init(raw:) }` — UInt32-backed, so a negative sentinel is impossible; the raw single-pane mount is keyed by `nil`).
- Produces: `@MainActor final class PaneModeTracker` keyed by `PaneID?` (nil = single raw pane) with `func mode(for pane: PaneID?) -> InteractionMode`, `func recompute(for pane: PaneID?, terminal: Terminal)`, and an `onChange: (PaneID?, InteractionMode) -> Void` hook; plus single-pane conveniences `var mode` / `func recompute(terminal:)` that pass `nil`. Also `final class PaneTerminalView: TerminalView` with `var onModeRelevantChange: ((Terminal) -> Void)?`.

**Purpose of this task:** prove the event foundation *before* building routing on it. After this task, a device trace must show the mode flipping on entering/leaving Claude. If the overrides do NOT fire in our build, stop and reassess here — cheaply — rather than after Tasks 5–8.

- [ ] **Step 1: Create `PaneModeTracker`**

`App/PaneModeTracker.swift`:
```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftTerm
import SemicolynKit

/// Holds each pane's tracked `InteractionMode`, recomputed from terminal state on
/// `bufferActivated` / `mouseModeChanged` (delivered via the `PaneTerminalView`
/// subclass overrides, NOT render-polling). Both mount sites own one so the mode
/// derivation lives in exactly one place. Keyed by `PaneID?` — nil = the single raw
/// (non-tmux) pane.
@MainActor
final class PaneModeTracker {
    // Keyed by PaneID? — nil is the single raw (non-tmux) pane. PaneID is UInt32-backed
    // (no room for a sentinel), so the optional key is the clean single-pane spelling.
    private var modes: [PaneID?: InteractionMode] = [:]
    /// Fired when a pane's mode actually changes (deduped). App wires this to the
    /// pane's gesture controller (isScrollEnabled + routing) and mouse-dot.
    var onChange: (PaneID?, InteractionMode) -> Void = { _, _ in }

    func mode(for pane: PaneID?) -> InteractionMode { modes[pane] ?? .localScroll }

    /// Recompute from live terminal state. Idempotent; only fires `onChange` on a
    /// real transition.
    func recompute(for pane: PaneID?, terminal: Terminal) {
        let next = resolveMode(isAltScreen: terminal.isCurrentBufferAlternate,
                               mouseReporting: terminal.mouseMode != .off)
        if modes[pane] != next {
            modes[pane] = next
            DebugLog.shared.log(.gesture, "mode[\(pane.map { "%\($0.raw)" } ?? "raw")] -> \(next)")
            onChange(pane, next)
        }
    }

    // Single-pane conveniences for the raw mount.
    var mode: InteractionMode { mode(for: nil) }
    func recompute(terminal: Terminal) { recompute(for: nil, terminal: terminal) }
}
```

- [ ] **Step 2: Create the `PaneTerminalView` subclass (the real event seam)**

`App/PaneTerminalView.swift`:
```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftTerm

/// SwiftTerm delivers `bufferActivated` / `mouseModeChanged` (the alt-screen and
/// mouse-mode transition events) to the `TerminalView` INSTANCE via the emulator
/// `TerminalDelegate` — NOT to the app's `TerminalViewDelegate`. `TerminalView`
/// declares them `open` for exactly this: subclass and override. We `super`-call
/// first (preserve SwiftTerm's own scroller / mouse-pan-gesture side effects), then
/// hand the live `Terminal` to `onModeRelevantChange`, which each mount wires to its
/// `PaneModeTracker.recompute(...)`.
final class PaneTerminalView: TerminalView {
    /// Set by the mount right after construction. Called on every alt-screen or
    /// mouse-mode transition with this view's emulator terminal.
    var onModeRelevantChange: ((Terminal) -> Void)?

    override func bufferActivated(source: Terminal) {
        super.bufferActivated(source: source)
        onModeRelevantChange?(source)
    }
    override func mouseModeChanged(source: Terminal) {
        super.mouseModeChanged(source: source)
        onModeRelevantChange?(source)
    }
}
```
> Verify the two override signatures against the pinned SwiftTerm (`iOSTerminalView.swift`): they are `open func bufferActivated(source: Terminal)` / `open func mouseModeChanged(source: Terminal)`. Match them exactly (including the `source` label). If the pinned version's signature differs, match what's there and note it — do NOT invent a signature.

- [ ] **Step 3: Construct `PaneTerminalView` at both mount sites + wire the tracker**

Both mounts currently do `TerminalView(frame:)` at one site each (`TerminalScreen.swift:56`, `TmuxPaneContainer.swift:548`) and type pane registries as `[PaneID: TerminalView]`. Change the construction to `PaneTerminalView(frame:)` (subtyping covers every `TerminalView`-typed site — no registry retyping needed). Add `let modeTracker = PaneModeTracker()` to each mount's coordinator. Right after constructing each pane view, wire:

```swift
// tmux (TmuxPaneContainer, where the pane view + PaneID are both in scope):
let view = PaneTerminalView(frame: .zero)
view.onModeRelevantChange = { [weak coordinator] term in
    coordinator?.modeTracker.recompute(for: pane, terminal: term)   // `pane` = this pane's PaneID
}
```
```swift
// raw (TerminalScreen.makeUIView):
let terminal = PaneTerminalView(frame: .zero)
terminal.onModeRelevantChange = { [weak coordinator = context.coordinator] term in
    coordinator?.modeTracker.recompute(terminal: term)   // single-pane → nil key
}
```
> `recompute` is `@MainActor`; the override runs on the main thread (SwiftTerm UI callbacks are main-thread), so a direct call is fine. If the compiler flags actor isolation, wrap in `MainActor.assumeIsolated { … }` following the existing pattern in `TmuxPaneContainer` (~line 360). Do NOT introduce a `paneID(for: Terminal)` reverse lookup — the tmux closure captures its own `pane` directly (each view knows which pane it is at construction).

- [ ] **Step 4: Prime the mode once at pane mount**

The overrides only fire on *changes*. Right after wiring `onModeRelevantChange`, call `modeTracker.recompute(...)` once with the view's terminal (`view.getTerminal()`) so a pane that starts on the alt-screen (reattach into a running vim/Claude) is correct from frame one. Tmux: in the pane-creation path. Raw: in `makeUIView` after the terminal is built.

- [ ] **Step 5: Delete the render-time mode poll (keep the mouse-dot visual)**

In `TmuxPaneContainer.updateMouseDots` and `TerminalScreen.updateMouseDot`, remove the `mouseMode != .off && isCurrentBufferAlternate` recomputation. Drive the mouse-dot's `isHidden` from `modeTracker.mode(for:)` instead (show when `.appOwnsInput`, or `.mouseReporting`). Wire `modeTracker.onChange` to refresh the dot. Do NOT delete the dot views themselves.

- [ ] **Step 6: Build on macOS CI**

Push the branch; the `macos` CI job (~15–18 min) is the only compile signal. Expected: green. Fix any Swift-6/`@MainActor` isolation errors surfaced only there (the delegate callbacks are nonisolated → hop to `@MainActor`; follow the existing `Task { @MainActor in … }` pattern already in `TmuxPaneContainer` ~line 360).

- [ ] **Step 7: Device trace — PROVE the events fire (foundation gate)**

On device with Diagnostics→gesture enabled: attach a tmux session, open a plain shell pane (expect `mode -> localScroll`), launch Claude Code (expect `mode -> appOwnsInput`), quit Claude (expect `mode -> localScroll`), run `htop` (expect `appOwnsInput`). Confirm the `mode[…] ->` log lines appear at each transition.
Expected: transitions logged. **If no transition logs appear, STOP** — the `PaneTerminalView` overrides aren't firing (wrong signature, or the constructed view isn't the subclass); re-check Step 2's signature match and Step 3's construction before proceeding.

- [ ] **Step 8: Commit**

```bash
git add App/PaneModeTracker.swift App/PaneTerminalView.swift App/TmuxPaneContainer.swift App/TerminalScreen.swift
git commit -m "feat(terminal): event-driven InteractionMode via PaneTerminalView override (retire render-poll)"
```

---

## Task 5: Route the tap-cursor path through the Kit DECCKM encoder (App, DRY)

**Files:**
- Modify: `App/TerminalScreen.swift` (`Coordinator.encodeArrowRun` private method + `placeCursor`)
- Modify: `App/ConnectionViewModel.swift` (`placeTmuxCursor`)

**Interfaces:**
- Consumes: `encodeArrowRun(_:applicationCursorKeys:)` (Task 3); the existing `activePaneApplicationCursor()` in `ConnectionViewModel` (reads the active pane's DECCKM).

**Why now:** this replaces two hardcoded-CSI copies with the DECCKM-aware Kit encoder before Task 6 adds a *third* caller (the drag path). Do it once, correctly, first. This also fixes a latent bug: tap-to-place-cursor sends CSI even when the app is in application-cursor mode.

- [ ] **Step 1: Replace `TerminalScreen.Coordinator.encodeArrowRun`**

Delete the private `encodeArrowRun(_ run: ArrowRun) -> [UInt8]` method (the one hardcoding `ESC [ A`). In `placeCursor`, read DECCKM from the view's terminal and call the Kit encoder:
```swift
func placeCursor(toCol: Int, toRow: Int, in view: TerminalView) {
    let term = view.getTerminal()
    let cur = term.getCursorLocation()   // .x = col, .y = row
    let appCursor = term.applicationCursor
    let runs = cursorTapArrows(fromCol: cur.x, fromRow: cur.y, toCol: toCol, toRow: toRow)
    for run in runs {
        let bytes = encodeArrowRun(run, applicationCursorKeys: appCursor)  // Kit encoder
        if !bytes.isEmpty { onSend(bytes) }
    }
}
```

- [ ] **Step 2: Replace the inline encode in `ConnectionViewModel.placeTmuxCursor`**
```swift
func placeTmuxCursor(_ view: TerminalView, toCol: Int, toRow: Int) {
    let term = view.getTerminal()
    let cur = term.getCursorLocation()
    let appCursor = term.applicationCursor
    let runs = cursorTapArrows(fromCol: cur.x, fromRow: cur.y, toCol: toCol, toRow: toRow)
    var bytes: [UInt8] = []
    for run in runs { bytes += encodeArrowRun(run, applicationCursorKeys: appCursor) }
    guard !bytes.isEmpty else { return }
    sendTerminalInput(bytes)
}
```

- [ ] **Step 3: Build on macOS CI**

Push; expected green. No new local test (App tier). The Kit encoder's behavior is already covered by Task 3's `ArrowEncodingTests`.

- [ ] **Step 4: Commit**

```bash
git add App/TerminalScreen.swift App/ConnectionViewModel.swift
git commit -m "refactor(terminal): route tap-cursor arrows through Kit DECCKM encoder (fixes CSI-in-appmode)"
```

---

## Task 6: Mode-driven gesture routing + alt-screen drag→arrows (App, the core)

**Files:**
- Modify: `App/TerminalGestureController.swift`
- Modify: `App/TmuxPaneContainer.swift` + `App/TerminalScreen.swift` (construct the controller with the new callbacks; wire `modeTracker.onChange` → controller)

**Interfaces:**
- Consumes: `InteractionMode`, `AltScreenScroll.arrows(...)`, `encodeArrowRun(_:applicationCursorKeys:)`, `PaneModeTracker`.
- Produces (controller `Callbacks` gains): `currentMode: () -> InteractionMode`, `applicationCursorKeys: () -> Bool`, `sendBytes: ([UInt8]) -> Void`, `cellHeight: () -> CGFloat`. The controller gains `func setScrollEnabled(_:)`-style behavior via the mount reacting to mode changes.

- [ ] **Step 1: Extend `Callbacks` and add begin-snapshot state**

In `TerminalGestureController`, replace `mouseReportingActive: () -> Bool` with:
```swift
let currentMode: () -> InteractionMode
let applicationCursorKeys: () -> Bool
let sendBytes: ([UInt8]) -> Void
```
Add stored per-gesture snapshot fields:
```swift
private var dragMode: InteractionMode = .localScroll     // snapped at .began
private var dragAppCursor: Bool = false                  // DECCKM snapped at .began
private var emittedCells: Int = 0                        // AltScreenScroll running total
```

- [ ] **Step 2: Rewrite `handleScrollViewPan` to route by mode**

```swift
@objc private func handleScrollViewPan(_ g: UIPanGestureRecognizer) {
    guard let view = terminalView else { return }
    switch g.state {
    case .began:
        dragMode = currentMode()                 // snapshot mode + DECCKM once
        dragAppCursor = applicationCursorKeys()
        emittedCells = 0
    case .changed:
        guard dragMode == .appOwnsInput else { return }  // only alt-screen streams arrows
        let term = view.getTerminal()
        let cellH = view.bounds.height / CGFloat(max(term.rows, 1))
        let (runs, newEmitted) = AltScreenScroll.arrows(
            totalDy: Double(g.translation(in: view).y),
            cellHeight: Double(cellH),
            emittedCells: emittedCells)
        emittedCells = newEmitted
        for run in runs {
            let bytes = encodeArrowRun(run, applicationCursorKeys: dragAppCursor)
            if !bytes.isEmpty { sendBytes(bytes) }
        }
    case .ended, .cancelled:
        // Window-switch resolves once, from cumulative translation, in ANY mode
        // that lets us own the horizontal axis (not mouseReporting).
        guard dragMode != .mouseReporting else { return }
        let t = g.translation(in: view)
        let decision = GestureClassifier.classify(
            dx: Double(t.x), dy: Double(t.y),
            isMultiWindowTmux: callbacks.isMultiWindowTmux())
        if case .switchWindow(let delta) = decision { callbacks.onSwitchWindow(delta) }
    default: break
    }
}
```
> Note: in `localScroll` the `.changed` branch returns immediately, so SwiftTerm's native scroll (still enabled) owns the vertical drag untouched — no competing emission. In `appOwnsInput`, the mount has set `isScrollEnabled = false` (Step 5), so SwiftTerm's pan is inert and only our arrow stream moves.

- [ ] **Step 3: Route single-tap by mode**

```swift
@objc private func handleSingleTap(_ g: UITapGestureRecognizer) {
    guard let view = terminalView else { return }
    switch currentMode() {
    case .mouseReporting, .appOwnsInput:
        // App owns clicks: let SwiftTerm forward as mouse (allowMouseReporting is
        // set true by the mount in these modes). We no-op here so we don't also
        // place a cursor. If the app didn't actually request mouse, this is a
        // harmless no-op (matches spec: alt-screen tap → mouse-if-requested, else nothing).
        return
    case .localScroll:
        let action = tapAction(hasSelection: callbacks.hasSelection())
        switch action {
        case .clearSelection: callbacks.clearSelection()
        case .placeCursor:
            let target = cell(at: g.location(in: view), in: view)
            callbacks.onPlaceCursor(target.col, target.row)
        }
    }
}
```
> Double/triple-tap selection handlers are unchanged — per spec they stay local in ALL modes (Blink/iTerm2 parity), so no mode gate is added there.

- [ ] **Step 4: Update both mounts to construct the new `Callbacks`**

In `TmuxPaneContainer` and `TerminalScreen`, where the controller is built: pass `currentMode: { [modeTracker, pane] in modeTracker.mode(for: pane) }` (tmux — `pane` is the non-optional `PaneID`, which binds to the `PaneID?` parameter) / `{ modeTracker.mode }` (raw); `applicationCursorKeys: { [weak view] in view?.getTerminal().applicationCursor ?? false }`; `sendBytes:` → the existing send path (`onSend` / `viewModel.sendTerminalInput`); remove the old `mouseReportingActive:` argument.

- [ ] **Step 5: Flip `isScrollEnabled` + `allowMouseReporting` on mode change**

Wire `modeTracker.onChange = { pane, mode in … }` (per mount) to update that pane's view:
```swift
let ownsScroll = (mode == .localScroll)
view.isScrollEnabled = ownsScroll                // documented UIScrollView API, NOT panGestureRecognizer.isEnabled
view.allowMouseReporting = (mode == .mouseReporting || mode == .appOwnsInput)
```
> This replaces the old per-render `allowMouseReporting = forwardMouse` assignment. `isScrollEnabled` cleanly parks SwiftTerm's native pan in `appOwnsInput` without the dirty-`isTracking` hazard of toggling the recognizer.

- [ ] **Step 6: Build on macOS CI**

Push; expected green. Resolve isolation/capture-list errors surfaced only on the macOS job.

- [ ] **Step 7: Device trace — the three modes behave**

With Diagnostics→gesture on:
- **Plain shell (localScroll):** vertical drag scrolls native scrollback (unchanged); clear horizontal swipe switches tmux window; tap places cursor. `gr:scrollPan` shows no arrow emission.
- **Claude/vim (appOwnsInput):** vertical drag scrolls the APP (Claude history moves), logs show `AltScreenScroll` arrows; `isScrollEnabled=false`; single-tap forwards to the app (no local cursor jump); horizontal swipe still switches window; double-tap still selects visible text.
- **A normal-screen mouse app (mouseReporting):** drag/tap forward as mouse; native scroll not stolen.

- [ ] **Step 8: Commit**

```bash
git add App/TerminalGestureController.swift App/TmuxPaneContainer.swift App/TerminalScreen.swift
git commit -m "feat(terminal): mode-driven gesture routing + alt-screen drag->arrows (retire binary mouse-gate)"
```

---

## Task 7: Remove the retired `mouseReportingActive` seam + dead poll code (App, cleanup)

**Files:**
- Modify: `App/TerminalGestureController.swift`, `App/TmuxPaneContainer.swift`, `App/TerminalScreen.swift`

- [ ] **Step 1: Grep for stragglers**

Run (host): `grep -rn "mouseReportingActive\|forwardMouse\|mouseMode != .off" App/`
Expected after Task 6: zero functional uses (only comments, if any). Remove any remaining `forwardMouse` locals and the `mouseReportingActive` callback field/type if still declared.

- [ ] **Step 2: Confirm the controller's doc-comment matches reality**

Update the `TerminalGestureController` header comment: it currently describes the "we set `allowMouseReporting = true` and let SwiftTerm forward … via the `mouseReportingActive` guard" model. Replace with the mode-driven description (snapshot at `.began`; `appOwnsInput` streams `AltScreenScroll` arrows; `isScrollEnabled` parks native scroll).

- [ ] **Step 3: Build on macOS CI**

Push; expected green.

- [ ] **Step 4: Commit**

```bash
git add App/TerminalGestureController.swift App/TmuxPaneContainer.swift App/TerminalScreen.swift
git commit -m "refactor(terminal): drop retired mouseReportingActive seam + render-poll remnants"
```

---

## Task 8: Full regression pass + PR

- [ ] **Step 1: Full Kit suite**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS (all Kit + SeedKit). Confirms Tasks 1–3 still green after the App work.

- [ ] **Step 2: Rust unaffected — sanity only if touched**

This change touches no Rust; skip `cargo test` unless `crates/` changed (it didn't).

- [ ] **Step 3: Device regression matrix (record in the PR)**

Confirm on device, tmux + raw:
- localScroll: native scroll, swipe-switch, tap-place, double/triple-select, long-press-zoom, edit menu.
- appOwnsInput (Claude, vim, htop, less): drag→app-scroll smooth + no jitter, no offset desync on a later tap, swipe-switch still works, visible-text select works, single-tap reaches the app.
- mouseReporting (a normal-screen mouse app): mouse events reach the app; native scroll not hijacked.
- Reattach into a running alt-screen app → starts in `appOwnsInput` (Task 4 Step 4 priming).

- [ ] **Step 4: Open the PR**

```bash
git push -u github HEAD
gh pr create --repo ds7n/semicolyn --title "feat(terminal): interaction-mode redesign (event-driven mode + alt-screen drag->arrows)" \
  --body "Implements docs/superpowers/specs/2026-07-12-terminal-interaction-mode-design.md. Replaces the binary mouse-gate straddle with a tracked InteractionMode (localScroll/appOwnsInput/mouseReporting) driven by bufferActivated/mouseModeChanged delegate events; per-mode drag ownership via isScrollEnabled; alt-screen drag->arrows (DECCKM-aware); mode+DECCKM snapshotted at gesture-begin; one PaneModeTracker shared by both mounts. Kit: InteractionMode, AltScreenScroll, encodeArrowRun (all Linux-tested). Fixes: Claude-Code-no-scroll, alt-screen tap no-op, tap-cursor CSI-in-appmode, duplicated mode derivation."
```
Expected: macOS CI green, then squash-merge.

---

## Self-Review

**1. Spec coverage:**
- §2 mode-switched hybrid decision → Tasks 4–6 realize it (native scroll kept in localScroll; owned in appOwnsInput). ✓
- §3 `InteractionMode` + `resolveMode` + alt precedence → Task 1. ✓
- §3 event-driven update via `bufferActivated`/`mouseModeChanged`, retire poll → Task 4. ✓
- §3 snapshot mode + DECCKM at `.began` → Task 6 Step 1–2. ✓
- §4 drag ownership via `isScrollEnabled` → Task 6 Step 5. ✓
- §4 tap/selection routing (alt tap→mouse, selection stays local) → Task 6 Step 3 + note. ✓
- §4 live 1:1 clamped arrows during `.changed` → Task 2 + Task 6 Step 2. ✓
- §5 `AltScreenScroll` owns the clamp constant → Task 2 (`maxCellsPerEmit`). ✓
- §5 one shared `PaneModeTracker`, no mount divergence → Task 4. ✓
- §5 DECCKM-aware encoder reused by tap + drag → Task 3 (encoder), Task 5 (tap), Task 6 (drag). ✓
- §5 mouse-dot sourced from mode not poll → Task 4 Step 5. ✓
- §8 testing (EP/BVA/anti-flood/negative) → Tasks 1–3 tests; device matrix Task 8. ✓
- §10 binding decisions untouched → GestureClassifier unchanged; no CursorDragEngine revival. ✓

**2. Placeholder scan:** No "TBD/handle appropriately"; every code step shows code; the two "adjust if the actual initializer differs" notes point at a concrete grep + fallback, not a vague instruction. ✓

**3. Type consistency:** `AltScreenScroll.arrows(totalDy:cellHeight:emittedCells:) -> (runs:[ArrowRun], newEmittedCells:Int)` used identically in Task 2 and Task 6. `encodeArrowRun(_:applicationCursorKeys:)` identical across Tasks 3/5/6. `ArrowRun(direction:count:)` matches the real struct in `CursorArrowStream.swift`. `resolveMode(isAltScreen:mouseReporting:)` identical in Tasks 1/4. `PaneModeTracker.mode(for:)`/`recompute(for:terminal:)`/`onChange` consistent Task 4↔6. ✓
