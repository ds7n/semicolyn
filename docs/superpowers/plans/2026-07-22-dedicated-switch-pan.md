<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Dedicated Switch Pan Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the plain-shell window-switch swipe reliable (including immediately after a switch) by giving it a dedicated always-on pan recognizer instead of riding SwiftTerm's native scroll pan.

**Architecture:** Add `switchPan` (a `UIPanGestureRecognizer` we own) that carries the switch logic in `.localScroll`/`.mouseReporting`; stop `addTarget`-ing the switch onto the native scroll pan. `switchPan` recognizes simultaneously with the scroll pan (axis-gated via `DragAxisLock`: our pan acts on horizontal, scroll pan on vertical). Selection + long-press subordinated to `switchPan`. Reuses `DragAxisLock` + `SwitchCommitDecision`.

**Tech Stack:** Swift 6, SwiftTerm, UIKit (App: macOS CI + device), XCTest (Kit: Linux/Docker).

## Global Constraints

- SPDX header on every source file. No em-dashes anywhere. Conventional commits.
- `Sources/SemicolynKit/`: platform-agnostic, Linux-tested, no UIKit/SwiftUI.
- `App/`: Apple-only, not Linux-buildable, macOS CI + device verified.
- Tests real: exact-value assertions; include a case that fails against the pre-fix behavior.
- `@MainActor` trap: `@objc` selectors on the `@MainActor` controller need no `assumeIsolated`; Coordinator->controller calls from `modeTracker.onChange` use `MainActor.assumeIsolated` (mirror `setAltScreenPan`).
- Kit tests via Docker: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`.

**Spec:** `docs/superpowers/specs/2026-07-22-dedicated-switch-pan-design.md`.

**Key existing anchors (verified):**
- `GestureRole` enum + `gesturesMayRecognizeSimultaneously` in `Sources/SemicolynKit/Terminal/GestureSimultaneity.swift` (cases: scrollPan/longPress/pinch/tap/selectionPan/altScreenPan/other; pairings return false for {longPress,scrollPan}, {selectionPan,scrollPan}, {altScreenPan,longPress}).
- `App/TerminalGestureController.swift`: `altScreenPan` declared ~line 116, created ~238-240, added to `ours` ~242, `setAltScreenPanEnabled` ~278, `handleScrollViewPan` ~429, `role(of:)` ~718 (classifies unknown pan as `.selectionPan` at ~729), `shouldRequireFailureOf` ~751, native-pan `addTarget` ~250, `detach` removeTarget ~267.
- `subordinateSelectionPan` (subordinates the selection pan; currently require-to-fail vs scrollPan).
- `App/TmuxPaneContainer.swift`: `modeTracker.onChange` ~87-96 (sets isScrollEnabled/allowMouseReporting/setAltScreenPan, ONLY on mode CHANGE), `setAltScreenPan(for:enabled:)` ~432.

---

### Task 1: Add `.switchPan` role + simultaneity pairings (Kit)

**Files:**
- Modify: `Sources/SemicolynKit/Terminal/GestureSimultaneity.swift`
- Modify: `Tests/SemicolynKitTests/GestureSimultaneityTests.swift`

**Interfaces:** `GestureRole.switchPan` (new case). Pairings: `(.switchPan,.scrollPan)`->true (coexist, axis-gated), `(.selectionPan,.switchPan)`->false, `(.switchPan,.longPress)`->false, `(.switchPan,.pinch)`->true.

- [ ] **Step 1: Write failing tests**

Append to `GestureSimultaneityTests` class:

```swift
    // The dedicated switch pan coexists with the native scroll pan (orthogonal axes: our
    // pan acts on horizontal, scroll pan on vertical); neither must require the other to fail.
    func testSwitchPanAndScrollPanCoexist() {
        XCTAssertTrue(gesturesMayRecognizeSimultaneously(.switchPan, .scrollPan))
        XCTAssertTrue(gesturesMayRecognizeSimultaneously(.scrollPan, .switchPan))
    }

    // Selection must NOT co-recognize with the switch pan (a switch drag must never become
    // a text selection), same as it must not with the scroll pan.
    func testSelectionPanAndSwitchPanAreMutuallyExclusive() {
        XCTAssertFalse(gesturesMayRecognizeSimultaneously(.selectionPan, .switchPan))
    }

    // Long-press must NOT co-recognize with the switch pan (held-then-drag hazard), mirroring
    // the altScreenPan/longPress and scrollPan/longPress exclusions.
    func testSwitchPanAndLongPressAreMutuallyExclusive() {
        XCTAssertFalse(gesturesMayRecognizeSimultaneously(.switchPan, .longPress))
    }

    // Pinch still coexists with the switch pan (2-finger vs 1-finger).
    func testSwitchPanAndPinchCoexist() {
        XCTAssertTrue(gesturesMayRecognizeSimultaneously(.switchPan, .pinch))
    }
```

- [ ] **Step 2: Run to verify fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter GestureSimultaneityTests`
Expected: FAIL (compile error: `.switchPan` not a `GestureRole` case).

- [ ] **Step 3: Add the case + pairings**

In `GestureSimultaneity.swift`, add to `GestureRole` (after `.altScreenPan`):

```swift
    /// OUR always-on horizontal window-switch pan (`.localScroll`/`.mouseReporting`). A
    /// UIPanGestureRecognizer we own, so the swipe never depends on SwiftTerm's scroll-view
    /// state (a fresh pane's native scroll pan does not track a horizontal drag). Coexists
    /// with the scroll pan (orthogonal axes: horizontal here, vertical there).
    case switchPan
```

In `gesturesMayRecognizeSimultaneously`, add before `return true` (the `(.switchPan,.scrollPan)` pair is NOT listed, so it defaults to true = coexist; only the exclusions need listing):

```swift
    // The switch pan must NOT co-recognize with the selection pan (a switch drag must never
    // be hijacked into a text selection) nor the long-press (held-then-drag hazard), matching
    // the scrollPan exclusions. It DOES coexist with the scroll pan (orthogonal axes) and
    // pinch (2-finger), which fall through to the default `true`.
    if pair == Set([.selectionPan, .switchPan]) { return false }
    if pair == Set([.switchPan, .longPress]) { return false }
```

- [ ] **Step 4: Run to verify pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter GestureSimultaneityTests`
Expected: PASS (all, including the 4 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Terminal/GestureSimultaneity.swift Tests/SemicolynKitTests/GestureSimultaneityTests.swift
git commit -m "feat(gestures): add .switchPan GestureRole + simultaneity pairings"
```

---

### Task 2: Add the `switchPan` recognizer + handler + role/subordination (App)

**Files:**
- Modify: `App/TerminalGestureController.swift`

**Interfaces:** new `switchPan` recognizer; `setSwitchPanEnabled(_:)`; `handleSwitchPan(_:)` (the switch half of the old `handleScrollViewPan`); `role(of:)` maps `switchPan`. Removes the native-pan `addTarget` of the switch logic.

- [ ] **Step 1: Declare the recognizer**

Near the `altScreenPan` declaration (~line 116), add:

```swift
    /// OUR always-on window-switch pan. Unlike `altScreenPan` (only `.appOwnsInput`), this is
    /// enabled in `.localScroll`/`.mouseReporting` where the plain-shell swipe used to ride
    /// SwiftTerm's native scroll pan, which does NOT track a horizontal drag on a freshly
    /// created pane (contentSize 0). Owning the recognizer removes that dependency: the swipe
    /// fires regardless of scroll-view state. Axis-gated (DragAxisLock) so it acts only on a
    /// horizontal-dominant drag; the native scroll pan keeps handling vertical scroll.
    private var switchPan: UIPanGestureRecognizer!
```

- [ ] **Step 2: Create + register it, enabled at install; stop riding the native pan**

In `installOurRecognizers`, after the `altScreenPan` creation block (~240), add:

```swift
        switchPan = UIPanGestureRecognizer(target: self, action: #selector(handleSwitchPan(_:)))
        switchPan.delegate = self
        // Enabled at install (NOT via modeTracker.onChange, which fires only on a mode CHANGE
        // and so never fires for a fresh pane that starts in .localScroll: the exact bug).
        // The mount then toggles it on mode transitions via `setSwitchPanEnabled`.
        switchPan.isEnabled = true
```

Update the `ours` array (~242) to include it:

```swift
        ours = [singleTap, doubleTap, tripleTap, longPress, twoFingerTap, altScreenPan, switchPan]
```

Delete the native-pan switch `addTarget` (~250): remove the line
`view.panGestureRecognizer.addTarget(self, action: #selector(handleScrollViewPan(_:)))`
and its comment (the switch no longer rides the native pan). Keep the `observeStrayRecognizers` call.

In `detach` (~267), remove the matching
`view.panGestureRecognizer.removeTarget(self, action: #selector(handleScrollViewPan(_:)))`
(nothing was added; leaving it is harmless but delete for correctness).

- [ ] **Step 3: Add `setSwitchPanEnabled` (mirror `setAltScreenPanEnabled`)**

After `setAltScreenPanEnabled` (~278), add:

```swift
    /// Enable OUR switch pan for `.localScroll`/`.mouseReporting` and disable it in
    /// `.appOwnsInput` (there `altScreenPan` owns the switch, exactly one switch-owner per
    /// mode). Called by the mount from `modeTracker.onChange`, alongside `setAltScreenPan`.
    func setSwitchPanEnabled(_ enabled: Bool) {
        switchPan?.isEnabled = enabled
        DebugLog.shared.log(.gesture, "switchPan enabled=\(enabled)")
    }
```

- [ ] **Step 4: Rename `handleScrollViewPan` -> `handleSwitchPan` (it is now our pan's selector)**

Replace `handleScrollViewPan` (~429-444) with `handleSwitchPan`. Body is the same switch logic (begin/drive/resolve), relabeled:

```swift
    /// OUR switch pan handler (`.localScroll`/`.mouseReporting`). Axis-gated: on a
    /// horizontal-dominant drag it drives the window switch (via `driveLiveSwitch` /
    /// `resolveLiveSwitch`); on a vertical/pending drag it does nothing (the native scroll
    /// pan, co-recognizing, handles the scroll). Unlike the old ride-the-scroll-pan target,
    /// this fires regardless of scroll-view content/state.
    @objc private func handleSwitchPan(_ g: UIPanGestureRecognizer) {
        guard let view = terminalView else { return }
        switch g.state {
        case .began:
            beginDrag("switchPan", on: view)
        case .changed:
            _ = driveLiveSwitch(g, in: view)   // horizontal -> switch; else no-op (scroll pan scrolls)
        case .ended, .cancelled:
            if resolveLiveSwitch(g, in: view) { return }   // switch committed/spring-back
            DebugLog.shared.log(.gesture, "drag-end owner=switchPan imode=\(dragMode) outcome=none")
        default: break
        }
    }
```

(Any other reference to `handleScrollViewPan` in the file, e.g. in comments, should be updated to `handleSwitchPan`; the `#selector` in Step 2 already points to it.)

- [ ] **Step 5: Map `switchPan` in `role(of:)` BEFORE the fallback selectionPan classification**

In `role(of:)` (~718), add the `switchPan` identity check alongside `altScreenPan` (it MUST come before the `if g is UIPanGestureRecognizer { return .selectionPan }` fallback at ~729, or our switchPan would be misclassified as a selection pan):

```swift
        if g === altScreenPan { return .altScreenPan }
        if g === switchPan { return .switchPan }
```

- [ ] **Step 6: Extend selection subordination to `switchPan`**

The `shouldRequireFailureOf` (~751) currently subordinates the selection pan to the scroll pan only. Extend it so the selection pan must also fail vs the switch pan:

```swift
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        guard role(of: g) == .selectionPan else { return false }
        return role(of: other) == .scrollPan || role(of: other) == .switchPan
    }
```

Also, in `subordinateSelectionPan` (the at-birth wiring that calls `require(toFail: scrollPan)`), add `require(toFail: switchPan)` so the selection pan is subordinated to our switch pan too. (Find the `require(toFail:)` call in `subordinateSelectionPan` and add the switchPan requirement next to it.)

- [ ] **Step 7: Verify (macOS CI compile)** — App tier; not Linux-buildable. macOS job is the gate.

- [ ] **Step 8: Commit**

```bash
git add App/TerminalGestureController.swift
git commit -m "feat(gestures): dedicated always-on switchPan (stop riding native scroll pan for the switch)"
```

---

### Task 3: Toggle `switchPan` on mode transitions in the mount (App)

**Files:**
- Modify: `App/TmuxPaneContainer.swift`

The `modeTracker.onChange` handler flips per-mode state, but ONLY on a mode CHANGE (so a fresh `.localScroll` pane never triggers it: that is why `switchPan` is enabled at install in Task 2). Here we ADD the transition toggle so `switchPan` is disabled in `.appOwnsInput` (where `altScreenPan` owns the switch) and enabled otherwise.

- [ ] **Step 1: Add `setSwitchPan` on the Coordinator (mirror `setAltScreenPan`)**

Near `setAltScreenPan(for:enabled:)` (~432), add:

```swift
        /// Enable/disable a pane's switch pan (mirrors `setAltScreenPan`). Called from the
        /// mode-transition handler so exactly one switch-owner is live per mode: `switchPan`
        /// in `.localScroll`/`.mouseReporting`, `altScreenPan` in `.appOwnsInput`.
        func setSwitchPan(for view: TerminalView, enabled: Bool) {
            MainActor.assumeIsolated {
                gestureControllers[ObjectIdentifier(view)]?.setSwitchPanEnabled(enabled)
            }
        }
```

- [ ] **Step 2: Toggle it in `modeTracker.onChange`**

In `makeUIView`'s `modeTracker.onChange` (~87-96), alongside `setAltScreenPan(... enabled: mode == .appOwnsInput)`, add:

```swift
                v.coordinator?.setSwitchPan(for: view, enabled: mode != .appOwnsInput)
```

- [ ] **Step 3: Verify (macOS CI compile)** — App tier; macOS job is the gate.

- [ ] **Step 4: Commit**

```bash
git add App/TmuxPaneContainer.swift
git commit -m "feat(gestures): toggle switchPan by mode (disabled in appOwnsInput, enabled otherwise)"
```

---

### Task 4: Kit green + push (macOS CI) + device-verify

**Files:** none (verification).

- [ ] **Step 1: Full Kit suite green**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS (baseline + the 4 new GestureSimultaneity tests).

- [ ] **Step 2: Push + confirm CI**

```bash
git push github feat/finger-drag-window-transition
```
Confirm `lint`/`linux-swift` + `macos` compile green (`linux-rust` flake ignorable: no Rust changed).

- [ ] **Step 3: Device-verify (THE fix)**

- Plain-shell swipe switches windows RELIABLY, INCLUDING immediately after switching to a freshly-created plain-shell window (the exact repro: swipe to a non-alt window, then swipe again -> it switches, not dead).
- Repeat several switches in a row: every one works.
- Vertical scroll + momentum unaffected at a plain shell.
- Alt-screen (vim/claude) switch still works.
- Diagonal drag scrolls (no wrong switch); fast horizontal flick switches.
- Double/triple-tap text selection still works (not hijacked by switchPan).
- No visible vertical twitch at the start of a horizontal switch (if present, note it: add a minimal offset-restore in a follow-up).
- Confirm the log now shows `drag-begin winner=switchPan imode=localScroll` on plain-shell swipes (proof the owned pan fires).

- [ ] **Step 4: Record outcome** in `TODO.md` + memory.

---

## Self-Review

**Spec coverage:** dedicated always-on switchPan = Task 2 (recognizer + handler + role + subordination) + Task 3 (mode toggle). Simultaneity pairings = Task 1 (Kit + tests). Stop riding native pan = Task 2 Step 2 (delete addTarget). Selection subordinated to switchPan = Task 2 Step 6. Enabled-at-install (not onChange-dependent) = Task 2 Step 2 comment + Task 3 (transition toggle only). No offset-restore (deferred) = spec, not implemented. Device matrix = Task 4 Step 3. Covered.

**Placeholder scan:** none. App-tier steps note no local compile. Every code step shows full code.

**Type consistency:** `GestureRole.switchPan` defined Task 1, used in `role(of:)` Task 2 Step 5 and pairings Task 1 Step 3. `setSwitchPanEnabled(_:)` defined Task 2 Step 3, called by `setSwitchPan(for:enabled:)` Task 3 Step 1, called in onChange Task 3 Step 2. `handleSwitchPan(_:)` selector defined Task 2 Step 4, referenced in the recognizer creation Task 2 Step 2. `switchPan` added to `ours` (Task 2 Step 2) so `role(of:)`'s `!ours.contains` logic + the at-install sweep treat it as ours. No drift.
