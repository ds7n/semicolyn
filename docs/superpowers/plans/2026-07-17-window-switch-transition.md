<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Animated window-switch transition — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On a horizontal swipe that switches tmux windows, slide the current window's content out in the swipe direction immediately, then slide the new window's panes in from the opposite side when tmux delivers them, with a timeout safety net.

**Architecture:** The pure swipe-delta → slide-edge mapping is a Kit function (tested). The animation is App-tier UIKit `transform` on a NEW `paneContentView` that wraps all pane subviews inside `ContainerView` (so one view animates and the tab strip, a SwiftUI sibling, is untouched). Slide-out fires from the swipe-release wiring; slide-in fires from `ContainerView.apply(state:)` when the active window changes with a pending transition.

**Tech Stack:** Swift 6, XCTest, SemicolynKit (Linux-tested) + App tier (macOS-CI + device). Docker `semicolyn-dev` for Kit tests.

## Global Constraints

- **Two tiers:** `Sources/SemicolynKit/` = pure, Linux-tested, `Sendable`, NO `import UIKit`/`SwiftUI`/`DebugLog`. App tier compiles ONLY on macOS CI (no local Swift build).
- **SPDX header** on every source file.
- **Tests real:** exact observable values; negative asserts the specific failure.
- **No em-dash (—)** in code/comments/commits. `→` U+2192 in log strings is fine.
- **Conventional commits.** Branch `fix/altscreen-tap-yield` (already carries the tap fix + this spec; branched off `github/main` = `298d916` which has the wheel code).
- **Run Kit tests:** `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <Suite>`.
- **@MainActor:** `ContainerView`/`Coordinator` run on the main thread; UIView work needs no `assumeIsolated` from within their own methods.

## Shipped facts this plan builds on (verified in current code)

- Swipe mapping (`GestureClassifier.swift:46`): `dx > 0 ? -1 : +1` — rightward swipe → `delta -1` (previous window); leftward → `+1` (next). Content-follows-finger.
- Slide-out site: `TmuxPaneContainer.swift` ~line 272, the `onSwitchWindow: { delta in … self?.onSwitchWindow(delta) }` closure in the gesture `callbacks`.
- Slide-in site: `ContainerView.apply(state:)` (~line 613); panes are DIRECT subviews via `addSubview(t)` (~line 682); `layoutSubviews` (~523) positions by frame each pass.
- `WindowTabStrip` is a SwiftUI SIBLING (`SessionView.swift:62`), NOT inside `ContainerView` — it must not be affected.

## File Structure

- `Sources/SemicolynKit/Terminal/WindowSlide.swift` (CREATE) — `SlideEdge` + `windowSlideDirection(delta:)`.
- `Tests/SemicolynKitTests/WindowSlideTests.swift` (CREATE) — direction tests.
- `App/WindowTransition.swift` (CREATE) — the UIKit two-phase animator + pending state + timeout.
- `App/TmuxPaneContainer.swift` (MODIFY) — add `paneContentView` wrapper; slide-out at swipe-release; slide-in + `previousActiveWindow` in `apply`.

---

## Task 1: Slide-direction decision (Kit)

**Files:**
- Create: `Sources/SemicolynKit/Terminal/WindowSlide.swift`
- Test: `Tests/SemicolynKitTests/WindowSlideTests.swift`

**Interfaces:**
- Produces:
  - `enum SlideEdge: Sendable, Equatable { case left, right }`
  - `func windowSlideDirection(delta: Int) -> (out: SlideEdge, in: SlideEdge)?`
- Mapping (pinned to the shipped swipe flip): `delta < 0` → `(out: .right, in: .left)`; `delta > 0` → `(out: .left, in: .right)`; `delta == 0` → `nil`.

- [ ] **Step 1: Write the failing test** — create `Tests/SemicolynKitTests/WindowSlideTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class WindowSlideTests: XCTestCase {
    // Rightward swipe -> delta -1 (previous window): current exits RIGHT, new enters from LEFT.
    func testPreviousSlidesOutRightInLeft() {
        let d = windowSlideDirection(delta: -1)
        XCTAssertEqual(d?.out, .right)
        XCTAssertEqual(d?.in, .left)
    }
    // Leftward swipe -> delta +1 (next window): current exits LEFT, new enters from RIGHT.
    func testNextSlidesOutLeftInRight() {
        let d = windowSlideDirection(delta: 1)
        XCTAssertEqual(d?.out, .left)
        XCTAssertEqual(d?.in, .right)
    }
    // Zero delta -> no switch, no transition.
    func testZeroDeltaNoTransition() {
        XCTAssertNil(windowSlideDirection(delta: 0))
    }
    // Magnitude does not change direction: large deltas map by SIGN like ±1.
    func testMagnitudeMapsBySign() {
        XCTAssertEqual(windowSlideDirection(delta: -5)?.out, .right)
        XCTAssertEqual(windowSlideDirection(delta: 5)?.out, .left)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter WindowSlideTests`
Expected: FAIL (`windowSlideDirection` / `SlideEdge` not defined).

- [ ] **Step 3: Implement** — create `Sources/SemicolynKit/Terminal/WindowSlide.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// A screen edge for the window-switch slide animation.
public enum SlideEdge: Sendable, Equatable { case left, right }

/// Which edge the OUTgoing window exits toward and which edge the INcoming window enters from,
/// for a window switch of `delta`. Content-follows-finger (matching the shipped swipe flip,
/// `GestureClassifier`: rightward swipe -> delta -1 = previous window): the current window
/// exits toward the finger-release direction and the new one enters from the opposite side.
/// `delta == 0` is not a switch, so it yields nil (no animation).
public func windowSlideDirection(delta: Int) -> (out: SlideEdge, in: SlideEdge)? {
    if delta < 0 { return (out: .right, in: .left) }   // previous window (rightward swipe)
    if delta > 0 { return (out: .left, in: .right) }    // next window (leftward swipe)
    return nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter WindowSlideTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Terminal/WindowSlide.swift Tests/SemicolynKitTests/WindowSlideTests.swift
git commit -m "feat(kit): windowSlideDirection — swipe delta -> slide edges for window-switch animation"
```

---

## Task 2: `WindowTransition` UIKit animator (App)

**Files:**
- Create: `App/WindowTransition.swift`

**Interfaces:**
- Consumes: `SlideEdge` (Kit).
- Produces (all `@MainActor`, App-tier):
  - `final class WindowTransition` with:
    - `func slideOut(_ edge: SlideEdge, view: UIView, width: CGFloat, completion: (() -> Void)?)` — animates `view.transform` to an off-screen translation toward `edge`.
    - `func beginPending(inEdge: SlideEdge, timeout: TimeInterval, onTimeout: @escaping () -> Void)` — records that a slide-in is expected from `inEdge`, arms a timeout.
    - `func consumePendingSlideIn(view: UIView, width: CGFloat) -> Bool` — if a slide-in is pending, starts `view` at the pending off-screen edge and animates it to `.identity`, clears pending + cancels timeout, returns true; else false.
    - `var pendingInEdge: SlideEdge?` (read for tests/asserts).
- Note: App tier — NOT locally buildable; macOS-CI + device gated.

- [ ] **Step 1: Create the animator** — `App/WindowTransition.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SemicolynKit

/// Two-phase window-switch slide (design: 2026-07-17-window-switch-transition-design.md).
/// On swipe release, `slideOut` translates the current pane-content view off-screen in the
/// swipe direction (responsive, independent of tmux). `beginPending` records that the NEW
/// window should slide IN from the opposite edge once tmux delivers it; `apply` calls
/// `consumePendingSlideIn` when the active window changes. A timeout clears a stuck pending
/// transition (slow/failed switch) so the content never sticks off-screen.
@MainActor
final class WindowTransition {
    private(set) var pendingInEdge: SlideEdge?
    private var timeoutItem: DispatchWorkItem?

    /// Duration of each slide phase.
    private let duration: TimeInterval = 0.22

    /// Slide the current content OUT toward `edge`. `completion` runs when the animation ends.
    func slideOut(_ edge: SlideEdge, view: UIView, width: CGFloat, completion: (() -> Void)? = nil) {
        let dx: CGFloat = (edge == .left) ? -width : width
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseIn], animations: {
            view.transform = CGAffineTransform(translationX: dx, y: 0)
        }, completion: { _ in completion?() })
    }

    /// Record that the incoming window should slide IN from `inEdge`, arming a timeout that
    /// invokes `onTimeout` (which should reset any lingering transform) if no slide-in arrives.
    func beginPending(inEdge: SlideEdge, timeout: TimeInterval, onTimeout: @escaping () -> Void) {
        pendingInEdge = inEdge
        timeoutItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.pendingInEdge != nil else { return }
            self.pendingInEdge = nil
            onTimeout()
        }
        timeoutItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)
    }

    /// If a slide-in is pending, start `view` off-screen at the pending edge and animate it to
    /// identity; clear pending + cancel the timeout. Returns whether a slide-in ran.
    @discardableResult
    func consumePendingSlideIn(view: UIView, width: CGFloat) -> Bool {
        guard let edge = pendingInEdge else { return false }
        pendingInEdge = nil
        timeoutItem?.cancel(); timeoutItem = nil
        let startDx: CGFloat = (edge == .left) ? -width : width
        view.transform = CGAffineTransform(translationX: startDx, y: 0)
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut], animations: {
            view.transform = .identity
        })
        return true
    }
}
```

- [ ] **Step 2: Verify by reading (no build)** — confirm: `slideOut` translates by ±width per edge; `beginPending` arms a cancelable timeout that only fires if still pending; `consumePendingSlideIn` starts off-screen at the pending edge and animates to `.identity`, clearing state; `@MainActor` on the class (UIView + DispatchQueue.main). Grep: `grep -n "slideOut\|beginPending\|consumePendingSlideIn\|pendingInEdge" App/WindowTransition.swift`.

- [ ] **Step 3: Commit**

```bash
git add App/WindowTransition.swift
git commit -m "feat(terminal): WindowTransition UIKit animator (slide-out/in + pending timeout)"
```

---

## Task 3: `paneContentView` wrapper in ContainerView (App)

**Files:**
- Modify: `App/TmuxPaneContainer.swift` (`ContainerView`)

**Rationale:** panes are currently DIRECT subviews of `ContainerView`, repositioned by frame in `layoutSubviews`. To animate a whole window as one screen, panes (and their halos/dots) must live in a single `paneContentView` subview that we transform. This task introduces that wrapper WITHOUT any animation yet — a pure structural refactor that must leave rendering identical.

**Interfaces:**
- Produces: `ContainerView.paneContentView: UIView` (fills the container's bounds); panes + halos are added to it; `apply`/`layoutSubviews`/pane-rect frames are relative to it.
- Consumes: nothing new.

- [ ] **Step 1: Add the content view + route pane subviews into it** — in `ContainerView`:
  - Add a stored `let paneContentView = UIView()`; add it as a subview in `init` (or lazily on first `apply`), pinned to fill `bounds` (set its frame = `bounds` in `layoutSubviews` BEFORE positioning panes, and on init).
  - Change every `addSubview(t)` for a pane (and halo/dot adds that belong to a pane's window content) to `paneContentView.addSubview(t)`.
  - Ensure `paneContentView.frame = bounds` is maintained (set at the top of `layoutSubviews`, before pane frames are computed), and `paneContentView.transform` is NOT reset by layout (only frame).
  - Pane frames (`view.frame = CGRect(x: rect.x, …)`) stay in `paneContentView`'s coordinate space — since `paneContentView` fills `bounds`, the rects are unchanged. No rect math changes.

- [ ] **Step 2: Verify by reading (no build)** — confirm: (a) every pane `addSubview` now targets `paneContentView`; (b) `paneContentView` fills bounds and is laid out before panes each pass; (c) halos/dots that decorate a pane are in `paneContentView` too (so they slide with it) — check `installHalo`/mouse-dot add sites and route them to the pane's superview (`paneContentView`) or keep them as subviews of the pane view itself (preferred: if halo/dot are added to the PANE view, they already ride along and need no change — verify which). (d) `paneTerminalViews`/`panes` bookkeeping still enumerates correctly. (e) `layoutSubviews`' `resolvedCell()`/`terminalGrid` client-size logic is unaffected (it uses `bounds`, not the content view).

- [ ] **Step 3: Commit**

```bash
git add App/TmuxPaneContainer.swift
git commit -m "refactor(terminal): wrap tmux panes in a paneContentView (enables window-switch transform)"
```

---

## Task 4: Wire slide-out + slide-in (App)

**Files:**
- Modify: `App/TmuxPaneContainer.swift`

**Interfaces:**
- Consumes: `windowSlideDirection(delta:)` (Task 1), `WindowTransition` (Task 2), `paneContentView` (Task 3).
- Produces: a `WindowTransition` owned by the `Coordinator`; slide-out on swipe-release; slide-in in `apply`; `ContainerView.previousActiveWindow` for the change-detect.

- [ ] **Step 1: Own a `WindowTransition`** — add `let windowTransition = WindowTransition()` to the `Coordinator` (or `ContainerView`; the Coordinator is reachable from both the gesture wiring and `apply`, so put it on the Coordinator and let `ContainerView` reach it via `coordinator?.windowTransition`).

- [ ] **Step 2: Slide-out at swipe release** — in the gesture `callbacks` `onSwitchWindow` closure (~line 272), before calling `self?.onSwitchWindow(delta)`:

```swift
                        onSwitchWindow:    { [weak self] delta in
                            DebugLog.shared.log(.lifecycle, "user-action: window-switch delta=\(delta)")
                            if let self, let dir = windowSlideDirection(delta: delta),
                               let content = self.containerView?.paneContentView {
                                let w = content.bounds.width
                                self.windowTransition.slideOut(dir.out, view: content, width: w)
                                self.windowTransition.beginPending(inEdge: dir.in, timeout: 1.5) { [weak content] in
                                    content?.transform = .identity   // stuck switch: snap back
                                }
                                DebugLog.shared.log(.gesture, "window-switch anim: out=\(dir.out) in=\(dir.in) delta=\(delta)")
                            }
                            self?.onSwitchWindow(delta)
                        },
```

  (`containerView` = the Coordinator's reference to its `ContainerView`; if the Coordinator does not already hold one, add a `weak var containerView: ContainerView?` set in `makeUIView`. Confirm/introduce this handle.)

- [ ] **Step 3: Slide-in in `apply`** — in `ContainerView.apply(state:)`, add a `previousActiveWindow: WindowID?` stored field. After the pane rebuild completes (end of `apply`), if the active window changed AND a slide-in is pending, run it:

```swift
            // Window-switch slide-in: after rebuilding the new window's panes, if the active
            // window changed and a transition is pending, slide the content in from the pending
            // edge (design 2026-07-17). Runs after panes are positioned so it animates the
            // final layout.
            if state.activeWindow != previousActiveWindow {
                coordinator?.windowTransition.consumePendingSlideIn(view: paneContentView, width: bounds.width)
            }
            previousActiveWindow = state.activeWindow
```

  Place this at the END of `apply` (after the pane create/position loop), and initialize `previousActiveWindow` to nil. NOTE: `apply` early-returns when the render signature is unchanged (`guard sig != lastRenderSignature`) or when there is no active window — in those cases `previousActiveWindow` is not updated and no slide-in runs, which is correct (a window switch always changes the signature).

- [ ] **Step 4: Verify by reading (no build)** — confirm: (a) slide-out reads `paneContentView.bounds.width` and fires before `onSwitchWindow`; (b) `beginPending` timeout resets the transform; (c) `apply`'s slide-in only runs on an active-window change with a pending transition, and updates `previousActiveWindow`; (d) the `containerView` handle on the Coordinator is set in `makeUIView` and used in the closure; (e) no retain cycle (weak self/content). Grep: `grep -n "windowTransition\|paneContentView\|previousActiveWindow\|slideOut\|consumePendingSlideIn" App/TmuxPaneContainer.swift`.

- [ ] **Step 5: Commit**

```bash
git add App/TmuxPaneContainer.swift
git commit -m "feat(terminal): animate window switch — slide out on release, slide new window in on apply"
```

---

## Task 5: Retest note (docs)

**Files:**
- Modify: `TODO.md`

- [ ] **Step 1: Add the retest procedure** — add under the alt-scroll / gesture section:

```markdown
### Window-switch animation retest
Swipe horizontally between tmux windows (need >1 window):
- EXPECT: on release the current window slides OUT in the swipe direction immediately, then
  the new window slides IN from the opposite side when tmux delivers it (brief empty gap on a
  slow link is acceptable). Rightward swipe (previous window): current exits right, new enters
  from left. Leftward (next): mirror.
- Confirm the tab strip does NOT slide (only the pane content).
- Slow/failed switch: content must NOT stick off-screen — the 1.5s timeout snaps it back.
- Log check (Gesture): `window-switch anim: out=… in=… delta=…` on release.
```

- [ ] **Step 2: Commit**

```bash
git add TODO.md
git commit -m "docs(todo): window-switch animation retest procedure"
```

---

## Self-Review

**Spec coverage:**
- §1 trigger/direction/sequence → Task 1 (direction) + Task 4 (wiring). ✓
- §2 `WindowTransition` helper + slide-out/in sites + `paneContentView` + timeout → Tasks 2, 3, 4. ✓
- §3 `windowSlideDirection` + `SlideEdge` → Task 1. ✓
- Testing (direction EP/BVA; App via device) → Task 1 tests + device retest note (Task 5). ✓
- Non-goals (no finger-track, no tab-strip anim, no mechanism change) → respected: tab strip is a sibling (untouched); only `paneContentView` transforms; `select-window`/delta unchanged.

**Placeholder scan:** none. Task 3 Step 2(c) asks the implementer to VERIFY where halos/dots are added (pane-view subview vs container) and route accordingly — that is a real verify-in-code instruction with the decision rule stated (prefer halo/dot as subviews of the pane view so they ride along), not a placeholder.

**Type consistency:**
- `windowSlideDirection(delta:) -> (out: SlideEdge, in: SlideEdge)?` — defined Task 1, consumed Task 4 Step 2. ✓
- `WindowTransition` methods (`slideOut`/`beginPending`/`consumePendingSlideIn`/`pendingInEdge`) — defined Task 2, called Task 4 Steps 2-3 with matching signatures. ✓
- `paneContentView` — introduced Task 3, consumed Task 4. ✓
- `previousActiveWindow: WindowID?` — introduced + used in Task 4 Step 3. ✓

**Risk called out:** Task 3 (`paneContentView` wrapper) is the highest-risk step — it re-parents pane subviews and must leave rendering pixel-identical (frames, client-size, halos). It is deliberately a SEPARATE task with no animation, so the whole-branch review + device pass can confirm rendering is unchanged before the animation rides on it. If the wrapper regresses layout, that is isolated to Task 3.

Plan complete.
