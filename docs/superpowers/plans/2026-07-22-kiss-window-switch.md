<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# KISS Window Switch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Strip the tmux window switch to its core: horizontal swipe on release past threshold sends `select-window`, tmux redraws. Delete all switch-animation and async-handoff machinery.

**Architecture:** Keep the gesture-detection deciders (`DragAxisLock`, `SwitchCommitDecision`) and the `select-window` action. Delete the live-drag slide, card-dim, both-ready gate, hidden-pane settle, timeout/generation guards, offset-restore, and the `paneContentView` wrapper (panes parent directly into `ContainerView`). Remove the now-dead Kit deciders and their tests.

**Tech Stack:** Swift 6, SwiftTerm, UIKit (App tier, macOS-CI + device verified), XCTest (Kit tier, Linux/Docker).

## Global Constraints

- SPDX header on every source file: `// SPDX-FileCopyrightText: 2026 True Positive LLC` / `// SPDX-License-Identifier: GPL-3.0-only`.
- No em-dashes anywhere (prose, code, comments, commits). Colon / parens / semicolon / two sentences instead.
- Conventional commits (`refactor:` / `fix:` / `test:` / `docs:`). This effort is mostly `refactor:` (deletion).
- `Sources/SemicolynKit/`: platform-agnostic, Linux-tested, no `import UIKit`/`SwiftUI`.
- `App/`: Apple-only, NOT Linux-buildable, invisible to `swift test`. Verify via macOS CI + device.
- `@MainActor` delegate-callback trap: wrap `DebugLog.shared.log`/UIKit/`AppStores.shared` reached from SwiftTerm `@objc`/delegate callbacks in `MainActor.assumeIsolated {}` (but NOT needed for UIView overrides or `@objc` selectors on an `@MainActor` class).
- Kit tests via Docker: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`.
- KISS/no-hoarding: DELETE dead code, do not leave inert wrappers or "just in case" state. git revert is the safety net.

**Spec:** `docs/superpowers/specs/2026-07-22-kiss-window-switch-design.md`.

**Deletion inventory (verified against current source):**
- Coordinator methods (`App/TmuxPaneContainer.swift`): `beginSwitchReveal`, `updateSwitchDrag`, `updateCardDim`, `clearCardDim`, `commitSwitchDrag`, `cancelSwitchDrag`, `clearPendingSwitch`, `discardCommittedSnapshot`, `failPendingSwitch`, `finishSwitchHandoffIfReady`, `completePendingSwitchIfNeeded`.
- Coordinator state: `pendingSwitchTimeout`, `pendingSwitchWindow`, `switchAnimDone`, `switchDelivered`, `switchGeneration`, `hasPendingSwitch`, `lastLoggedDragOffset`, `switchSettleDelay`.
- ContainerView: `cardDimView`, `cardDimInstalled`, `ensureCardDimInstalled`, `cardDimOverlay`, `revealSwitchedPanes`, `paneContentView`, `paneContentViewInstalled`, `ensurePaneContentViewInstalled`, and the pane-created-`isHidden` logic.
- GestureController (`App/TerminalGestureController.swift`): `Callbacks.onDragBeginSwitch/onDragUpdate/onDragCancel`, `driveLiveSwitch` live-render body, `savedContentOffset`, `ScrollResidueDecision` call. `onDragCommit` is KEPT but simplified (fires `select-window` on release).
- Kit deciders + tests (dead after the above): `WindowDragModel(.swift/Tests)`, `GapDim(.swift/Tests)`, `ScrollResidueDecision(.swift/Tests)`, `WindowSlide(.swift/Tests)` (provides `windowSlideDirection`/`ExposedNeighbor`, used only by deleted switch code).
- KEEP: `DragAxisLock`, `SwitchCommitDecision` (+ tests), `armResizeSettle` (pending Task 1 determination).

---

### Task 1: Determine armResizeSettle fate (investigation + decisive cut-or-keep)

Trace what triggers the resize burst `armResizeSettle` coalesces, then cut it if animation-coupled or keep it if it is a live keybar-resize concern. This is a correctness call (cutting a needed debounce breaks resize), done first so later tasks know whether to remove it.

**Files:**
- Read: `App/TmuxPaneContainer.swift` (`armResizeSettle` def ~line 520, its call site in `apply` ~line 1269, `noteClientSize` ~line 524, `resizeSettleUntil`/`switchResizeQuiet` ~lines 163-167).

- [ ] **Step 1: Trace the trigger**

Determine: is `armResizeSettle` called from the deleted animation path, or from the universal active-window-change point in `apply(state:)` (which still fires with the animation gone, because the keybar/keyboard still grows on a window change)?

Read the call site: `armResizeSettle()` is invoked in `apply(state:)` where `state.activeWindow != previousActiveWindow` (around line 1269), NOT from `commitSwitchDrag`. That block ALSO calls `completePendingSwitchIfNeeded` (which IS deleted), but `armResizeSettle` itself guards the tmux resize debounce against the keybar-grow burst, which happens on ANY active-window change (tab tap, swipe, esc-pill), independent of the slide animation.

- [ ] **Step 2: Record the decision**

Decision: **KEEP `armResizeSettle`, `resizeSettleUntil`, `switchResizeQuiet`, and the `noteClientSize` settling logic.** They are a live resize-debounce concern (keybar grow on window change), not switch-animation ceremony. Later tasks must NOT delete them. The `completePendingSwitchIfNeeded` call that shares that `apply` block IS deleted (Task 4); `armResizeSettle` stays in that block.

Write this decision into the progress ledger so Tasks 3-4 honor it. No code change in this task.

- [ ] **Step 3: Commit (docs-only note if any; otherwise skip to Task 2)**

No production change. If a clarifying code comment is added at the `armResizeSettle` call site noting it survives the KISS cut, commit it:

```bash
git add App/TmuxPaneContainer.swift
git commit -m "docs(gestures): note armResizeSettle survives KISS switch cut (keybar-grow debounce, not animation)"
```

Otherwise proceed to Task 2 with no commit.

---

### Task 2: Collapse the gesture controller to on-release select-window (App)

Simplify `TerminalGestureController` so a horizontal drag does nothing visible during the drag and, on release past threshold, calls `onSwitchWindow` via the retained `onDragCommit`. Remove the live-drag reveal callbacks, the offset snapshot/restore, and the `driveLiveSwitch` live-render body.

**Files:**
- Modify: `App/TerminalGestureController.swift`

**Interfaces:**
- Consumes: `DragAxisLock.resolve`, `SwitchCommitDecision.resolve` (KEEP, unchanged).
- Produces: `Callbacks` retains ONLY `onDragCommit: (_ delta: Int) -> Void` for the switch (fires on release past threshold). `onDragBeginSwitch`, `onDragUpdate`, `onDragCancel` REMOVED from the struct.

- [ ] **Step 1: Remove the reveal callbacks from `Callbacks`**

Delete these members from the `Callbacks` struct (lines ~57-65): `onDragBeginSwitch`, `onDragUpdate`, `onDragCancel`. KEEP `onDragCommit`.

- [ ] **Step 2: Remove offset snapshot/restore**

Delete the `savedContentOffset` property (line ~89) and its doc comment. In `beginDrag`, delete the `savedContentOffset = view.contentOffset` line (~356) and its comment.

- [ ] **Step 3: Collapse `driveLiveSwitch` to axis-detect only**

Replace `driveLiveSwitch` (lines ~391-438) so it ONLY resolves the axis via `DragAxisLock` (setting `dragAxis`) and returns whether the drag is switch-locked. Remove the `ScrollResidueDecision` restore block, the `switchRevealStarted`/`onDragBeginSwitch`/`onDragUpdate` calls, and the `WindowDragModel.offset`/`exposedNeighbor` usage. New body:

```swift
    /// Feed the drag's cumulative translation through the axis lock. Returns true if this
    /// drag is (now) switch-locked (horizontal) so the caller suppresses its scroll/arrow
    /// path. No live rendering: the switch fires only on release (see `resolveLiveSwitch`).
    private func driveLiveSwitch(_ g: UIPanGestureRecognizer, in view: TerminalView) -> Bool {
        let t = g.translation(in: view)
        if case .pending = dragAxis {
            let multiWin = callbacks.isMultiWindowTmux()
            dragAxis = DragAxisLock.resolve(dx: Double(t.x), dy: Double(t.y),
                                            isMultiWindowTmux: multiWin)
            if case .pending = dragAxis {
                // still inside the dead-zone; no decision yet
            } else {
                let (axisDesc, reason): (String, String)
                switch dragAxis {
                case .switchWindow(let delta): axisDesc = "switchWindow(delta=\(delta))"; reason = "dominance"
                case .scroll: axisDesc = "scroll"; reason = "vertical-or-single"
                case .pending: axisDesc = "pending"; reason = "dead-zone"
                }
                DebugLog.shared.log(.gesture, decisionLine(
                    "drag-axis-lock",
                    inputs: [("dx", "\(Int(t.x))"), ("dy", "\(Int(t.y))"), ("multiWin", "\(multiWin)")],
                    outputs: [("axis", axisDesc)],
                    reason: reason))
            }
        }
        if case .switchWindow = dragAxis { return true }
        return false
    }
```

- [ ] **Step 4: Simplify `resolveLiveSwitch` to commit-on-release**

Replace `resolveLiveSwitch` (lines ~443-457) so on release it applies `SwitchCommitDecision` and, on commit, calls `onDragCommit(delta)`; on spring-back it does nothing (no `onDragCancel`). New body:

```swift
    /// On release, resolve commit-vs-nothing for a switch-locked drag. Returns true if this
    /// was a switch drag (caller skips its own resolution). Commit fires `onDragCommit`
    /// (-> tmux select-window); a short drag does nothing (no animation to cancel).
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
            DebugLog.shared.log(.gesture, "drag-switch short dx=\(Int(t.x)) vx=\(Int(v.x)) - no switch")
        }
        return true
    }
```

- [ ] **Step 5: Remove `switchRevealStarted` if now unused**

Search for `switchRevealStarted`. It was only set/read by the deleted reveal path. Delete the property (~line 85) and its reset in `beginDrag` (~line 333). If any reference remains, the compile-check (Step 6) via CI will catch it.

- [ ] **Step 6: Verify (macOS CI compile)**

App-tier; not Linux-buildable. After all App tasks land, the `macos` CI job is the compile gate. Do NOT run `swift build`/`swift test` for App code.

- [ ] **Step 7: Commit**

```bash
git add App/TerminalGestureController.swift
git commit -m "refactor(gestures): switch fires on release, no live-drag reveal (KISS)"
```

---

### Task 3: Delete the switch-animation machinery from the Coordinator (App)

Remove all reveal/commit/gate/settle methods and state from the `Coordinator`, and update the switch callback construction so the gesture controller's `onDragCommit` calls `onSwitchWindow(delta)` directly.

**Files:**
- Modify: `App/TmuxPaneContainer.swift`

- [ ] **Step 1: Rewire the callback construction in `installHalo`**

In the `Callbacks(...)` init (lines ~363-374), remove `onDragBeginSwitch`, `onDragUpdate`, `onDragCancel`. Replace the `onDragCommit` closure to call `onSwitchWindow` directly (the tmux `select-window` path already wired via the coordinator's `onSwitchWindow`):

```swift
                        onDragCommit: { [weak self] delta in
                            self?.onSwitchWindow(delta)   // tmux select-window; tmux redraws (KISS)
                        }
```

- [ ] **Step 2: Delete the Coordinator switch methods**

Delete these method definitions entirely (with their doc comments): `beginSwitchReveal`, `updateSwitchDrag`, `updateCardDim`, `clearCardDim`, `commitSwitchDrag`, `cancelSwitchDrag`, `clearPendingSwitch`, `discardCommittedSnapshot`, `failPendingSwitch`, `finishSwitchHandoffIfReady`, `completePendingSwitchIfNeeded`.

- [ ] **Step 3: Delete the Coordinator switch state**

Delete these stored properties + `switchSettleDelay` static (with comments): `pendingSwitchTimeout`, `pendingSwitchWindow`, `switchAnimDone`, `switchDelivered`, `switchGeneration`, `hasPendingSwitch` (computed), `lastLoggedDragOffset`, `switchSettleDelay`. KEEP `armResizeSettle`/`resizeSettleUntil`/`switchResizeQuiet`/`previousActiveWindow` (Task 1 decision: resize-debounce, not animation).

- [ ] **Step 4: Fix the `apply(state:)` active-window-change block**

In `apply(state:)` (around line 1263-1273), the block gated on `state.activeWindow != previousActiveWindow` currently calls both `armResizeSettle()` and `completePendingSwitchIfNeeded(newActive:)`. Remove the `completePendingSwitchIfNeeded` call (deleted), KEEP `armResizeSettle()` and the `previousActiveWindow` update. Result:

```swift
            if state.activeWindow != previousActiveWindow, state.activeWindow != nil {
                MainActor.assumeIsolated {
                    coordinator?.armResizeSettle()   // keybar-grow resize debounce on window change (KEEP)
                }
            }
            previousActiveWindow = state.activeWindow
```

- [ ] **Step 5: Remove pane-created-hidden logic in `apply`**

In the pane-creation block (~line 1201), delete the `if coordinator?.hasPendingSwitch == true { t.isHidden = true }` line (the hidden-until-reveal masking). Panes are always created visible now.

- [ ] **Step 6: Verify (macOS CI compile)** — App-tier; the `macos` job is the gate.

- [ ] **Step 7: Commit**

```bash
git add App/TmuxPaneContainer.swift
git commit -m "refactor(gestures): delete switch-animation + async-handoff machinery from Coordinator (KISS)"
```

---

### Task 4: Remove paneContentView wrapper + cardDim from ContainerView; parent panes directly (App)

Delete the `paneContentView` and `cardDimView` wrappers. Parent panes directly into `ContainerView` and pin them in `layoutSubviews` against `ContainerView.bounds` (same visible-height inset, minus the wrapper).

**Files:**
- Modify: `App/TmuxPaneContainer.swift` (`ContainerView`)

- [ ] **Step 1: Delete cardDim members**

Delete `cardDimView`, `cardDimInstalled`, `ensureCardDimInstalled`, `cardDimOverlay` (lines ~902-923).

- [ ] **Step 2: Delete paneContentView members**

Delete `paneContentView`, `paneContentViewInstalled`, `ensurePaneContentViewInstalled` (lines ~875-886), and `revealSwitchedPanes` (~892).

- [ ] **Step 3: Reparent panes to ContainerView in `apply`**

In `apply(state:)`, change the pane parenting (line ~1202) from `paneContentView.addSubview(t)` to `addSubview(t)` (the ContainerView itself). Remove the `ensurePaneContentViewInstalled()` call at the top of `apply` (~line 1131).

- [ ] **Step 4: Rewrite `layoutSubviews` to pin panes directly**

In `layoutSubviews` (lines ~963-1040), remove all `paneContentView` framing/transform/bounds/center logic (lines ~969-1013 that pin the wrapper, handle `dragActive`, the transform-preservation instrument, and cardDim pinning). Keep the keybar-height inset math (`firstResponderKeybarHeight`, `visibleTerminalHeight`, `usableH`), the grid computation, `noteClientSize`, and the `relayoutExistingPaneFrames` on bounds change. Panes are framed directly by `paneRects` in `apply` and `relayoutExistingPaneFrames`; those already set each pane's `frame` against ContainerView coordinates, so with the wrapper gone their frames are correct as-is. The `dragActive` transform branch is deleted (no transform ever set).

Replace the `paneContentView`-pinning block with nothing (the pane frames from `apply`/`relayoutExistingPaneFrames` already position them in ContainerView space). Verify `relayoutExistingPaneFrames` (~line 1046) sets `view.frame` directly (it does: `view.frame = CGRect(x: rect.x, ...)`) and remove its `guard paneContentView.transform.isIdentity` guard (~line 1047, no transform now).

- [ ] **Step 5: Verify (macOS CI compile)** — App-tier; the `macos` job is the gate. This task has the most reparenting risk; the CI compile + device layout check are the real gates.

- [ ] **Step 6: Commit**

```bash
git add App/TmuxPaneContainer.swift
git commit -m "refactor(gestures): remove paneContentView/cardDim wrappers, parent panes directly (KISS)"
```

---

### Task 5: Delete the now-dead Kit deciders + tests

Remove the pure deciders that only served the animation, with their tests. Verified: each is referenced only by the App code deleted in Tasks 2-4 (or nothing).

**Files:**
- Delete: `Sources/SemicolynKit/Terminal/WindowDragModel.swift` + `Tests/SemicolynKitTests/WindowDragModelTests.swift`
- Delete: `Sources/SemicolynKit/Terminal/GapDim.swift` + `Tests/SemicolynKitTests/GapDimTests.swift`
- Delete: `Sources/SemicolynKit/Terminal/ScrollResidueDecision.swift` + `Tests/SemicolynKitTests/ScrollResidueDecisionTests.swift`
- Delete: `Sources/SemicolynKit/Terminal/WindowSlide.swift` + `Tests/SemicolynKitTests/WindowSlideTests.swift`

- [ ] **Step 1: Confirm no live references remain**

Run: `grep -rnE "WindowDragModel|GapDim|ScrollResidueDecision|WindowSlide|windowSlideDirection|ExposedNeighbor" Sources/ App/`
Expected: after Tasks 2-4, matches only inside the four files being deleted (and the `DragAxisLock.swift` doc-comment mention of `windowSlideDirection`, which is a comment, update it). If any live reference remains in App/, STOP: a prior task missed a deletion.

- [ ] **Step 2: Update the stale doc-comment in DragAxisLock**

In `Sources/SemicolynKit/Terminal/DragAxisLock.swift` (~line 15), the `.switchWindow` case comment says "Matches `windowSlideDirection`." Remove that clause (the referenced symbol is deleted):

```swift
    /// Content-follows-finger is gone (KISS): rightward swipe (dx>0) -> previous window (-1),
    /// leftward -> next (+1).
    case switchWindow(delta: Int)
```

- [ ] **Step 3: Delete the eight files**

```bash
git rm Sources/SemicolynKit/Terminal/WindowDragModel.swift Tests/SemicolynKitTests/WindowDragModelTests.swift \
       Sources/SemicolynKit/Terminal/GapDim.swift Tests/SemicolynKitTests/GapDimTests.swift \
       Sources/SemicolynKit/Terminal/ScrollResidueDecision.swift Tests/SemicolynKitTests/ScrollResidueDecisionTests.swift \
       Sources/SemicolynKit/Terminal/WindowSlide.swift Tests/SemicolynKitTests/WindowSlideTests.swift
```

- [ ] **Step 4: Run the full Kit suite (verifies the deletion compiles + nothing else referenced them)**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS. The suite drops the deleted deciders' tests but everything else stays green (notably `DragAxisLockTests`, `SwitchCommitDecisionTests`). If it fails to COMPILE, a non-App reference to a deleted symbol remains, fix it.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(gestures): delete dead animation deciders (WindowDragModel/GapDim/ScrollResidueDecision/WindowSlide) + tests"
```

---

### Task 6: Integration gate (Kit green + push macOS CI + device-verify)

**Files:** none (verification).

- [ ] **Step 1: Full Kit suite green**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS (baseline minus the ~deleted animation tests; `DragAxisLock`/`SwitchCommitDecision` still green).

- [ ] **Step 2: Push + confirm all CI jobs, especially `macos`**

```bash
git push github feat/finger-drag-window-transition
```
Confirm `lint`, `linux-rust`, `linux-swift`, and the `macos` compile job all green (macos is the only App-tier signal). Rerun `linux-rust` if it flakes on sshd-fixtures.

- [ ] **Step 3: Device verification (acceptance gate)**

Device matrix (spec): horizontal swipe past threshold switches windows (on release); short drag does nothing; vertical scroll + momentum unaffected; long-press pane-zoom works; tab strip still switches; NO slide/dim/blank-hold animation, the screen just redraws (a brief blank while tmux repaints is acceptable); rapid double-swipe does not corrupt (tmux is authoritative, last select-window wins); alt-screen (vim/claude) swipe still switches.

- [ ] **Step 4: Record outcome**

On PASS, note the build/commit in `TODO.md` + update the memory. On FAIL, capture a `gesture`+`render` device log and diagnose against the matrix.

---

## Self-Review

**Spec coverage:**
- KISS switch = swipe -> select-window -> redraw: Task 2 (on-release commit) + Task 3 (onDragCommit -> onSwitchWindow). Covered.
- Delete animation machinery: Task 3 (Coordinator methods/state) + Task 4 (paneContentView/cardDim). Covered.
- Fire on release past threshold, no live tracking: Task 2 Steps 3-4. Covered.
- paneContentView REMOVED (no inert wrapper): Task 4. Covered.
- armResizeSettle investigate-then-decide: Task 1. Covered (decision: KEEP, recorded).
- Dead Kit deciders + tests removed: Task 5. Covered.
- Keep DragAxisLock + SwitchCommitDecision: untouched; Task 5 Step 1 confirms no accidental deletion. Covered.
- Testing (Kit green, device matrix): Task 6. Covered.

**Placeholder scan:** No TBD/TODO/"handle edge cases". App-tier steps that cannot run locally say so and route to macOS CI + device (correct for the tier, not a placeholder). Every code step shows the replacement code.

**Type consistency:** `onDragCommit: (_ delta: Int) -> Void` is the sole retained switch callback, defined in Task 2 Step 1 and constructed in Task 3 Step 1 with matching signature. `driveLiveSwitch`/`resolveLiveSwitch` return `Bool` (unchanged contract) in Task 2. `DragAxisLock.resolve` / `SwitchCommitDecision.resolve` signatures unchanged (kept). Deleted symbols (`WindowDragModel`, `GapDim`, `ScrollResidueDecision`, `WindowSlide`, `windowSlideDirection`, `ExposedNeighbor`, `onDragBeginSwitch/Update/Cancel`, all the switch state) are removed consistently across Tasks 2-5 with Task 5 Step 1 as the dangling-reference backstop.

**Ordering:** callers simplified before machinery deleted (Task 2 before 3), wrappers removed after their users are gone (Task 4 after 3), dead Kit deleted last after all App references removed (Task 5 after 2-4). Task 1 (armResizeSettle determination) first so 3-4 honor the keep decision.
