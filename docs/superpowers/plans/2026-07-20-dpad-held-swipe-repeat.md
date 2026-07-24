<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# d-pad Held-Swipe Arrow Repeat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Holding a swipe on the keybar d-pad auto-repeats the arrow key, iOS-style: distance selects direction, held-time drives the repeat rate.

**Architecture:** A pure, Linux-tested Kit decider (`ArrowRepeat.interval(heldFor:)` + `dominantArrow(dx:dy:)`) computes the iOS-standard timing curve and dominant-axis direction. The App-tier `PadView` gets a `@State` repeating `Timer` that samples held-time, re-arms at the decider's interval, and fires the arrow for the current thumb direction. The first arrow (single-fire on 16pt crossing) is unchanged; repeat is additive.

**Tech Stack:** Swift 6 (SemicolynKit, strict-concurrency, no UIKit/SwiftUI in Kit), XCTest (Linux), SwiftUI (App tier, macOS-CI-only).

## Global Constraints

- Every source file carries the SPDX header: `// SPDX-FileCopyrightText: 2026 True Positive LLC` then `// SPDX-License-Identifier: GPL-3.0-only`.
- Kit code (`Sources/SemicolynKit/`) is Swift 6 strict-concurrency, `Sendable`, **no `import UIKit`/`SwiftUI`/`CryptoKit`**. Only `import Foundation`.
- Kit tests run via: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <Suite>` (there is NO Swift toolchain on the host; use the `semicolyn-dev` container).
- App-tier code (`App/`) does NOT compile on Linux and is invisible to `swift test`; it is validated only by the macOS CI job.
- Conventional commits (`feat:`/`fix:`/`test:`). Stage files **explicitly** (never `git add -A` — `extern/` submodules must stay untracked).
- No em-dashes in any output.
- Timing constants (verbatim from spec): `initialDelay = 0.40`, `startInterval = 0.25`, `minInterval = 0.06`, `rampDuration = 1.20` (all `TimeInterval`).

---

### Task 1: `ArrowRepeat` Kit decider (timing curve + dominant axis)

**Files:**
- Create: `Sources/SemicolynKit/Keybar/ArrowRepeat.swift`
- Test: `Tests/SemicolynKitTests/ArrowRepeatTests.swift`

**Interfaces:**
- Consumes: `ArrowDirection` (existing, `Sources/SemicolynKit/Keybar/KeyEncoding.swift`: `enum ArrowDirection: String { case up, down, left, right }`).
- Produces:
  - `ArrowRepeat.interval(heldFor: TimeInterval) -> TimeInterval?` (static)
  - `ArrowRepeat.initialDelay / startInterval / minInterval / rampDuration` (static `TimeInterval` constants)
  - `dominantArrow(dx: Double, dy: Double) -> ArrowDirection` (free function)

- [ ] **Step 1: Write the failing tests**

Create `Tests/SemicolynKitTests/ArrowRepeatTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ArrowRepeatTests: XCTestCase {

    // MARK: interval(heldFor:) — iOS-style hold-to-repeat timing (BVA on the curve)

    func testNoRepeatAtStart() {
        XCTAssertNil(ArrowRepeat.interval(heldFor: 0))              // still in initial-delay window
    }
    func testNoRepeatJustUnderInitialDelay() {
        XCTAssertNil(ArrowRepeat.interval(heldFor: 0.40 - 0.001))   // just under boundary
    }
    func testStartIntervalAtInitialDelayBoundary() {
        let out = ArrowRepeat.interval(heldFor: 0.40)               // exactly at boundary
        XCTAssertNotNil(out)
        XCTAssertEqual(out!, 0.25, accuracy: 1e-9)                  // == startInterval
    }
    func testEasesToRampMidpoint() {
        // Linear ease start(0.25)->min(0.06) across rampDuration(1.20); midpoint = mean.
        let out = ArrowRepeat.interval(heldFor: 0.40 + 0.60)        // half the ramp
        XCTAssertNotNil(out)
        XCTAssertEqual(out!, (0.25 + 0.06) / 2, accuracy: 1e-9)     // 0.155
    }
    func testClampsToMinIntervalAtRampEnd() {
        let out = ArrowRepeat.interval(heldFor: 0.40 + 1.20)        // ramp end
        XCTAssertNotNil(out)
        XCTAssertEqual(out!, 0.06, accuracy: 1e-9)                  // == minInterval
    }
    func testClampsToMinIntervalPastRampEnd() {
        let out = ArrowRepeat.interval(heldFor: 0.40 + 1.20 + 1.0)  // well past ramp
        XCTAssertNotNil(out)
        XCTAssertEqual(out!, 0.06, accuracy: 1e-9)                  // clamped floor
    }

    // MARK: dominantArrow(dx:dy:) — equivalence partitions, one representative each

    func testDominantRight() { XCTAssertEqual(dominantArrow(dx: 10, dy: 0), .right) }
    func testDominantLeft()  { XCTAssertEqual(dominantArrow(dx: -10, dy: 0), .left) }
    func testDominantDown()  { XCTAssertEqual(dominantArrow(dx: 0, dy: 10), .down) }
    func testDominantUp()    { XCTAssertEqual(dominantArrow(dx: 0, dy: -10), .up) }
    func testDominantDiagonalHorizontalWins() {
        XCTAssertEqual(dominantArrow(dx: 10, dy: 4), .right)        // |dx| > |dy|
    }
    func testDominantDiagonalVerticalWins() {
        XCTAssertEqual(dominantArrow(dx: 4, dy: -10), .up)          // |dy| > |dx|
    }
    func testTieResolvesHorizontalPositive() {
        XCTAssertEqual(dominantArrow(dx: 5, dy: 5), .right)         // |dx| == |dy|, dx >= 0
    }
    func testTieResolvesHorizontalNegative() {
        XCTAssertEqual(dominantArrow(dx: -5, dy: 5), .left)         // |dx| == |dy|, dx < 0
    }
    func testZeroResolvesRight() {
        XCTAssertEqual(dominantArrow(dx: 0, dy: 0), .right)         // (0,0) tie -> horizontal +
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ArrowRepeatTests`
Expected: FAIL to compile with "cannot find 'ArrowRepeat' in scope" / "cannot find 'dominantArrow' in scope".

- [ ] **Step 3: Write the implementation**

Create `Sources/SemicolynKit/Keybar/ArrowRepeat.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// iOS-style key-repeat timing for a held d-pad swipe, as a function of how long the
/// swipe has been held (measured from the first fire at the 16pt crossing). Distance
/// selects direction (see `dominantArrow`); held-time drives the rate. Pure + testable,
/// mirroring the `ResizeDebounce` tested-seam pattern (no UIKit/SwiftUI).
public enum ArrowRepeat {
    /// After the first fire, wait this long before repeating begins.
    public static let initialDelay: TimeInterval  = 0.40
    /// The first repeat interval once repeating begins (slow).
    public static let startInterval: TimeInterval = 0.25
    /// The fastest repeat interval (clamp floor).
    public static let minInterval: TimeInterval   = 0.06
    /// Held-time over which the interval eases from `startInterval` down to `minInterval`.
    public static let rampDuration: TimeInterval  = 1.20

    /// The repeat interval for a swipe held `heldFor` seconds, or nil while still inside
    /// the initial-delay window (no repeat yet). Linear ease from `startInterval` down to
    /// `minInterval` across `rampDuration`, clamped at `minInterval` past the ramp.
    public static func interval(heldFor: TimeInterval) -> TimeInterval? {
        guard heldFor >= initialDelay else { return nil }
        let intoRamp = heldFor - initialDelay
        guard intoRamp < rampDuration else { return minInterval }
        let progress = intoRamp / rampDuration               // 0..<1 across the ramp
        return startInterval + (minInterval - startInterval) * progress
    }
}

/// The dominant-axis arrow for a drag translation. Ties (|dx| == |dy|, including 0,0)
/// resolve to the horizontal axis (`.right` when `dx >= 0`, else `.left`). Extracted from
/// `PadView` so direction selection is unit-tested.
public func dominantArrow(dx: Double, dy: Double) -> ArrowDirection {
    if abs(dx) >= abs(dy) {
        return dx >= 0 ? .right : .left
    }
    return dy >= 0 ? .down : .up
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ArrowRepeatTests`
Expected: PASS, 14 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Keybar/ArrowRepeat.swift \
        Tests/SemicolynKitTests/ArrowRepeatTests.swift
git commit -m "feat(keybar): ArrowRepeat decider (iOS hold-to-repeat curve + dominant axis)"
```

---

### Task 2: Wire held-swipe repeat into `PadView`

**Files:**
- Modify: `App/Keybar/KeybarSlotViews.swift:224-244` (the `PadView` struct)

**Interfaces:**
- Consumes: `ArrowRepeat.interval(heldFor:)`, `ArrowRepeat.initialDelay`, `dominantArrow(dx:dy:)` (Task 1); `vm.keybar.arrow(_ d: ArrowDirection)` (existing, `KeybarInputRouter.swift:34`); `DebugLog.shared.log(.keybar, ...)` (existing).
- Produces: nothing consumed by later tasks (terminal task).

> **Note:** This task is App-tier — it does NOT compile on Linux and is invisible to `swift test`. It is validated by the macOS CI job plus device retest. There is no local red/green test cycle; the "verify" step is the macOS CI build.

- [ ] **Step 1: Replace the `PadView` body with the held-repeat gesture**

In `App/Keybar/KeybarSlotViews.swift`, replace the entire `PadView` struct (currently lines 224-244) with:

```swift
/// Pad: SWIPE = arrow key in the swiped (dominant-axis) direction, and HOLDING the swipe
/// auto-repeats it iOS-style (distance picks direction, held-time drives the rate — see
/// SemicolynKit `ArrowRepeat`). No tap action: the pad is purely a directional control
/// (device 2026-07-20: tap used to zoom the active pane, so a press meant to send an arrow
/// zoomed a pane instead). Zoom lives on the long-press-pane gesture elsewhere.
struct PadView: View {
    let vm: ConnectionViewModel
    @Environment(\.theme) private var theme

    @State private var heldSince: Date?                 // set on the first crossing; nil = not held
    @State private var lastTranslation: CGSize = .zero  // latest dx/dy, updated every onChanged
    @State private var repeatTimer: Timer?

    var body: some View {
        SlotChrome(bg: Color(theme.keybar.slotBg)) {
            Image(systemName: "dpad").foregroundStyle(Color(theme.text.primary))
        }
        .gesture(
            DragGesture(minimumDistance: 16)
                .onChanged { g in
                    lastTranslation = g.translation           // always track the latest thumb pos
                    guard heldSince == nil else { return }     // already holding — timer drives it
                    fireArrow()                                // first fire on crossing 16pt
                    heldSince = Date()
                    DebugLog.shared.log(.keybar,
                        "keybar:dpad swipe dx=\(Int(g.translation.width)) dy=\(Int(g.translation.height)) -> arrow=\(dominantArrow(dx: g.translation.width, dy: g.translation.height))")
                    DebugLog.shared.log(.keybar, "keybar:dpad repeat start")
                    scheduleNextRepeat()
                }
                .onEnded { _ in stopRepeat() }
        )
    }

    /// Fire the arrow for the current thumb direction.
    private func fireArrow() {
        vm.keybar.arrow(dominantArrow(dx: lastTranslation.width, dy: lastTranslation.height))
    }

    /// Re-arm the repeat timer: ask the Kit decider for the interval at the current held-time.
    /// While still in the initial-delay window it returns nil — poll again at the remaining delay.
    private func scheduleNextRepeat() {
        guard let since = heldSince else { return }
        let held = Date().timeIntervalSince(since)
        let delay: TimeInterval
        let shouldFire: Bool
        if let interval = ArrowRepeat.interval(heldFor: held) {
            delay = interval
            shouldFire = true
        } else {
            delay = max(0.01, ArrowRepeat.initialDelay - held)   // wait out the remaining delay
            shouldFire = false
        }
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard self.heldSince != nil else { return }      // released between arm and fire
                if shouldFire { self.fireArrow() }
                self.scheduleNextRepeat()
            }
        }
    }

    /// Stop repeating and reset held state (on release).
    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        heldSince = nil
    }
}
```

> **Why `MainActor.assumeIsolated` in the Timer closure:** `Timer.scheduledTimer`'s closure is `nonisolated`, but it touches `@State` and `vm.keybar` on an `@MainActor` view. The main run loop fires it on the main thread, so `assumeIsolated` is safe and satisfies Swift 6 strict-concurrency (recurring macOS-CI-only trap — see the `@MainActor delegate-callback` memory).

- [ ] **Step 2: Push and let the macOS CI job validate the compile**

There is no local build for App-tier code. Commit, push, and rely on the macOS CI job (the only Apple build signal):

```bash
git add App/Keybar/KeybarSlotViews.swift
git commit -m "feat(keybar): held-swipe d-pad repeat (iOS timing via ArrowRepeat)"
git push github feat/finger-drag-window-transition
```

Then watch CI: `gh run list --repo ds7n/semicolyn --branch feat/finger-drag-window-transition --limit 1`
Expected: the `macos` job passes (no strict-concurrency or type errors).

- [ ] **Step 3: Gate TestFlight on macOS-green, then device-retest**

Once the macOS job is green, trigger a TestFlight build and device-test that:
- a quick swipe-and-release still sends exactly ONE arrow (no accidental repeat),
- holding the swipe past ~0.4s starts repeating and accelerates the longer it is held,
- sliding the thumb to a different axis mid-hold changes the repeat direction,
- releasing stops the repeat immediately.

```bash
gh workflow run "Release to TestFlight" --repo ds7n/semicolyn --ref feat/finger-drag-window-transition
```

---

## Self-Review

**Spec coverage:**
- iOS timing curve (initialDelay/startInterval/minInterval/rampDuration) → Task 1 `ArrowRepeat.interval`. ✓
- Dominant-axis direction, ties → horizontal → Task 1 `dominantArrow` + tests. ✓
- First arrow unchanged single-fire → Task 2 `onChanged` first-crossing `fireArrow()`. ✓
- Direction tracks thumb during hold → Task 2 `lastTranslation` read in `fireArrow`. ✓
- `@State` repeating Timer, release stops it → Task 2 `scheduleNextRepeat`/`stopRepeat`. ✓
- Throttled logging (one "repeat start", not per-tick) → Task 2 logs once in `onChanged`, none in the timer. ✓
- BVA tests on the curve + EP tests on direction → Task 1 Step 1. ✓

**Placeholder scan:** No TBD/TODO; all code shown in full. ✓

**Type consistency:** `ArrowRepeat.interval(heldFor:) -> TimeInterval?`, `dominantArrow(dx:dy:) -> ArrowDirection`, `vm.keybar.arrow(ArrowDirection)` — names/signatures match between Task 1 (produces) and Task 2 (consumes). ✓
