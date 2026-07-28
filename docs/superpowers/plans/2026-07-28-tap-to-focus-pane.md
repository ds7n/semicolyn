<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Tap-to-focus-pane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tapping an inactive tmux pane focuses it (`select-pane`); tapping the already-active pane keeps today's behavior (place cursor / yield / forward mouse).

**Architecture:** A new pure Kit decider `paneTapAction(...)` composes the existing `tapAction(hasSelection:)` and becomes the single entry point for single-tap routing. `handleSingleTap` calls it; on `.focusPane` it invokes a new `onSelectPane` callback. The container wires that callback to optimistically move the accent border + first responder locally, then send `select-pane -t %N`; tmux's echoed layout confirms it via the existing `apply()`.

**Tech Stack:** Swift 6 (strict concurrency), SwiftTerm, tmux `-CC` control mode, XCTest. Kit tier = Linux-tested; App tier = macOS-CI-validated.

## Global Constraints

- SemicolynKit tier is **pure, Linux-tested**: no `import UIKit`/`SwiftUI`/`CryptoKit`; `Sendable`; Swift 6 strict concurrency.
- App tier does NOT compile on Linux; validate via macOS CI only. Keep App changes thin wiring.
- Every source file carries the SPDX header: `// SPDX-FileCopyrightText: 2026 True Positive LLC` / `// SPDX-License-Identifier: GPL-3.0-only`.
- Conventional commits (`feat:`/`test:`/`refactor:`). Feature branch `feat/tap-to-focus-pane` (already created); squash-merge to `main`.
- No em-dash (U+2014) or en-dash (U+2013) anywhere.
- Kit tests run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <Name>`.
- Existing symbols (verified present): `InteractionMode` (cases `localScroll`/`appOwnsInput`/`mouseReporting`, `Sources/SemicolynKit/Terminal/InteractionMode.swift`); `TapAction` (cases `clearSelection`/`placeCursor`) + `tapAction(hasSelection:) -> TapAction` (`Sources/SemicolynKit/Terminal/TapAction.swift`); `TmuxCommand.selectPane(target: PaneID) -> String` (`Sources/SemicolynKit/Tmux/TmuxCommand.swift:56`); `PaneID` with `.raw`.

---

## Task 1: Pure `paneTapAction` decider (Kit, Linux-tested)

**Files:**
- Create: `Sources/SemicolynKit/Terminal/PaneTapAction.swift`
- Test: `Tests/SemicolynKitTests/PaneTapActionTests.swift`

**Interfaces:**
- Consumes: `InteractionMode`, `TapAction`, `tapAction(hasSelection:)` (all existing).
- Produces:
  - `enum PaneTapAction: Equatable, Sendable { case focusPane; case active(TapAction); case yield }`
  - `func paneTapAction(isActivePane: Bool, mode: InteractionMode, hasSelection: Bool) -> PaneTapAction`

- [ ] **Step 1: Write the failing tests**

Create `Tests/SemicolynKitTests/PaneTapActionTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class PaneTapActionTests: XCTestCase {
    // Inactive pane always focuses, regardless of mode or selection.
    func testInactiveLocalScrollFocuses() {
        XCTAssertEqual(
            paneTapAction(isActivePane: false, mode: .localScroll, hasSelection: false),
            .focusPane)
    }
    func testInactiveAppOwnsFocuses() {
        XCTAssertEqual(
            paneTapAction(isActivePane: false, mode: .appOwnsInput, hasSelection: false),
            .focusPane)
    }
    func testInactiveMouseReportingFocuses() {
        XCTAssertEqual(
            paneTapAction(isActivePane: false, mode: .mouseReporting, hasSelection: true),
            .focusPane)
    }

    // Active + localScroll delegates to the existing tapAction decider.
    func testActiveLocalScrollNoSelectionPlacesCursor() {
        XCTAssertEqual(
            paneTapAction(isActivePane: true, mode: .localScroll, hasSelection: false),
            .active(.placeCursor))
    }
    func testActiveLocalScrollWithSelectionClears() {
        XCTAssertEqual(
            paneTapAction(isActivePane: true, mode: .localScroll, hasSelection: true),
            .active(.clearSelection))
    }

    // Active + app-owned modes yield.
    func testActiveAppOwnsYields() {
        XCTAssertEqual(
            paneTapAction(isActivePane: true, mode: .appOwnsInput, hasSelection: false),
            .yield)
    }
    func testActiveMouseReportingYields() {
        XCTAssertEqual(
            paneTapAction(isActivePane: true, mode: .mouseReporting, hasSelection: false),
            .yield)
    }

    // Regression guard: the bug this feature fixes. An inactive localScroll pane
    // must NOT place a cursor (old behavior), it must focus.
    func testInactiveLocalScrollIsNotPlaceCursor() {
        XCTAssertNotEqual(
            paneTapAction(isActivePane: false, mode: .localScroll, hasSelection: false),
            .active(.placeCursor))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PaneTapActionTests`
Expected: FAIL to compile ("cannot find 'paneTapAction'" / "cannot find 'PaneTapAction'").

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SemicolynKit/Terminal/PaneTapAction.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// What a single tap should do on a tmux pane, given whether that pane is
/// currently the active (focused) pane, its interaction mode, and whether a
/// text selection is active. The single source of truth for single-tap routing.
///
/// A tap on an INACTIVE pane always focuses it (in every mode); the tap is
/// consumed by the focus-switch and nothing is forwarded to the remote. A tap
/// on the ACTIVE pane runs the existing per-mode behavior.
public enum PaneTapAction: Equatable, Sendable {
    /// Inactive pane: focus it (`select-pane`), consume the tap.
    case focusPane
    /// Active pane in `.localScroll`: the existing tap behavior (place / clear).
    case active(TapAction)
    /// Active pane in an app-owned mode (`.appOwnsInput` / `.mouseReporting`):
    /// yield (SwiftTerm forwards the click, or nothing happens).
    case yield
}

/// Pure decider for a single tap on a pane. See `PaneTapAction`.
public func paneTapAction(isActivePane: Bool,
                          mode: InteractionMode,
                          hasSelection: Bool) -> PaneTapAction {
    guard isActivePane else { return .focusPane }
    switch mode {
    case .localScroll:
        return .active(tapAction(hasSelection: hasSelection))
    case .appOwnsInput, .mouseReporting:
        return .yield
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PaneTapActionTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Terminal/PaneTapAction.swift Tests/SemicolynKitTests/PaneTapActionTests.swift
git commit -m "feat(kit): pure paneTapAction decider (focus inactive pane vs act on active)"
```

---

## Task 2: `TmuxRuntime.selectPane(target:)` wrapper (App, macOS-CI)

**Files:**
- Modify: `App/TmuxRuntime.swift` (add after `zoomActivePane()`, ~line 220)

**Interfaces:**
- Consumes: `TmuxCommand.selectPane(target: PaneID)` (existing), `write(_:)` (existing private send).
- Produces: `func selectPane(target: PaneID)` on `TmuxRuntime`.

- [ ] **Step 1: Add the targeted select-pane wrapper**

In `App/TmuxRuntime.swift`, immediately after `zoomActivePane()`, add:

```swift
    /// Focus a specific pane by id (tap-to-focus). Unlike `selectPaneRelative`,
    /// this targets `%N` directly. tmux emits the layout change that re-keys the
    /// active pane in `apply()`.
    func selectPane(target: PaneID) {
        DebugLog.shared.log(.tmux, "tmux:send select-pane target=%\(target.raw)")
        write(TmuxCommand.selectPane(target: target))
    }
```

- [ ] **Step 2: Verify it compiles (macOS CI)**

This is App-tier; there is no local Swift toolchain. Push happens after Task 4; CI's `macos` job validates compilation. No local run.

- [ ] **Step 3: Commit**

```bash
git add App/TmuxRuntime.swift
git commit -m "feat(app): TmuxRuntime.selectPane(target:) for tap-to-focus"
```

---

## Task 3: Add `isActivePane` + `onSelectPane` callbacks; route `handleSingleTap` through the decider (App, macOS-CI)

**Files:**
- Modify: `App/TerminalGestureController.swift` (`Callbacks` struct ~line 35-59; `handleSingleTap` ~line 612-644)

**Interfaces:**
- Consumes: `paneTapAction(isActivePane:mode:hasSelection:)` (Task 1); existing `callbacks.currentMode()`, `callbacks.hasSelection()`, `callbacks.clearSelection()`, `callbacks.onPlaceCursor(_:_:)`, `cell(at:in:)`.
- Produces: two new `Callbacks` fields, `isActivePane: () -> Bool`, `onSelectPane: () -> Void`.

- [ ] **Step 1: Add the two callbacks to the `Callbacks` struct**

In `App/TerminalGestureController.swift`, inside `struct Callbacks`, after `onPlaceCursor` (line 39) add:

```swift
        /// Whether THIS pane is currently the active (focused) pane. Read fresh
        /// on each tap; backs the tap-to-focus decision.
        let isActivePane: () -> Bool
        /// Focus THIS pane (tap on an inactive pane). Optimistically moves the
        /// accent border locally, then sends `select-pane -t %N`.
        let onSelectPane: () -> Void
```

- [ ] **Step 2: Route `handleSingleTap` through `paneTapAction`**

Replace the body of `handleSingleTap` after the `becomeFirstResponder` block (the `switch callbacks.currentMode()` block, lines ~623-643) with:

```swift
        switch paneTapAction(isActivePane: callbacks.isActivePane(),
                             mode: callbacks.currentMode(),
                             hasSelection: callbacks.hasSelection()) {
        case .focusPane:
            callbacks.onSelectPane()
            DebugLog.shared.log(.gesture, "gesture:singleTap action=focus-pane")
        case .active(.clearSelection):
            callbacks.clearSelection()
            DebugLog.shared.log(.gesture, "gesture:singleTap action=clear")
        case .active(.placeCursor):
            let p = g.location(in: view)
            let target = cell(at: p, in: view)
            callbacks.onPlaceCursor(target.col, target.row)
            DebugLog.shared.log(.gesture, "gesture:singleTap action=place at=(\(target.col),\(target.row))")
        case .yield:
            DebugLog.shared.log(.gesture, "gesture:singleTap action=appOwns mode=\(callbacks.currentMode())")
            return
        }
```

(This removes the now-redundant local `tapAction(hasSelection:)` call; the decider owns that logic. The `becomeFirstResponder` block above it is unchanged.)

- [ ] **Step 3: Update every `Callbacks(...)` construction site to supply the new fields**

There are two construction sites. Update BOTH so the struct still compiles:

1. `App/TmuxPaneContainer.swift` ~line 300-311 (the tmux per-pane controller), added in Task 4.
2. `App/TerminalScreen.swift` ~line 143-146 (the raw/single-pane path). Raw shell has exactly one pane, always active, and no tmux select-pane. Add:

```swift
                isActivePane: { true },
                onSelectPane: { },
```

Add these two lines to the `Callbacks(...)` init in `TerminalScreen.swift` (alongside `onLongPressZoom: { }` / `onPlaceCursor:`). For raw shell `isActivePane` is always `true`, so `paneTapAction` never returns `.focusPane` and behavior is identical to today.

- [ ] **Step 4: Commit**

```bash
git add App/TerminalGestureController.swift App/TerminalScreen.swift
git commit -m "feat(app): route handleSingleTap through paneTapAction (tap inactive pane = focus)"
```

---

## Task 4: Wire `onSelectPane` through the container with optimistic border (App, macOS-CI)

**Files:**
- Modify: `App/TmuxPaneContainer.swift` (`ContainerView` props ~line 39-41; `makeUIView`/`updateUIView` copy ~line 59-60,142-143; `Coordinator` props ~line 187-188; controller init ~line 300-311; factor `applyActiveBorder` out of `apply()` ~line 975-993; add `pendingActivePane`)
- Modify: `App/SessionView.swift` (~line 80-81: pass `onSelectPane` closure to the container)
- Modify: `App/ConnectionViewModel.swift` (~line 335: add `func selectPane(_:)`)

**Interfaces:**
- Consumes: `TerminalGestureController.Callbacks.onSelectPane` / `.isActivePane` (Task 3); `TmuxRuntime.selectPane(target:)` (Task 2); existing `window.activePane`, `activeBorderColor`/`inactiveBorderColor`.
- Produces: container `onSelectPane: ((PaneID) -> Void)?`; coordinator `onSelectPane: (PaneID) -> Void`; `ConnectionViewModel.selectPane(_ pane: PaneID)`; `Coordinator.pendingActivePane: PaneID?`; `Coordinator.applyActiveBorder(active:in:)` helper.

- [ ] **Step 1: Add `selectPane` to the view model**

In `App/ConnectionViewModel.swift`, next to `func zoomActivePane()` (~line 335) add:

```swift
    func selectPane(_ pane: PaneID) { tmux?.selectPane(target: pane) }
```

- [ ] **Step 2: Add the container `onSelectPane` property + copy it into the coordinator**

In `App/TmuxPaneContainer.swift` `ContainerView`, after `onPlaceCursor` (line 41) add:

```swift
    var onSelectPane: ((PaneID) -> Void)? = nil
```

In `makeUIView` after line 60 (`if let onPlaceCursor { c.onPlaceCursor = onPlaceCursor }`) add:

```swift
        if let onSelectPane { c.onSelectPane = onSelectPane }
```

In `updateUIView` after line 143 add:

```swift
        if let onSelectPane { context.coordinator.onSelectPane = onSelectPane }
```

In the `Coordinator`, after `onPlaceCursor` (line 188) add:

```swift
        var onSelectPane: (PaneID) -> Void = { _ in }
        /// Optimistic focus hint: the pane the user just tapped, applied to the
        /// accent border locally before tmux echoes the layout. Cleared/superseded
        /// on the next `apply()`. Never the source of truth (server-derived
        /// `window.activePane` is).
        var pendingActivePane: PaneID? = nil
```

- [ ] **Step 3: Factor the active-border logic out of `apply()` into a helper**

In `apply()` the per-pane loop (~line 975-993) currently sets the border inline. Extract it into a coordinator method so the optimistic path reuses the exact logic. Add this method to the `Coordinator`:

```swift
        /// Apply active/inactive border chrome for `active` across `rects`. Shared
        /// by `apply()` (authoritative, on tmux layout) and the optimistic tap path.
        /// Single-pane windows show no border (a lone coral rim is meaningless).
        func applyActiveBorder(active: PaneID?, singlePane: Bool) {
            for (pane, view) in paneViews {
                let isActive = (pane == active)
                if isActive {
                    view.layer.borderWidth = singlePane ? 0 : 1.5
                    if !singlePane { view.layer.borderColor = activeBorderColor.cgColor }
                } else {
                    view.layer.borderColor = inactiveBorderColor.cgColor
                    view.layer.borderWidth = singlePane ? 0 : 0.5
                }
            }
        }
```

NOTE for the implementer: confirm the pane->view map name (the code iterates panes with their `TerminalView`s; it may be `paneViews`, `views`, or keyed off `rects`). Use whatever the existing `apply()` loop uses to reach each pane's `view`, and match `activeBorderColor`/`inactiveBorderColor`/`becomeFirstResponder` exactly. Then replace the inline border block in `apply()` (lines ~981-993, the `if isActive { ... } else { ... }` border portion) with a call `applyActiveBorder(active: window.activePane, singlePane: singlePane)` placed AFTER the frame set, keeping the existing `becomeFirstResponder()` handoff for the active pane intact. Do not remove the first-responder logic; only the border-setting lines move into the helper.

- [ ] **Step 4: Wire `onSelectPane` + `isActivePane` into the per-pane controller**

In the controller-construction `Callbacks(...)` (~line 300-311), add alongside `onLongPressZoom` / `onPlaceCursor`:

```swift
                        isActivePane: { [weak self] in
                            self?.containerView?.currentWindow?.activePane == pane
                        },
                        onSelectPane: { [weak self] in
                            guard let self else { return }
                            // Optimistic: move border + first responder locally now.
                            self.pendingActivePane = pane
                            let singlePane = (self.paneViews.count <= 1)
                            self.applyActiveBorder(active: pane, singlePane: singlePane)
                            self.paneViews[pane]?.becomeFirstResponder()
                            // Then tell tmux; the echoed layout confirms via apply().
                            self.onSelectPane(pane)
                        },
```

NOTE for the implementer: `pane` is the loop-local `PaneID` already captured by the other closures at this site (see `onPlaceCursor`/`altScrollDecision` capturing `pane`). For `isActivePane`, read the active pane the same way `apply()` does (`window.activePane` for the current window). If the controller closure cannot see `window` directly, expose the current active pane through the coordinator (a stored `var currentActivePane: PaneID?` updated in `apply()`), and compare against that. Match the exact `paneViews` accessor confirmed in Step 3.

- [ ] **Step 5: Pass the closure from `SessionView` to the container**

In `App/SessionView.swift`, in the `TmuxPaneContainer` construction (~line 80-81, alongside `onZoomActivePane:` / `onPlaceCursor:`), add:

```swift
                            onSelectPane: { [weak vm] pane in vm?.selectPane(pane) },
```

- [ ] **Step 6: Commit**

```bash
git add App/TmuxPaneContainer.swift App/SessionView.swift App/ConnectionViewModel.swift
git commit -m "feat(app): wire tap-to-focus with optimistic accent border"
```

---

## Task 5: Push, verify CI, device-test

**Files:** none (verification).

- [ ] **Step 1: Push the branch**

```bash
git push -u github feat/tap-to-focus-pane
```

- [ ] **Step 2: Wait for CI**

`linux-swift` (Task 1 tests included) + `lint` are the fast signal; the `macos` job (~15-18 min) is the ONLY validation that Tasks 2-4 compile. Confirm all green. Rerun a flaky `linux-rust` if it hits the sshd-fixtures race (not a real failure on this non-Rust change).

- [ ] **Step 3: Device pass (TestFlight)**

Trigger a TF build (gated on the macos job passing). On device, in a multi-pane tmux window:
1. Tap an inactive pane → accent border moves to it INSTANTLY (optimistic) → cursor input now goes there → tmux confirms (border stays).
2. Tap the active shell pane → cursor still places at the tapped cell (unchanged).
3. Tap an inactive pane running Claude/vim → it focuses (does not forward a stray click); a second tap yields to the app as before.
4. Single-pane window → no border, tap behaves exactly as today.
5. Long-press still zooms; double/triple-tap word/line-select still only fire on an active `.localScroll` pane.

Capture via `tools/syslog-sink` (docker up, TLS/TCP). Look for `gesture:singleTap action=focus-pane` then `tmux:send select-pane target=%N`.

- [ ] **Step 4: Squash-merge** once device-verified.

---

## Self-review notes

- **Spec coverage:** core model (Task 1 decider + Task 3 routing), always-focus-first (Task 1: `!isActivePane` before mode switch), focus-only-then-act (`.focusPane` returns without place/forward), optimistic border (Task 4 Step 4), `select-pane` wiring (Task 2 + Task 4). Edge cases (zoom/single-pane/mouse-mode) fall out of the decider + `singlePane` guard. Testing split matches the spec (Kit pure tests + App CI/device).
- **No placeholders:** every code step has real content; the two "NOTE for the implementer" blocks flag exact-symbol confirmations to make in the App tier (unavoidable: App code is not Linux-readable by the Kit tests, and the pane->view accessor must match the existing `apply()` loop), not deferred work.
- **Type consistency:** `PaneTapAction`/`paneTapAction` signatures identical across Tasks 1 and 3; `onSelectPane: () -> Void` (controller) vs `onSelectPane: (PaneID) -> Void` (container/VM) is intentional, the controller already knows its own `pane` and passes none; the container closure receives the `PaneID`. `selectPane(target:)` (runtime) vs `selectPane(_:)` (VM) mirror the existing `zoomActivePane`/`zoomActivePane()` naming split.
