# Keybar-Inset via keyboardLayoutGuide Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the dead band between the terminal and the keybar that appears AFTER an app-switch / window-change, by laying out the panes to end at the keybar's ACTUAL top edge (tracked live via `keyboardLayoutGuide`) instead of a `bounds.height - guessedKeybarHeight` value that only aligns on first connect.

**Architecture:** The current fix subtracts `firstResponderKeybarHeight()` from `bounds.height`. That guessed height aligns with the floating keybar on first connect but not after the keybar re-lays-out on re-entry (device: `gapToKeybar=56` post-switch while `gapPx=0` hides it). The corrected approach reads the REAL keyboard/accessory top position from `ContainerView.keyboardLayoutGuide.layoutFrame.minY` (UIKit, iOS 15+, auto-tracks the keyboard + its inputAccessoryView across show/hide/animation/app-switch) and uses THAT as the usable bottom for both the grid and the pane frames. The existing container-space `gapToKeybar` diagnostic self-verifies the alignment.

**Tech Stack:** Swift 6 (App tier = macOS-CI-only, not Linux-buildable), UIKit `keyboardLayoutGuide`, XCTest, Docker `semicolyn-dev`.

## Global Constraints

- **App-tier change** in `App/TmuxPaneContainer.swift` (`ContainerView`), macOS-CI + device verified, NOT Linux-buildable. Hand-trace.
- **`keyboardLayoutGuide`** is a `UIView` property (iOS 15+); `container.keyboardLayoutGuide.layoutFrame` is the keyboard's frame in the container's coordinate space (`.null`/empty when the keyboard is down). Its `.minY` is the keyboard-top (and the keybar, an inputAccessoryView, sits at/above that). USE it to derive the usable bottom; do NOT re-add a `.safeAreaInset` keybar (that mount was deliberately removed, `SessionView.swift` ~122/179).
- **Keep the existing Kit helper `visibleTerminalHeight` and its tests** as the manual fallback when `keyboardLayoutGuide` gives no usable frame (keyboard down or `.null`).
- **The self-verifying signal is `gapToKeybar` (container-space), NOT `gapPx`.** The fix is correct when `gapToKeybar ~= 0` in BOTH first-connect and post-switch states.
- **SPDX header intact. No em-dash (U+2014) / en-dash (U+2013).** Conventional commits. Linux test: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`.
- **Do NOT regress the two known failure modes:** full-height panes -> hidden bottom rows; pane-shorter-than-keybar -> dead band. The keyboardLayoutGuide value must drive grid AND pane frames identically (the same invariant as before, now sourced from the real keyboard position).

---

### Task 1: Add a pure Kit helper for the usable bottom from a keyboard-guide frame

**Files:**
- Modify: `Sources/SemicolynKit/Terminal/TerminalGrid.swift`
- Test: `Tests/SemicolynKitTests/VisibleTerminalHeightTests.swift` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: `usableHeightFromKeyboardTop(rawHeight: Double, keyboardTopY: Double?) -> Double` (pure). When `keyboardTopY` is non-nil and `0 < keyboardTopY <= rawHeight`, returns `keyboardTopY` (the pane bottom = the keyboard/keybar top in container coords). Otherwise (nil = keyboard down / no guide; or out-of-range) returns `rawHeight` (full height). Clamps to `[0, rawHeight]`.

**Why Kit:** keep the ONE piece of arithmetic (choose keyboard-top vs full height, clamped) pure and unit-tested, so the App wiring is a thin read of `keyboardLayoutGuide` feeding this. Mirrors `visibleTerminalHeight`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/SemicolynKitTests/VisibleTerminalHeightTests.swift`:

```swift
    // keyboardLayoutGuide gives the keyboard/keybar TOP in container coords; the pane bottom is
    // exactly there. A valid top (e.g. 361 in a 417 container) is the usable height directly.
    func testUsableFromKeyboardTopValid() {
        XCTAssertEqual(usableHeightFromKeyboardTop(rawHeight: 417, keyboardTopY: 361), 361, accuracy: 1e-9)
    }
    // Keyboard down (nil frame) -> full height.
    func testUsableFromKeyboardTopNil() {
        XCTAssertEqual(usableHeightFromKeyboardTop(rawHeight: 417, keyboardTopY: nil), 417, accuracy: 1e-9)
    }
    // Degenerate (top <= 0) -> full height (fail open, no zero/negative pane).
    func testUsableFromKeyboardTopNonPositive() {
        XCTAssertEqual(usableHeightFromKeyboardTop(rawHeight: 417, keyboardTopY: 0), 417, accuracy: 1e-9)
        XCTAssertEqual(usableHeightFromKeyboardTop(rawHeight: 417, keyboardTopY: -5), 417, accuracy: 1e-9)
    }
    // Top beyond the container height (guide reported larger) -> clamp to rawHeight.
    func testUsableFromKeyboardTopBeyond() {
        XCTAssertEqual(usableHeightFromKeyboardTop(rawHeight: 417, keyboardTopY: 500), 417, accuracy: 1e-9)
    }
    // Compose to the row count: 361 top, 11.15 cell -> 32 rows (the correct fit).
    func testUsableFromKeyboardTopComposesToRows() {
        let usable = usableHeightFromKeyboardTop(rawHeight: 417, keyboardTopY: 361)
        XCTAssertEqual(terminalGrid(width: 402, height: usable, cellWidth: 5.66, cellHeight: 11.15)?.rows, 32)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter VisibleTerminalHeightTests`
Expected: FAIL, `usableHeightFromKeyboardTop` undefined.

- [ ] **Step 3: Add the implementation**

Append to `Sources/SemicolynKit/Terminal/TerminalGrid.swift`:

```swift
/// The terminal-usable height when the keyboard/keybar top is known from UIKit's
/// `keyboardLayoutGuide`. `keyboardTopY` is the guide's `layoutFrame.minY` in the container's
/// coordinate space (the pane bottom sits exactly there); `nil` when the keyboard is down or the
/// guide has no usable frame. Returns `keyboardTopY` when it is a valid interior value
/// (`0 < keyboardTopY <= rawHeight`), else the full `rawHeight` (fail open: keyboard-down or a
/// bogus guide value must never yield a zero/negative pane). This is preferred over
/// `visibleTerminalHeight(rawHeight:keybarHeight:)` because it uses the keybar's REAL position
/// (which re-lays-out after an app-switch) instead of a measured height that only aligns on first
/// connect.
public func usableHeightFromKeyboardTop(rawHeight: Double, keyboardTopY: Double?) -> Double {
    guard let top = keyboardTopY, top > 0, top <= rawHeight else { return rawHeight }
    return top
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter VisibleTerminalHeightTests`
Expected: PASS (all, including the pre-existing tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Terminal/TerminalGrid.swift Tests/SemicolynKitTests/VisibleTerminalHeightTests.swift
git commit -m "feat(kit): usableHeightFromKeyboardTop for keyboardLayoutGuide-driven inset"
```

---

### Task 2: Drive the container's usable height from keyboardLayoutGuide

**Files:**
- Modify: `App/TmuxPaneContainer.swift` (`ContainerView.layoutSubviews` ~715-720; `apply` ~968; add a `keyboardTopInContainer()` helper)

**Interfaces:**
- Consumes: `SemicolynKit.usableHeightFromKeyboardTop(rawHeight:keyboardTopY:)` (Task 1); existing `visibleTerminalHeight` (fallback); `fittedPaneRects(layout:cell:usableHeight:)`, `terminalGrid`.
- Produces: `keyboardTopInContainer() -> Double?` (reads `self.keyboardLayoutGuide.layoutFrame`; returns its `.minY` when the frame is non-empty and inside the view, else nil).

**Design note:** replace the `usableH = visibleTerminalHeight(bounds.height, kbH)` computation (which used the guessed accessory height) with `usableH = usableHeightFromKeyboardTop(bounds.height, keyboardTopInContainer())`. Everything downstream (grid, `fittedPaneRects`, `logGeometry`) already consumes `usableH`, so this is a source swap plus the helper. The keybar (inputAccessoryView) sits on top of the keyboard, and `keyboardLayoutGuide` tracks the keyboard's frame INCLUDING the accessory on iOS 15+, so `.minY` is the keybar top. Task 3 device-verifies this assumption via `gapToKeybar`; if the guide excludes the accessory, Task 3 documents the one-line adjustment (subtract the measured keybar height from the top).

- [ ] **Step 1: Add the keyboard-top reader**

In `ContainerView`, add:

```swift
        /// The keyboard/keybar top edge in THIS view's coordinate space, via `keyboardLayoutGuide`
        /// (iOS 15+, auto-tracks the keyboard + its inputAccessoryView across show/hide/animation
        /// and the post-app-switch re-layout that a measured keybar height missed). Returns nil when
        /// the keyboard is down / the guide has no usable frame, so the caller falls back to full
        /// height. The pane bottom is laid out to this Y so it meets the keybar top with no dead band.
        private func keyboardTopInContainer() -> Double? {
            let f = keyboardLayoutGuide.layoutFrame
            guard f.height > 0, f.width > 0, f.minY.isFinite, f.minY > 0 else { return nil }
            return Double(f.minY)
        }
```

- [ ] **Step 2: Use it for `usableH` in `layoutSubviews`**

Replace the line (~720):

```swift
            let usableH = visibleTerminalHeight(rawHeight: Double(bounds.height), keybarHeight: Double(kbH))
```

with:

```swift
            // Prefer the REAL keyboard/keybar top from keyboardLayoutGuide (it re-lays-out
            // correctly after an app-switch, which a measured keybar height did not: device
            // 2026-08-02 gapToKeybar=56 post-switch). Fall back to the measured-height reduction
            // only if the guide has no usable frame (older iOS / no window).
            let usableH: Double = {
                if let top = keyboardTopInContainer() {
                    return usableHeightFromKeyboardTop(rawHeight: Double(bounds.height), keyboardTopY: top)
                }
                return visibleTerminalHeight(rawHeight: Double(bounds.height), keybarHeight: Double(kbH))
            }()
```

`kbH` is still computed above (used for the fallback + `logGeometry`); leave that line. The render-storm early-out keys on `LayoutInputs(bounds, cell, keybarH: kbH)`; ADD the keyboard-top to the early-out inputs so a keyboard-position change (which can happen with bounds/kbH unchanged) re-runs layout. Change the `LayoutInputs` construction (~699) to include the keyboard top, and add a stored field to `LayoutInputs`. If `LayoutInputs` is a struct with an `Equatable` synthesis, add `keyboardTop: Double?` to it and pass `keyboardTopInContainer()`; keep `kbH` too. (Read the `LayoutInputs` definition first; mirror its existing fields.)

- [ ] **Step 3: Use it in `apply`**

In `apply` (~968), replace the `usableH` computation that currently uses `visibleTerminalHeight(..., keybarHeight: firstResponderKeybarHeight())` with the same keyboard-top-preferred logic:

```swift
            let usableH: Double = {
                if let top = keyboardTopInContainer() {
                    return usableHeightFromKeyboardTop(rawHeight: Double(bounds.height), keyboardTopY: top)
                }
                return visibleTerminalHeight(rawHeight: Double(bounds.height),
                                             keybarHeight: Double(firstResponderKeybarHeight()))
            }()
```

Keep passing `usableHeight: usableH` to `fittedPaneRects` (unchanged from the prior task).

- [ ] **Step 4: Kit still green + commit**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS (Kit unaffected; confirms no accidental Kit edit).

```bash
git add App/TmuxPaneContainer.swift
git commit -m "fix(app): lay out panes to keyboardLayoutGuide top (post-switch keybar gap)"
```

---

### Task 3: Push, macOS CI, TestFlight, device-verify gapToKeybar in BOTH states

**Files:** none (verification).

- [ ] **Step 1: Push + macOS CI**

```bash
git push github feat/gesture-diagnostics
gh workflow run CI --ref feat/gesture-diagnostics
```

Wait for the `macos` job green (~15-18 min). Rerun `linux-rust` only if it flakes on sshd readiness.

- [ ] **Step 2: TestFlight (after macos green)**

```bash
gh workflow run "Release to TestFlight" --repo ds7n/semicolyn --ref feat/gesture-diagnostics
```

- [ ] **Step 3: Device-verify the alignment in BOTH states (the whole point)**

Capture on device (syslog sink UP, TLS 6514/TCP, `.geometry` on) in a Claude Code pane, keyboard UP. Read the newest `geo:layout`. Confirm:
- **First connect:** `gapToKeybar ~= 0` (prompt/status/tmux bar visible above the keybar, no band).
- **After an app-switch (background Semicolyn, reopen) AND after a window-change:** `gapToKeybar ~= 0` STILL (this is the case that regressed before). If `gapToKeybar` is a large positive, the band returned; if negative, panes overlap behind the keybar.
- `paneRows` matches `grid` rows (no stale SwiftTerm grid).
- Keyboard DOWN: container fills full height (usableH == bounds.height), terminal not shrunk.
- Split window still tiles with no gap.

**If `gapToKeybar ~= kbH` (a constant ~56 residual) in BOTH states:** `keyboardLayoutGuide` tracks the keyboard EXCLUDING the inputAccessoryView, so the container bottom lands one keybar-height too low. The one-line fix: subtract the measured keybar height from the keyboard top before using it (`top - firstResponderKeybarHeight()`), i.e. the pane bottom is the ACCESSORY top = keyboard-top minus accessory height. The `gapToKeybar` residual tells us this objectively; adjust and re-verify. Do NOT guess which; read the number.

---

## Self-Review notes (for the implementer)

- **Spec coverage:** inset driven by the REAL keybar position (keyboardLayoutGuide) not a guessed height (Task 2), pure clamp helper + tests (Task 1), self-verifying via the existing container-space `gapToKeybar` (Task 3), keyboard-down + fallback preserved (helper returns full height on nil), the grid/pane invariant preserved (both use the same `usableH`).
- **The invariant still holds:** grid and every `fittedPaneRects` call use the SAME `usableH`; only its SOURCE changed (keyboard-top preferred, measured-height fallback).
- **The residual-kbH contingency (Task 3 step 3) is explicit, not a guess:** the diagnostic distinguishes "guide includes accessory" (gapToKeybar~=0, done) from "guide excludes accessory" (gapToKeybar~=kbH, subtract accessory height). One device read decides.
- **Do not re-add `.safeAreaInset` for the keybar** (deliberately removed; the keybar is a per-pane inputAccessoryView).
