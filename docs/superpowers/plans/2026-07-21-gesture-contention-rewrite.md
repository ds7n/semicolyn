<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Gesture Contention Rewrite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the horizontal tmux-window-switch swipe reliable at a plain shell by making SwiftTerm's scroll pan the single authoritative drag owner and subordinating its lazily-created selection pan.

**Architecture:** Keep SwiftTerm's `TerminalView` (a `UIScrollView`) and its engine. In the App-only `TerminalGestureController`, (1) snapshot the scroll `contentOffset` at drag start and restore it the instant `DragAxisLock` resolves to a window-switch (erasing the tiny accidental vertical scroll), and (2) catch SwiftTerm's lazily-created selection pan the moment it appears and durably subordinate it to the scroll pan (activating the existing dead-code failure rule). The one genuinely new decision (restore-or-not) is extracted as a pure, Linux-tested Kit decider.

**Tech Stack:** Swift 6, SwiftTerm (pinned commit 58915b1), UIKit gesture recognizers (App tier, macOS-CI + device verified), XCTest (Kit tier, Linux). Docker dev image `semicolyn-dev` for `swift test`.

## Global Constraints

- Every source file carries an SPDX header: `// SPDX-FileCopyrightText: 2026 True Positive LLC` / `// SPDX-License-Identifier: GPL-3.0-only`.
- No em-dashes in any generated output (prose, code, comments, commits). Use a colon, parentheses, a semicolon, or two sentences.
- Conventional commits (`feat:` / `fix:` / `refactor:` / `test:` / `docs:`).
- `Sources/SemicolynKit/` is the platform-agnostic, Linux-tested tier: NO `import UIKit` / `SwiftUI` / `CryptoKit`. Pure logic only.
- `App/` is the Apple-only tier: does NOT compile on Linux and is invisible to `swift test`. Validate via macOS CI + device, never locally.
- Tests must be real (equivalence-partitioning + boundary values; assert exact observable values, no tautologies; a negative test asserts the specific failure).
- Kit tests run in Docker: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`.
- `@MainActor` delegate-callback trap: `DebugLog.shared.log` / UIKit reads / `AppStores.shared` are `@MainActor`; SwiftTerm `@objc` delegate + gesture callbacks are nonisolated -> wrap in `MainActor.assumeIsolated {}`. (UIView overrides and `@objc` selectors on an `@MainActor` class do NOT need it.)
- Scope: gesture arbitration ONLY. Do NOT touch the `commitSwitchDrag` transform-slide / both-ready-gate / hidden-pane-settle machinery in `TmuxPaneContainer.swift`, nor tmux control-mode / rendering (that is the separate capture-pane follow-up spec).

**Spec:** `docs/superpowers/specs/2026-07-21-gesture-contention-rewrite-design.md`.

---

### Task 1: Pure offset-restore decider (Kit)

The one genuinely new piece of logic: given the resolved drag axis, decide whether the scroll offset accidentally moved during the pre-lock dead-zone should be restored, and to what. Extracting it as a pure decider keeps the App-layer change to a one-line call of a Linux-tested function (mirrors the `DragAxisLock` / `SwitchCommitDecision` pure-decider pattern).

**Files:**
- Create: `Sources/SemicolynKit/Terminal/ScrollResidueDecision.swift`
- Test: `Tests/SemicolynKitTests/ScrollResidueDecisionTests.swift`

**Interfaces:**
- Consumes: `DragAxis` (existing, in `DragAxisLock.swift`: `.pending` / `.scroll` / `.switchWindow(delta:)`).
- Produces: `enum ScrollRestore: Equatable, Sendable { case keep; case restore(toX: Double, toY: Double) }` and `struct ScrollResidueDecision { static func resolve(axis: DragAxis, savedX: Double, savedY: Double) -> ScrollRestore }`.

- [ ] **Step 1: Write the failing test**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Restore the pre-drag scroll offset ONLY when the drag locks to a window switch
/// (the native scroll pan nudged the buffer during the dead-zone before we locked).
/// Scroll and still-pending drags keep their live offset.
final class ScrollResidueDecisionTests: XCTestCase {
    // EP: switch-locked -> restore to the saved offset exactly.
    func testSwitchRestoresToSavedOffset() {
        XCTAssertEqual(
            ScrollResidueDecision.resolve(axis: .switchWindow(delta: -1), savedX: 3, savedY: 42),
            .restore(toX: 3, toY: 42))
    }

    // EP: the delta sign does not change the restore target (both switch directions restore).
    func testSwitchOtherDirectionAlsoRestores() {
        XCTAssertEqual(
            ScrollResidueDecision.resolve(axis: .switchWindow(delta: +1), savedX: 0, savedY: 7),
            .restore(toX: 0, toY: 7))
    }

    // EP: scroll axis -> keep the live offset (native scroll must run free).
    func testScrollKeepsLiveOffset() {
        XCTAssertEqual(
            ScrollResidueDecision.resolve(axis: .scroll, savedX: 3, savedY: 42),
            .keep)
    }

    // BVA: still-pending (inside dead-zone) -> keep (no decision yet).
    func testPendingKeepsLiveOffset() {
        XCTAssertEqual(
            ScrollResidueDecision.resolve(axis: .pending, savedX: 3, savedY: 42),
            .keep)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ScrollResidueDecisionTests`
Expected: FAIL (compile error: `ScrollResidueDecision` / `ScrollRestore` not defined).

- [ ] **Step 3: Write minimal implementation**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Whether to restore the terminal's scroll offset after a drag's axis resolves.
public enum ScrollRestore: Equatable, Sendable {
    /// Keep the live offset (a scroll drag, or not yet decided).
    case keep
    /// Restore the offset captured at drag start (a switch drag: undo the tiny
    /// vertical nudge the native scroll pan made during the pre-lock dead-zone).
    case restore(toX: Double, toY: Double)
}

/// Pure decision for the pre-lock scroll residue. The native `UIScrollView` pan
/// commits on first movement (no dead-zone), so a horizontal drag can nudge the
/// buffer a few points before `DragAxisLock` resolves to `.switchWindow`. When it
/// does, restore the offset captured at `.began`; otherwise keep the live offset.
public struct ScrollResidueDecision: Sendable {
    public static func resolve(axis: DragAxis, savedX: Double, savedY: Double) -> ScrollRestore {
        guard case .switchWindow = axis else { return .keep }
        return .restore(toX: savedX, toY: savedY)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ScrollResidueDecisionTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Terminal/ScrollResidueDecision.swift Tests/SemicolynKitTests/ScrollResidueDecisionTests.swift
git commit -m "feat(gestures): pure ScrollResidueDecision decider (restore offset on switch-lock)"
```

---

### Task 2: Snapshot + restore the scroll offset on switch-lock (App)

Wire Task 1's decider into the live drag path. Capture `contentOffset` at drag `.began`; on the frame `DragAxisLock` resolves to `.switchWindow`, restore it so the accidental vertical scroll from the dead-zone is erased before the page-turn begins.

App tier: NOT Linux-testable. Verified by macOS CI compile + device. The restore LOGIC is already covered by Task 1's Kit tests; this task is the thin wiring.

**Files:**
- Modify: `App/TerminalGestureController.swift`
  - `beginDrag(_:on:)` (around lines 323-354): add the offset snapshot.
  - `driveLiveSwitch(_:in:)` (around lines 360-401): at the moment the axis first resolves to switch, apply the restore.
  - Add a stored property near the other per-drag snapshot state (around lines 73-85).

**Interfaces:**
- Consumes: `ScrollResidueDecision.resolve(axis:savedX:savedY:)` -> `ScrollRestore` (Task 1); `terminalView.contentOffset` (SwiftTerm `UIScrollView`).
- Produces: no new public surface (internal wiring only).

- [ ] **Step 1: Add the per-drag saved-offset property**

In `App/TerminalGestureController.swift`, in the "Per-gesture snapshot state" block (near `private var dragAxis: DragAxis = .pending`), add:

```swift
    /// Scroll `contentOffset` captured at this drag's `.began`, so a switch-lock can
    /// restore it and erase the tiny vertical scroll the native pan made during the
    /// pre-lock dead-zone (`ScrollResidueDecision`). Reset each drag.
    private var savedContentOffset: CGPoint = .zero
```

- [ ] **Step 2: Snapshot the offset in `beginDrag`**

In `beginDrag(_:on:)`, immediately after `stopAltScreenFling()` and before `dragMode = callbacks.currentMode()`, add:

```swift
        // Capture the scroll offset so a switch-lock can undo any accidental scroll the
        // native pan made during the pre-lock dead-zone (ScrollResidueDecision, Kit).
        savedContentOffset = view.contentOffset
```

- [ ] **Step 3: Restore the offset when the axis locks to switch**

In `driveLiveSwitch(_:in:)`, inside the `if !switchRevealStarted { ... }` block (which runs exactly once, on the first switch-locked frame), BEFORE `callbacks.onDragBeginSwitch()`, add:

```swift
            // Undo the dead-zone scroll residue now that we know this is a switch (Kit decider).
            if case let .restore(toX, toY) = ScrollResidueDecision.resolve(
                axis: dragAxis, savedX: Double(savedContentOffset.x), savedY: Double(savedContentOffset.y)) {
                view.contentOffset = CGPoint(x: toX, y: toY)
                DebugLog.shared.log(.gesture,
                    "drag-switch restore-offset x=\(Int(toX)) y=\(Int(toY))")
            }
```

Note: this is inside a `UIGestureRecognizer` `@objc`-selector-driven call chain on an `@MainActor` class (`handleScrollViewPan` / `handleAltScreenPan` are `@objc` on the `@MainActor` controller), so no `MainActor.assumeIsolated` wrap is needed here (per the trap rule: `@objc` selectors on an `@MainActor` class do not need it, and `DebugLog.shared.log` is reached from that already-isolated context).

- [ ] **Step 4: Verify it compiles on macOS CI**

This is App-tier; it does NOT build on Linux. Push the branch and confirm the `macos` CI job compiles. Do NOT rely on `swift test` here.

Run (after pushing): `gh run watch` or check the `macos` job for the branch.
Expected: `macos` job compiles green (the Linux `linux-swift` / `linux-rust` / `lint` jobs cover Kit + Rust).

- [ ] **Step 5: Commit**

```bash
git add App/TerminalGestureController.swift
git commit -m "feat(gestures): restore scroll offset on switch-lock (erase dead-zone residue)"
```

---

### Task 3: Catch SwiftTerm's selection pan at birth and subordinate it (App)

The root-cause fix for the intermittency. SwiftTerm creates `panSelectionGesture` lazily (first selection), after our init sweep. Detect it the moment it appears, set its `.delegate = self` once (activating the existing dead-code `shouldRequireFailureOf` rule) and call `require(toFail: scrollPan)` as redundant insurance. Keep the existing per-`.began` `disableStraySwiftTermPans` scan as a second-layer fallback.

App tier: verified by macOS CI compile + device.

**Files:**
- Modify: `App/TerminalGestureController.swift`
  - Add a `subordinateSelectionPan(on:)` helper.
  - Call it from `beginDrag` (before the existing `disableStraySwiftTermPans` call) and from the tap handlers that can trigger selection (`handleDoubleTap`, `handleTripleTap`) so the pan is caught the instant a selection is created.
  - The existing delegate method `gestureRecognizer(_:shouldRequireFailureOf:)` (lines 748-751) already returns the correct answer; it just needs the selection pan to have `self` as delegate.

**Interfaces:**
- Consumes: `terminalView.gestureRecognizers`, `view.panGestureRecognizer` (SwiftTerm scroll pan), the existing `role(of:)` classifier, the existing `ours` array.
- Produces: no new public surface (internal wiring only).

- [ ] **Step 1: Add the `subordinateSelectionPan` helper**

In `App/TerminalGestureController.swift`, in the `// MARK: Setup` region (near `disableStraySwiftTermPans`), add:

```swift
    /// Durably subordinate SwiftTerm's LAZILY-created selection/mouse pan to the native
    /// scroll pan, at the moment it first exists. Unlike `disableStraySwiftTermPans` (a
    /// per-drag scan that misses the case where the selection pan WINS arbitration before
    /// our `.began` handler runs), this wires the pan into the failure tree ONCE: it sets
    /// our delegate (so the existing `shouldRequireFailureOf` selectionPan-vs-scrollPan
    /// rule fires) and calls `require(toFail:)` directly as redundant insurance. Idempotent
    /// (re-setting the same delegate / re-adding the same failure requirement is a no-op).
    private func subordinateSelectionPan(on view: TerminalView) {
        let scrollPan = view.panGestureRecognizer
        for gr in view.gestureRecognizers ?? [] where
            gr is UIPanGestureRecognizer
            && gr !== scrollPan            // not the scroll pan (our authoritative owner)
            && !ours.contains(gr) {        // not one of ours
            if gr.delegate !== self {
                gr.delegate = self
                gr.require(toFail: scrollPan)
                DebugLog.shared.log(.gesture,
                    "selectionPan subordinated (delegate+require-fail vs scrollPan)")
            }
        }
    }
```

- [ ] **Step 2: Call it at drag start (before the fallback scan)**

In `beginDrag(_:on:)`, immediately BEFORE the existing `disableStraySwiftTermPans(on: view)` call, add:

```swift
        // Primary fix: durably subordinate the selection pan the instant it exists.
        subordinateSelectionPan(on: view)
```

- [ ] **Step 3: Call it right after a selection is created (catch at true birth)**

In `handleDoubleTap(_:)`, immediately AFTER `view.setSelectionRange(...)`, add:

```swift
        subordinateSelectionPan(on: view)   // the selection pan is created now; subordinate it at birth
```

In `handleTripleTap(_:)`, immediately AFTER `view.setSelectionRange(...)`, add:

```swift
        subordinateSelectionPan(on: view)   // the selection pan is created now; subordinate it at birth
```

These run on `@objc` tap selectors of the `@MainActor` controller, so no `MainActor.assumeIsolated` wrap is needed.

- [ ] **Step 4: Confirm the delegate method already handles it (no change, read-only verify)**

Confirm `gestureRecognizer(_:shouldRequireFailureOf:)` (around lines 748-751) reads:

```swift
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        return role(of: g) == .selectionPan && role(of: other) == .scrollPan
    }
```

This is the previously-dead code that Step 2/3 activate by setting the delegate. No edit needed; just verify it is present and unchanged.

- [ ] **Step 5: Verify it compiles on macOS CI**

App-tier; does NOT build on Linux. Push and confirm the `macos` job compiles green.

- [ ] **Step 6: Commit**

```bash
git add App/TerminalGestureController.swift
git commit -m "fix(gestures): subordinate SwiftTerm selection pan at birth (kill drag-steal race)"
```

---

### Task 4: Regression guard for the existing deciders + simultaneity policy (Kit)

Lock in that the untouched pure deciders and the simultaneity policy still behave, so the App wiring can only regress on device, never silently in Kit. This is a verification task (no production change) that also documents the selection-vs-scroll invariant the App layer now depends on.

**Files:**
- Modify: `Tests/SemicolynKitTests/GestureSimultaneityTests.swift` (add one explicit assertion if not already present).

**Interfaces:**
- Consumes: `gesturesMayRecognizeSimultaneously(_:_:)`, `GestureRole` (existing).
- Produces: none (test-only).

- [ ] **Step 1: Add the selection-vs-scroll exclusivity assertion**

Append to `Tests/SemicolynKitTests/GestureSimultaneityTests.swift` (inside the existing `final class GestureSimultaneityTests: XCTestCase {` body):

```swift
    // The invariant the App's selection-pan subordination relies on: the selection pan
    // and the scroll pan must NEVER co-recognize (else a drag selects instead of scrolls).
    func testSelectionPanAndScrollPanAreMutuallyExclusive() {
        XCTAssertFalse(gesturesMayRecognizeSimultaneously(.selectionPan, .scrollPan))
        // Order-independent (the policy sets the pair).
        XCTAssertFalse(gesturesMayRecognizeSimultaneously(.scrollPan, .selectionPan))
    }

    // Guard the OTHER direction: pinch must still coexist with the scroll pan, or a stray
    // second finger would kill scrolling.
    func testPinchStillCoexistsWithScrollPan() {
        XCTAssertTrue(gesturesMayRecognizeSimultaneously(.pinch, .scrollPan))
    }
```

- [ ] **Step 2: Run the full Kit gesture suite to verify green**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter "DragAxisLockTests|SwitchCommitDecisionTests|WindowDragModelTests|GestureSimultaneityTests|ScrollResidueDecisionTests"`
Expected: PASS (all gesture deciders + the new ScrollResidueDecision, including the two new assertions).

- [ ] **Step 3: Commit**

```bash
git add Tests/SemicolynKitTests/GestureSimultaneityTests.swift
git commit -m "test(gestures): assert selection-vs-scroll exclusivity invariant (App subordination guard)"
```

---

### Task 5: Full Kit suite green + push for macOS CI + device-verify handoff

Final integration gate. The App-tier changes (Tasks 2, 3) are only verifiable on device, per the standing rule for App-tier gesture changes.

**Files:** none (verification + docs only).

- [ ] **Step 1: Run the complete Kit test suite**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS (the full SemicolynKit + SeedKit suite; the prior baseline was ~1326 green plus the 4 new ScrollResidueDecision tests + 2 new GestureSimultaneity assertions).

- [ ] **Step 2: Push and confirm all CI jobs**

```bash
git push origin feat/finger-drag-window-transition
```

Confirm: `linux-swift`, `linux-rust`, `lint` green, and critically the `macos` job compiles green (the only Apple-tier build signal). If `linux-rust` flakes with "sshd fixtures not reachable", rerun that job only: `gh run rerun <id> --failed`.

- [ ] **Step 3: Device verification (the acceptance gate)**

Build to device / TestFlight and verify the edge-case matrix from the spec:
  - Plain-shell horizontal switch works reliably across repeated attempts (the fix).
  - Selection-then-switch: create a text selection (double-tap), then repeatedly swipe to switch; the swipe must NOT be swallowed as a selection (the intermittent case, now durable).
  - Vertical scroll + momentum unaffected at a plain shell.
  - Diagonal drag resolves sanely (biased to scroll on ties).
  - Fast horizontal flick commits a switch.
  - Hold-then-drag does not start a text selection.
  - Alt-screen (Claude/vim) window switch still works.
  - No visible vertical twitch at the start of a horizontal switch (offset-restore working).

- [ ] **Step 4: Record the outcome**

On device-verify PASS, note the build/commit in `TODO.md` and update the `gesture-arch-rethink-2026-07-21` memory to "gesture contention rewrite device-VERIFIED", then the capture-pane follow-up spec becomes the next work. On FAIL, capture a device log with the `gesture` + `render` categories on and diagnose against the edge-case table before iterating.

---

## Self-Review

**Spec coverage:**
- Contention model (one drag owner, interpret scroll-pan stream): the model is inherent (no new recognizer added); Tasks 2-3 implement the two behaviors that make it correct. Covered.
- Component A (offset snapshot/restore): Task 1 (pure decider) + Task 2 (wiring). Covered.
- Component B (selection-pan-at-birth): Task 3. Covered.
- Component C (retain per-`.began` scan as insurance): Task 3 explicitly keeps `disableStraySwiftTermPans` and layers `subordinateSelectionPan` before it. Covered.
- Component D (wire the dead code): Task 3 Step 4 activates the existing `shouldRequireFailureOf`. Covered.
- Testing: Kit pure-seam test (Task 1) + regression guard (Task 4) + full-suite/device gate (Task 5). Covered.
- Out-of-scope (commit machinery / capture-pane / ET) explicitly untouched: enforced by the Global Constraints scope line and by no task touching `TmuxPaneContainer.swift`. Covered.

**Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to Task N". Every code step shows complete code. App-tier steps that cannot run locally say so explicitly and route to macOS CI + device (not a placeholder; the correct verification path for that tier).

**Type consistency:** `ScrollResidueDecision.resolve(axis:savedX:savedY:) -> ScrollRestore` is defined in Task 1 and consumed with the identical signature in Task 2 Step 3. `ScrollRestore.restore(toX:toY:)` / `.keep` match between definition, tests, and the App call site. `subordinateSelectionPan(on:)` is defined and called with the same signature in Task 3. `DragAxis` cases (`.pending` / `.scroll` / `.switchWindow(delta:)`) match `DragAxisLock.swift`. `GestureRole.selectionPan` / `.scrollPan` / `.pinch` match `GestureSimultaneity.swift`.
