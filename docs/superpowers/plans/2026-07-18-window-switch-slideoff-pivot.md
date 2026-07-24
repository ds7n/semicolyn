<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Window-switch Slide-off + Gap-dim Pivot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pivot the window-switch transition: the CURRENT window slides off with the finger over a darkening gap (no live neighbor reveal), and the pre-warmed new window is drawn only on commit at its final full-size frame.

**Architecture:** A small pure Kit unit (`GapDim`) holds the dim opacity ramp + gradient-direction logic (Linux-tested). The App tier removes the live neighbor-reveal from `updateSwitchDrag`, adds an always-present `gapDimView` overlay behind `paneContentView` (fixing the never-rendered seam-dim), and relocates the snapshot render from during-drag to commit-only (fixing the zoom-mismatch). All three existing Kit units (`DragAxisLock`, `WindowDragModel`, `SwitchCommitDecision`) and `WindowSnapshotStore` are untouched.

**Tech Stack:** Swift 6 (strict concurrency, `Sendable`), XCTest (Kit, Docker `semicolyn-dev`), UIKit + SwiftTerm (App tier, macOS-CI / device only), tmux `-CC` control mode.

**Spec:** `docs/superpowers/specs/2026-07-18-window-switch-slideoff-pivot-design.md`

## Global Constraints

- **Two tiers:** `Sources/SemicolynKit/` = pure logic, Linux-tested, Swift 6 strict-concurrency, `Sendable`, NO `import UIKit`/`SwiftUI`/`CryptoKit`. `App/` = Apple-only, macOS-CI-verified, does NOT compile on Linux / is invisible to `swift test`.
- **Every source file carries the two-line SPDX header** (`// SPDX-FileCopyrightText: 2026 True Positive LLC` + `// SPDX-License-Identifier: GPL-3.0-only`; Markdown uses `<!-- -->`).
- **Tests must be real** (`docs/superpowers/specs/2026-06-18-testing-standards-design.md`): EP + boundary values, assert observable values (no tautologies), a negative asserts the SPECIFIC outcome.
- **Kit build/test** (host has NO Swift toolchain): `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <TestClass>`.
- **RECURRING macOS-CI TRAP:** the pane-container `Coordinator` is a NONISOLATED NSObject; any `@MainActor`/UIKit/`DebugLog` access from it must be inside `MainActor.assumeIsolated {}`. Every existing switch method here already wraps its body that way (`beginSwitchReveal`, `updateSwitchDrag`, `commitSwitchDrag`, `cancelSwitchDrag`, `failPendingSwitch`, `completePendingSwitchIfNeeded`). New code MUST match.
- **App tier does not compile on Linux** — the macOS CI job is the only compile signal (use `workflow_dispatch` if the webhook is stuck: `gh workflow run CI --ref <branch>`).
- **No em-dashes** in any generated output.
- **Direction convention (unchanged):** rightward drag (dx>0) -> `.previous` (-1); the window slides RIGHT, the gap opens on the LEFT. Leftward -> `.next` (+1); gap opens on the RIGHT.
- **Branch:** work continues on `feat/finger-drag-window-transition` (already rebased on main, CI-green, PR #103). These commits stack on top.

---

## File Structure

**Kit (new, pure, tested):**
- `Sources/SemicolynKit/Terminal/GapDim.swift` - dim opacity ramp + gradient endpoints per drag direction.

**Kit tests (new):**
- `Tests/SemicolynKitTests/GapDimTests.swift`

**App (modified):**
- `App/TmuxPaneContainer.swift` - remove live neighbor reveal from `updateSwitchDrag`; add `gapDimView` overlay (on `ContainerView`, behind `paneContentView`, pinned in `layoutSubviews`); drive its alpha/gradient from `GapDim`; relocate the snapshot render to `commitSwitchDrag` (final full-size frame); replace `installSeamDim`/`updateSeamDim`/`clearSeamDim`/`seamDim` with the gap-dim equivalents.

**Unchanged (verify, don't touch):** `DragAxisLock.swift`, `WindowDragModel.swift`, `SwitchCommitDecision.swift`, `WindowSnapshotStore.swift`, `TmuxRuntime.swift` capture routing, `TerminalGestureController.swift` (the gesture callbacks stay identical - only the coordinator's handling changes).

---

## Task 1: `GapDim` pure unit (Kit)

**Files:**
- Create: `Sources/SemicolynKit/Terminal/GapDim.swift`
- Test: `Tests/SemicolynKitTests/GapDimTests.swift`

**Interfaces:**
- Consumes: `ExposedNeighbor` (from `WindowDragModel.swift`).
- Produces:
  - `public struct GapDim: Sendable`
    - `public static let maxOpacity: Double` (0.5)
    - `public static func opacity(offset: Double, width: Double) -> Double` - clamped ramp `min(abs(offset)/width, 1) * maxOpacity`; 0 when width<=0.
    - `public struct Endpoints: Equatable, Sendable { public let startX: Double; public let endX: Double }`
    - `public static func endpoints(exposed: ExposedNeighbor) -> Endpoints` - gradient x-endpoints (y fixed 0.5 at the App layer). Dark end nearest the departing window.

- [ ] **Step 1: Write the failing test**

Create `Tests/SemicolynKitTests/GapDimTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Gap-dim ramp (opacity grows with drag progress, clamped) + gradient direction
/// (dark end nearest the departing window, mirrored by drag direction).
final class GapDimTests: XCTestCase {
    private let width = 400.0

    // EP: no drag -> fully transparent.
    func testZeroDragIsTransparent() {
        XCTAssertEqual(GapDim.opacity(offset: 0, width: width), 0, accuracy: 0.0001)
    }

    // EP: half-width drag -> half of maxOpacity.
    func testHalfDragIsHalfMax() {
        XCTAssertEqual(GapDim.opacity(offset: 200, width: width),
                       0.5 * GapDim.maxOpacity, accuracy: 0.0001)
    }

    // BVA: at full width -> exactly maxOpacity.
    func testAtWidthIsMax() {
        XCTAssertEqual(GapDim.opacity(offset: width, width: width),
                       GapDim.maxOpacity, accuracy: 0.0001)
    }

    // BVA: past full width -> clamped at maxOpacity (does not exceed).
    func testPastWidthClampsToMax() {
        XCTAssertEqual(GapDim.opacity(offset: width * 2, width: width),
                       GapDim.maxOpacity, accuracy: 0.0001)
    }

    // Sign-agnostic: a leftward (negative) drag ramps the same as rightward.
    func testNegativeOffsetRampsSame() {
        XCTAssertEqual(GapDim.opacity(offset: -200, width: width),
                       GapDim.opacity(offset: 200, width: width), accuracy: 0.0001)
    }

    // Guard: width <= 0 -> 0 (no divide-by-zero / no dim).
    func testZeroWidthIsTransparent() {
        XCTAssertEqual(GapDim.opacity(offset: 100, width: 0), 0, accuracy: 0.0001)
    }

    // Direction: previous (rightward drag, gap on the LEFT, departing window on the
    // right) and next produce MIRRORED endpoints.
    func testEndpointsMirrorByDirection() {
        let prev = GapDim.endpoints(exposed: .previous)
        let next = GapDim.endpoints(exposed: .next)
        XCTAssertEqual(prev.startX, next.endX, accuracy: 0.0001)
        XCTAssertEqual(prev.endX, next.startX, accuracy: 0.0001)
        // And they are not degenerate (start != end).
        XCTAssertNotEqual(prev.startX, prev.endX)
    }

    // Direction: .none -> a defined default with no gradient span (start == end),
    // so no dim direction is implied when there is no horizontal drag.
    func testNoneHasNoSpan() {
        let none = GapDim.endpoints(exposed: .none)
        XCTAssertEqual(none.startX, none.endX, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter GapDimTests`
Expected: FAIL to compile ("cannot find 'GapDim' in scope").

- [ ] **Step 3: Write the implementation**

Create `Sources/SemicolynKit/Terminal/GapDim.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Pure geometry for the window-switch gap dimming. As the CURRENT window slides off,
/// the exposed gap behind it darkens with drag progress; the gradient is darkest at the
/// edge nearest the departing window and fades across the gap. This unit owns the opacity
/// ramp and the gradient x-endpoints (direction); the App layer applies them to a
/// `CAGradientLayer` / overlay `UIView`.
public struct GapDim: Sendable {
    /// Peak dim (fraction) reached at a full-width drag. 0.5 = a clear but not opaque grey.
    public static let maxOpacity: Double = 0.5

    /// Overlay opacity for a drag of `offset` over a pane of `width`: linear ramp from 0
    /// (at rest) to `maxOpacity` (at a full-width drag), clamped past width. Sign-agnostic
    /// (uses `abs`). `width <= 0` -> 0 (no dim, no divide-by-zero).
    public static func opacity(offset: Double, width: Double) -> Double {
        guard width > 0 else { return 0 }
        return min(abs(offset) / width, 1) * maxOpacity
    }

    /// Gradient x-endpoints in unit coordinates (0 = left edge, 1 = right edge; y is fixed
    /// at 0.5 by the App layer). `startX` is the DARK end (nearest the departing window),
    /// `endX` the clear end.
    public struct Endpoints: Equatable, Sendable {
        public let startX: Double
        public let endX: Double
        public init(startX: Double, endX: Double) { self.startX = startX; self.endX = endX }
    }

    /// Endpoints for the drag direction. `.previous` (rightward drag): the window slides
    /// RIGHT, the gap opens on the LEFT, and the departing window is to the gap's RIGHT ->
    /// dark on the right (startX = 1), fading left (endX = 0). `.next` mirrors it. `.none`
    /// -> a zero-span default (no direction implied).
    public static func endpoints(exposed: ExposedNeighbor) -> Endpoints {
        switch exposed {
        case .previous: return Endpoints(startX: 1.0, endX: 0.0)
        case .next:     return Endpoints(startX: 0.0, endX: 1.0)
        case .none:     return Endpoints(startX: 0.5, endX: 0.5)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter GapDimTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Full Kit suite (regression)**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS (all existing + the 8 new GapDim tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/SemicolynKit/Terminal/GapDim.swift Tests/SemicolynKitTests/GapDimTests.swift
git commit -m "feat(terminal): GapDim pure unit (dim opacity ramp + gradient direction)"
```

---

## Task 2: `gapDimView` overlay on `ContainerView` (App)

**Why:** The old seam-dim was attached to the neighbor-snapshot host (often absent), so it never rendered. Install a dedicated overlay `UIView` that is ALWAYS in the hierarchy, behind `paneContentView`, so the sliding window reveals it and its gradient always renders.

**Files:**
- Modify: `App/TmuxPaneContainer.swift` (the `ContainerView` class)
- Test: none (App tier); Kit stays green.

**Interfaces:**
- Consumes: nothing new (UIKit).
- Produces (on `ContainerView`):
  - `let gapDimView = UIView()` + a `CAGradientLayer` sublayer, installed BEHIND `paneContentView`.
  - `func gapDimLayer() -> CAGradientLayer` - accessor the Coordinator uses to set colors/endpoints.
  - Frame pinned to `bounds` in `layoutSubviews` (both the view and its gradient sublayer).

- [ ] **Step 1: Add the overlay view + gradient to `ContainerView`**

In `App/TmuxPaneContainer.swift`, next to `let paneContentView = UIView()` (around line 732), add:

```swift
        /// Dim overlay revealed in the gap as `paneContentView` slides off during a window
        /// switch. Installed BEHIND `paneContentView` (so the sliding window uncovers it) and
        /// pinned to `bounds`. Always in the hierarchy - unlike the prior seam-dim (attached
        /// to a neighbor host that often did not exist), so its gradient always renders.
        /// Transparent at rest; the Coordinator ramps its `.alpha` with drag progress
        /// (`GapDim.opacity`) and sets the gradient direction (`GapDim.endpoints`).
        let gapDimView = UIView()
        private let gapDimGradient = CAGradientLayer()
        private var gapDimInstalled = false

        /// Install `gapDimView` (with its gradient) as the FIRST subview so it sits behind
        /// `paneContentView`. Idempotent. The gradient is a black->clear horizontal fade whose
        /// direction the Coordinator sets per drag; the view starts fully transparent.
        private func ensureGapDimInstalled() {
            guard !gapDimInstalled else { return }
            gapDimView.frame = bounds
            gapDimView.isUserInteractionEnabled = false
            gapDimView.alpha = 0
            gapDimGradient.frame = gapDimView.bounds
            gapDimGradient.colors = [UIColor.black.cgColor, UIColor.clear.cgColor]
            gapDimView.layer.addSublayer(gapDimGradient)
            insertSubview(gapDimView, at: 0)   // behind paneContentView
            gapDimInstalled = true
        }

        /// The gap-dim gradient layer, for the Coordinator to set start/end points + keep the
        /// view in the hierarchy. Ensures installation on first access.
        func gapDimLayer() -> CAGradientLayer {
            ensureGapDimInstalled()
            return gapDimGradient
        }

        /// The gap-dim overlay view, for the Coordinator to ramp `.alpha`.
        func gapDimOverlay() -> UIView {
            ensureGapDimInstalled()
            return gapDimView
        }
```

- [ ] **Step 2: Pin the overlay in `layoutSubviews`**

In `ContainerView.layoutSubviews()` (around line 771), right after the existing
`ensurePaneContentViewInstalled(); paneContentView.frame = bounds` lines, add:

```swift
            ensureGapDimInstalled()
            gapDimView.frame = bounds
            gapDimGradient.frame = gapDimView.bounds
```

> **Verify:** confirm the exact existing lines in `layoutSubviews` that pin `paneContentView`
> (they read `ensurePaneContentViewInstalled()` then `paneContentView.frame = bounds`). Insert
> the three gap-dim lines immediately after, so the overlay is pinned on every layout pass
> (rotation / keyboard / font change). `CALayer` frame assignment inside `layoutSubviews` is
> standard; no `CATransaction` needed (implicit animations there are already disabled by UIKit's
> layout pass).

- [ ] **Step 3: Verify Kit still builds/tests**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS (App change invisible to Linux; confirms nothing Kit-side broke).

- [ ] **Step 4: Commit**

```bash
git add App/TmuxPaneContainer.swift
git commit -m "feat(terminal): gapDimView overlay behind paneContentView (always-present dim)"
```

---

## Task 3: Remove live reveal from `updateSwitchDrag`; drive gap-dim (App)

**Why:** The drag should slide the current window off with a darkening gap and NOT show the neighbor. Strip the neighbor-host reveal; drive `gapDimView` from `GapDim` instead.

**Files:**
- Modify: `App/TmuxPaneContainer.swift` (the `Coordinator`)
- Test: none (App tier); Kit stays green.

**Interfaces:**
- Consumes: `GapDim` (Task 1), `gapDimLayer()`/`gapDimOverlay()` (Task 2), `ExposedNeighbor`.
- Produces: a slimmed `updateSwitchDrag(offset:exposed:)` + a private `updateGapDim(exposed:offset:)`; removal of `installSeamDim`/`updateSeamDim`/`clearSeamDim`/`seamDim`; a new `clearGapDim()`.

- [ ] **Step 1: Replace `updateSwitchDrag`'s body**

Replace the entire `updateSwitchDrag(offset:exposed:)` method (currently lines ~540-576, the
version that resolves the neighbor, adds `host`, positions it `base + offset`, and calls
`updateSeamDim(on: host, ...)`) with:

```swift
        /// Live `.changed`: slide `paneContentView` with the finger and darken the exposed
        /// gap behind it. NO neighbor window is shown during the drag (pivot 2026-07-18:
        /// prep-don't-reveal); the pre-warmed snapshot is drawn only on commit. Wrapped in
        /// `assumeIsolated` for the same reason as `beginSwitchReveal`.
        func updateSwitchDrag(offset: Double, exposed: ExposedNeighbor) {
            MainActor.assumeIsolated {
                guard let content = containerView?.paneContentView else { return }
                content.transform = CGAffineTransform(translationX: CGFloat(offset), y: 0)
                updateGapDim(exposed: exposed, offset: offset)
            }
        }

        /// Ramp the gap-dim overlay with drag progress (`GapDim.opacity`) and set its gradient
        /// direction (`GapDim.endpoints`) so the dark end is nearest the departing window.
        /// Assumes the caller is already on the main actor (called from within
        /// `updateSwitchDrag`'s `assumeIsolated` block).
        private func updateGapDim(exposed: ExposedNeighbor, offset: Double) {
            guard let container = containerView else { return }
            let w = Double(container.bounds.width)
            let overlay = container.gapDimOverlay()
            let gradient = container.gapDimLayer()
            let ep = GapDim.endpoints(exposed: exposed)
            gradient.startPoint = CGPoint(x: ep.startX, y: 0.5)
            gradient.endPoint = CGPoint(x: ep.endX, y: 0.5)
            overlay.alpha = CGFloat(GapDim.opacity(offset: offset, width: w))
        }

        /// Fade the gap-dim overlay back to transparent (spring-back, commit-handoff, timeout).
        /// Main-actor caller (invoked from within existing `assumeIsolated` blocks).
        private func clearGapDim() {
            containerView?.gapDimOverlay().alpha = 0
        }
```

- [ ] **Step 2: Delete the old seam-dim helpers + state**

Delete these four now-unused members from the `Coordinator` (they referenced the removed
neighbor host):
- `private var seamDim: CAGradientLayer?` (~line 163)
- `private func installSeamDim(on:exposed:) -> CAGradientLayer` (~lines 583-595)
- `private func updateSeamDim(on:exposed:progress:)` (~lines 600-607)
- `private func clearSeamDim()` (~lines 610-613)

Then replace every remaining `clearSeamDim()` CALL with `clearGapDim()` (there are calls in
`cancelSwitchDrag`, `failPendingSwitch`, and `completePendingSwitchIfNeeded`). Confirm none remain:

Run: `grep -n "seamDim\|clearSeamDim\|installSeamDim\|updateSeamDim" App/TmuxPaneContainer.swift`
Expected: no matches.

- [ ] **Step 3: Verify Kit still builds/tests**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add App/TmuxPaneContainer.swift
git commit -m "feat(terminal): slide-off drag + gap-dim (remove live neighbor reveal)"
```

---

## Task 4: Relocate snapshot render to commit (final full-size frame) (App)

**Why:** The zoom-mismatch came from drawing the snapshot under a partial drag transform. Draw it ONLY at commit, at the pane's final frame, so it always matches. During the drag no snapshot exists; `revealedSnapshot` is now set for the first time inside `commitSwitchDrag`.

**Files:**
- Modify: `App/TmuxPaneContainer.swift` (the `Coordinator`)
- Test: none (App tier); Kit stays green.

**Interfaces:**
- Consumes: `WindowSnapshotStore.snapshotView(for:)` + `layout(window:in:bounds:cellWidth:cellHeight:)`, `neighborWindow(of:delta:)`, `windowSlideDirection(delta:)`, `resolvedCellPublic()`.
- Produces: `commitSwitchDrag(delta:)` that renders the snapshot at the final frame; `cancelSwitchDrag` no longer manipulates a during-drag host (there is none).

- [ ] **Step 1: Rewrite `commitSwitchDrag` to draw the snapshot at commit**

Replace the body of `commitSwitchDrag(delta:)` (currently lines ~619-643) with:

```swift
        /// Release past threshold: finish sliding the current window off, issue the tmux
        /// switch, and draw the PRE-WARMED snapshot of the new window at its FINAL full-size
        /// frame (identity transform) so it covers the pane with no blank flash and no zoom
        /// mismatch (the snapshot is never shown under a partial drag transform). The live
        /// panes swap in UNDER it in `apply(state:)`; a 1.5s timeout is the safety net.
        func commitSwitchDrag(delta: Int) {
            MainActor.assumeIsolated {
                guard let content = containerView?.paneContentView,
                      let container = containerView,
                      let vm, let state = vm.tmuxState,
                      let active = state.activeWindow,
                      let dir = windowSlideDirection(delta: delta) else { cancelSwitchDrag(); return }
                let w = container.bounds.width
                let outX: CGFloat = (dir.out == .left) ? -w : w
                // Finish the current window's slide-off; the gap-dim holds at full.
                UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut], animations: {
                    content.transform = CGAffineTransform(translationX: outX, y: 0)
                })
                // Draw the pre-warmed snapshot of the target window at its FINAL frame (only
                // place a snapshot is shown; full-size, so no zoom mismatch). If the capture
                // has not landed yet, hold the gap grey until tmux delivers the live window.
                if let neighbor = vm.neighborWindow(of: active, delta: delta),
                   let host = vm.snapshotStore?.snapshotView(for: neighbor) {
                    container.addSubview(host)                       // above gapDim + slid-off content
                    host.transform = .identity
                    let cell = container.resolvedCellPublic()
                    vm.snapshotStore?.layout(window: neighbor, in: state, bounds: container.bounds,
                                             cellWidth: cell.w, cellHeight: cell.h)
                    revealedSnapshot = (host, neighbor)
                    pendingSwitchWindow = neighbor
                } else {
                    // No snapshot yet: hold grey (gapDim stays); the live window draws on delivery.
                    pendingSwitchWindow = vm.neighborWindow(of: active, delta: delta)
                }
                onSwitchWindow(delta)   // tmux select-window
                // Cancel any prior in-flight timeout before arming a new one (rapid re-commit
                // race, Task 7 review 2026-07-18).
                pendingSwitchTimeout?.cancel()
                let timeout = DispatchWorkItem { [weak self] in self?.failPendingSwitch() }
                pendingSwitchTimeout = timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: timeout)
                DebugLog.shared.log(.gesture,
                    "switch commit delta=\(delta) snapshot=\(revealedSnapshot != nil) -> pending @\(pendingSwitchWindow.map { "\($0.raw)" } ?? "nil")")
            }
        }
```

> **Verify:** confirm `WindowSnapshotStore.layout(window:in:bounds:cellWidth:cellHeight:)` and
> `snapshotView(for:)` signatures match (they were built in the shipped feature - grep them in
> `App/WindowSnapshotStore.swift`). Confirm `resolvedCellPublic()` returns `(w:Double,h:Double)`
> (it does, line ~870). Confirm `vm.neighborWindow(of:delta:)` exists (added in the shipped
> feature). If `state`/`active` are already in scope differently, adapt.

- [ ] **Step 2: Simplify `cancelSwitchDrag` (no during-drag host to move)**

Replace the body of `cancelSwitchDrag()` (currently lines ~648-665) with:

```swift
        /// Release short: spring the current window back to identity and clear the gap-dim.
        /// No during-drag snapshot exists to move (pivot: the snapshot is drawn only on
        /// commit). Wrapped in `assumeIsolated` for the same reason as `beginSwitchReveal`.
        func cancelSwitchDrag() {
            MainActor.assumeIsolated {
                clearPendingSwitch()
                guard let content = containerView?.paneContentView else { return }
                UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut], animations: {
                    content.transform = .identity
                }, completion: { [weak self] _ in
                    // Drop any snapshot that a just-committed switch left (defensive; normally nil).
                    self?.revealedSnapshot?.view.removeFromSuperview()
                    self?.revealedSnapshot = nil
                })
                clearGapDim()
                DebugLog.shared.log(.gesture, "switch cancel -> spring back")
            }
        }
```

- [ ] **Step 3: Confirm `failPendingSwitch` + `completePendingSwitchIfNeeded` clear the gap-dim**

These already call `clearSeamDim()` (now `clearGapDim()` after Task 3). Verify each still:
resets `paneContentView.transform = .identity`, removes `revealedSnapshot`, and calls
`clearGapDim()`. No structural change needed beyond the Task 3 rename. Confirm:

Run: `grep -n "clearGapDim()" App/TmuxPaneContainer.swift`
Expected: calls in `updateSwitchDrag` path (none - it ramps, not clears), `cancelSwitchDrag`,
`failPendingSwitch`, `completePendingSwitchIfNeeded` (3 clear-calls total).

- [ ] **Step 4: Verify Kit still builds/tests**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add App/TmuxPaneContainer.swift
git commit -m "feat(terminal): draw pre-warmed snapshot at commit (final frame, fixes zoom)"
```

---

## Task 5: macOS CI + device retest

**Files:** none (process task).

- [ ] **Step 1: Push + trigger CI**

```bash
git push github feat/finger-drag-window-transition
gh workflow run CI --repo ds7n/semicolyn --ref feat/finger-drag-window-transition   # webhook is stuck; dispatch manually
```

- [ ] **Step 2: Watch macOS job to green**

Run: `gh run list --repo ds7n/semicolyn --branch feat/finger-drag-window-transition --limit 1`, then
`gh run view --job=<macos-job-id> --repo ds7n/semicolyn` until the `macos` job is ✓.
Most likely failure classes (fix inline, re-push, re-dispatch):
- `MainActor.assumeIsolated` missing on a new Coordinator method body -> wrap it.
- A `WindowSnapshotStore` / `resolvedCellPublic` / `neighborWindow` member-name mismatch -> match the real signature.

- [ ] **Step 3: Device retest checklist**

Enable Settings > Diagnostics > Gesture logging, then on device verify:
1. Horizontal drag: the CURRENT window slides off tracking the finger; NO new window is shown in the gap.
2. The gap behind the sliding window DARKENS progressively (grey deepens with drag distance) and is darkest nearest the departing window's edge. (`switch commit ... snapshot=` log on release.)
3. Drag past ~40% + release: current window finishes sliding off, the new window appears immediately and correctly sized (no zoom mismatch), no blank flash. (`switch commit` -> `switch handoff complete`.)
4. Short drag + release: springs back, gap-dim clears, no switch. (`switch cancel`.)
5. Fast short flick: commits.
6. Vertical drag still scrolls (normal) / wheel-scrolls Claude (alt-screen).
7. Horizontal drag on a Claude/alt-screen pane also switches.
8. Edge window (drag to wrap): commits + wraps.
9. Reverse direction mid-drag: the gap side (and gradient direction) flips; alpha follows drag distance.
10. Single-window session: no switch, no gap-dim.

- [ ] **Step 4: Squash-merge PR #103 once CI green + device feel confirmed**

Per repo convention. Then update the resume doc + memory.

---

## Self-Review

**Spec coverage:**
- Drag slides current window off, no reveal -> Task 3 (slimmed `updateSwitchDrag`). ✓
- Gap-dim gradient in the exposed gap, darkest near departing window, ramps with distance -> `GapDim` (Task 1) + `gapDimView` overlay (Task 2) + `updateGapDim` (Task 3). ✓
- Overlay always present (fixes never-rendered) -> `gapDimView` installed behind `paneContentView`, pinned in `layoutSubviews` (Task 2). ✓
- Snapshot only at commit, final full-size frame (fixes zoom) -> Task 4 `commitSwitchDrag`. ✓
- Snapshot-not-ready -> hold grey -> Task 4 else-branch. ✓
- 1.5s timeout + rapid-recommit guard + `clearPendingSwitch` retained -> Task 4 (timeout) + unchanged `clearPendingSwitch`. ✓
- Kept Kit units + `WindowSnapshotStore` + edge-wrap + mode coverage -> untouched (stated in File Structure). ✓
- Spring-back clears dim -> Task 4 `cancelSwitchDrag`. ✓

**Placeholder scan:** none; every code step is complete. The three "Verify" notes point at real signatures to confirm against the current file (grounded checks, not placeholders).

**Type consistency:** `GapDim.opacity`/`endpoints`/`Endpoints`/`maxOpacity` used consistently across Task 1 (producer) and Task 3 (consumer). `gapDimOverlay()`/`gapDimLayer()` match between Task 2 (producer) and Task 3 (consumer). `clearGapDim()` defined in Task 3 and called in Task 3 + Task 4. `revealedSnapshot`/`pendingSwitchWindow`/`pendingSwitchTimeout` names match the existing coordinator state (unchanged).
