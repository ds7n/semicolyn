<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Switch-Sizing + Scroll Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the switch-back sizing thrash (B/C), reduce alt-screen scroll grit (D), and add recognizer-level logging to catch the intermittent swipe miss (A).

**Architecture:** Three independent fixes, one build. B/C: keybar reports its last VALID height when measured at width 0 (fresh attach on switch). D: raise the fling stop-velocity floor so the decaying fling ends crisply instead of dribbling slow single wheel-clicks. A: make the existing stray-recognizer observer actually log, and install it in `.localScroll` too.

**Tech Stack:** Swift 6, SwiftTerm, UIKit (App tier: macOS CI + device), XCTest (Kit tier: Linux/Docker).

## Global Constraints

- SPDX header on every source file. No em-dashes anywhere. Conventional commits.
- `Sources/SemicolynKit/`: platform-agnostic, Linux-tested, no UIKit/SwiftUI.
- `App/`: Apple-only, not Linux-buildable, macOS CI + device verified.
- Tests real: exact-value assertions; include a case that fails against the pre-fix behavior.
- `@MainActor` trap: wrap `DebugLog.shared.log`/UIKit reached from SwiftTerm `@objc`/delegate callbacks in `MainActor.assumeIsolated {}` (not needed for UIView overrides or `@objc` selectors on an `@MainActor` class).
- Kit tests via Docker: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`.
- Keep the three fixes in separate commits (isolatable).

**Spec:** `docs/superpowers/specs/2026-07-22-switch-sizing-and-scroll-polish-design.md`.

---

### Task 1 (B/C): keybar returns last-valid height when measured at width 0 (App)

**Root cause:** on a window switch the freshly-attached `KeybarInputAccessory` has `bounds.width == 0`, so `contentHeight()`'s `sizeThatFits` returns a degenerate ~seed height; `ContainerView.firstResponderKeybarHeight()` reads that, so `usableH`/grid thrash and the history seed paints at the wrong size (cursor-in-corner). Fix: when not yet laid out (width <= 0), return the already-cached `lastMeasuredHeight` instead of measuring.

**Files:**
- Modify: `App/KeybarInputAccessory.swift` (`contentHeight()`, lines ~96-102; uses `lastMeasuredHeight` line 49, `seedHeight` line 45).

- [ ] **Step 1: Guard `contentHeight()` on width**

Replace the body of `contentHeight()` (lines ~96-102) with:

```swift
    private func contentHeight() -> CGFloat {
        // Not yet laid out (width 0) => `sizeThatFits` returns a degenerate height (the seed).
        // This happens for a freshly-attached accessory on a window switch, and made
        // `firstResponderKeybarHeight` report a transient wrong kbH (40 not 74), thrashing the
        // grid and painting the history seed at the wrong size (device 2026-07-22, the
        // cursor-in-corner switch-back). Fall back to the last VALID measurement, which
        // predictor-strip / hidden-keybar / hardware-keyboard changes keep current.
        guard bounds.width > 0 else {
            return lastMeasuredHeight > 0 ? lastMeasuredHeight : Self.seedHeight
        }
        let fitted = host.sizeThatFits(in: CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        let h = fitted.height > 0 ? fitted.height : Self.seedHeight
        DebugLog.shared.log(.keybar, "keybar:contentHeight h=\(h)")
        return h
    }
```

Note: the old code used `let width = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width` then measured; the fix removes the `UIScreen` fallback path (that fallback was the bug: measuring at a wrong width) and returns the cached height instead.

- [ ] **Step 2: Self-review (App tier, no local compile)**

Confirm: `lastMeasuredHeight` (line 49) and `seedHeight` (line 45) are in scope; `intrinsicContentSize` (line 107-112) still sets `lastMeasuredHeight = height` on every valid measure, so the cache stays current for legitimate height changes; `layoutSubviews` (line 117) re-measures once real bounds exist and invalidates if changed, so the correct height propagates once laid out. macOS CI + device are the gates.

- [ ] **Step 3: Commit**

```bash
git add App/KeybarInputAccessory.swift
git commit -m "fix(keybar): return last-valid height when measured at width 0 (switch-back sizing thrash)"
```

---

### Task 2 (D): raise fling stop-velocity floor for a crisp end (Kit + App)

**Root cause:** the alt-screen fling ticks every frame but emits only whole wheel-line cells; as it decays below ~1 cell/frame, it dribbles slow single clicks with gaps = grit. `ScrollMomentum.stopVelocity` (currently 20.0 pt/sec) is the floor at which the App tick loop stops. Raising it ends the fling before the gritty slow tail (cannot make discrete wheel lines sub-pixel smooth; a crisp stop is the best available).

**Files:**
- Modify: `Sources/SemicolynKit/Terminal/ScrollMomentum.swift` (`stopVelocity`, line ~29).
- Modify: `Tests/SemicolynKitTests/ScrollMomentumTests.swift` (add/adjust a boundary test).

**Interfaces:** `ScrollMomentum.isFinished(at:)` (unchanged signature) now returns true at a higher velocity floor. `stopVelocity` value changes.

- [ ] **Step 1: Write the failing test**

Add to `Tests/SemicolynKitTests/ScrollMomentumTests.swift` (inside the class):

```swift
    // D (2026-07-22): the fling must END while it is still moving at a few lines/sec, not
    // dribble out slow single wheel-clicks (the alt-screen grit). With the raised floor, a
    // fling that has decayed to ~60 pt/sec is considered finished (a ~6-line cell at ~10pt
    // is <1 line per few frames). Below the floor -> finished; comfortably above -> not.
    func testRaisedStopFloorEndsFlingWhileStillSlowMoving() {
        // A fling released fast enough to qualify, sampled at a time where its instantaneous
        // velocity has decayed to ~50 pt/sec, must now be finished (grit-cut).
        let m = ScrollMomentum(velocity: 1200)
        // find a t where velocity(at:) is ~50 pt/sec: v0 * e^(-k t) = 50.
        let k = ScrollMomentum.decayRate
        let tAtFifty = Foundation.log(1200.0 / 50.0) / k
        XCTAssertTrue(m.isFinished(at: tAtFifty),
                      "fling at ~50 pt/sec should be finished with the raised floor")
        // And it must NOT be finished while still moving briskly (~150 pt/sec).
        let tAtOneFifty = Foundation.log(1200.0 / 150.0) / k
        XCTAssertFalse(m.isFinished(at: tAtOneFifty),
                       "fling at ~150 pt/sec should still be running")
    }

    // The stop floor is the raised value (no silent retune back).
    func testStopVelocityFloorValue() {
        XCTAssertEqual(ScrollMomentum.stopVelocity, 70.0)
    }
```

(Add `import Foundation` to the test file if not already present.)

- [ ] **Step 2: Run to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ScrollMomentumTests`
Expected: FAIL (`testStopVelocityFloorValue` expects 70.0 but it is 20.0; `testRaisedStopFloorEndsFlingWhileStillSlowMoving` fails because 50 pt/sec is above the old 20.0 floor so `isFinished` is false).

- [ ] **Step 3: Raise the floor**

In `Sources/SemicolynKit/Terminal/ScrollMomentum.swift`, change `stopVelocity` (line ~29) from `20.0` to `70.0` and update its doc comment:

```swift
    /// Instantaneous velocity (points/sec) below which the fling is considered stopped, so the
    /// App's tick loop ends. Raised from 20 to 70 (2026-07-22): at ~1 wheel-line (~10pt) per
    /// event, a fling below ~70 pt/sec dribbles out slow single clicks with visible gaps (the
    /// alt-screen "grit"), so we end the fling crisply here instead of tailing off. A fast
    /// flick still carries; only the gritty slow tail is cut.
    public static let stopVelocity: Double = 70.0
```

- [ ] **Step 4: Run to verify pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ScrollMomentumTests`
Expected: PASS (all ScrollMomentumTests including the two new ones).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Terminal/ScrollMomentum.swift Tests/SemicolynKitTests/ScrollMomentumTests.swift
git commit -m "fix(scroll): raise fling stop-velocity floor to end alt-screen scroll crisply (cut grit tail)"
```

Note: no App code change is required for D. `tickAltScreenFling` already calls
`momentum.isFinished(at:)` and `startAltScreenFling` already guards `!momentum.isFinished(at: 0)`;
both pick up the raised floor automatically. (Verify this in Step 2 review: no App edit needed.)

---

### Task 3 (A): make the stray-recognizer observer log, in both modes (App)

**Finding:** intermittent swipe misses are invisible because `observeRecognizerState` is a no-op and `observeStrayRecognizers` is only installed in `.appOwnsInput`. Make the observer LOG which non-ours recognizer fired, and install it in `.localScroll` too, so the next device log captures a swipe that loses the recognizer race before `drag-begin`.

**Files:**
- Modify: `App/TerminalGestureController.swift` (`observeRecognizerState` lines ~318-320; install site in `beginDrag` line ~363).

- [ ] **Step 1: Make the observer log the firing recognizer**

Replace `observeRecognizerState` (lines ~318-320) with:

```swift
    @objc private func observeRecognizerState(_ g: UIGestureRecognizer) {
        guard g.state == .began || g.state == .changed else { return }
        // A: catch a swipe that loses the recognizer race before `drag-begin` logs. Identify
        // which non-ours recognizer began/changed on the terminal view (SwiftTerm's scroll or
        // lazy selection pan). If this fires without a following `drag-begin`, that recognizer
        // pre-empted our switch drag (the invisible intermittent-swipe miss, device 2026-07-22).
        let kind: String
        if g === terminalView?.panGestureRecognizer { kind = "scrollPan" }
        else if g is UIPanGestureRecognizer { kind = "strayPan" }
        else { kind = String(describing: type(of: g)) }
        DebugLog.shared.log(.gesture,
            "gr-observe \(kind) state=\(g.state.rawValue) mode=\(callbacks.currentMode())")
    }
```

This runs on an `@objc` selector of the `@MainActor` controller, so no `MainActor.assumeIsolated` wrap is needed.

- [ ] **Step 2: Install the observer in localScroll too**

In `beginDrag` (line ~363), the observer is currently installed only in `.appOwnsInput`:
```swift
        if dragMode == .appOwnsInput { observeStrayRecognizers(on: view) }
```
Change it to install in every mode (the intermittent miss is at a plain shell = `.localScroll`):
```swift
        observeStrayRecognizers(on: view)   // A: observe stray recognizers in ALL modes (catch localScroll swipe-race misses)
```

- [ ] **Step 3: Self-review (App tier, no local compile)**

Confirm: `observeStrayRecognizers` is idempotent (UIKit ignores duplicate identical target/action, per its existing doc), so calling it every drag is safe; `callbacks.currentMode()` is available in the observer; the log is under `.gesture` (already used). No behavior change beyond logging. macOS CI + device are the gates.

- [ ] **Step 4: Commit**

```bash
git add App/TerminalGestureController.swift
git commit -m "feat(gestures): log stray-recognizer firing in all modes (instrument intermittent swipe miss)"
```

---

### Task 4: Kit green + push (macOS CI) + device-verify

**Files:** none (verification).

- [ ] **Step 1: Full Kit suite green**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS (baseline + the new ScrollMomentum tests).

- [ ] **Step 2: Push + confirm CI**

```bash
git push github feat/finger-drag-window-transition
```
Confirm `lint`/`linux-rust`/`linux-swift` + `macos` compile all green.

- [ ] **Step 3: Device-verify (per-symptom)**

- B/C: switch windows back and forth several times, the returned window renders at the CORRECT size immediately (no cursor-in-corner, no mis-sized redraw / visible grid thrash on return).
- D: in an alt-screen app (vim/htop), flick-scroll ends crisply without a gritty slow single-click tail; a fast flick still carries a reasonable distance.
- A: (no visible change) after a session that includes some plain-shell swipes that fail to switch, the captured log now contains `gr-observe strayPan ... mode=localScroll` lines (evidence of the recognizer-race miss) to diagnose next round.

- [ ] **Step 4: Record outcome** in `TODO.md` + memory.

---

## Self-Review

**Spec coverage:** B/C (keybar width-0 fallback) = Task 1. D (raise stop floor for crisp fling end) = Task 2, pure Kit + test, no App change needed (verified: App already calls isFinished). A (recognizer logging in all modes) = Task 3. Kit test for D fails pre-fix (floor 70 vs 20). Device matrix per symptom = Task 4 Step 3. All covered.

**Placeholder scan:** none. App-tier steps state no local compile (correct for tier). Every code step shows full replacement code.

**Type consistency:** `ScrollMomentum.stopVelocity: Double` changes value only (20->70), signature of `isFinished(at:)` unchanged; App callers unaffected. `observeRecognizerState(_:)` selector signature unchanged (still `@objc`, `UIGestureRecognizer` arg). `contentHeight() -> CGFloat` signature unchanged. No cross-task interface drift (the three tasks touch disjoint files except none share a symbol).
