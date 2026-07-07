# Mosh Exit Classification + First-Frame Watchdog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix first-connect-over-Mosh landing on a blank terminal + crash banner instead of falling back to SSH, by classifying the Mosh loop exit on reason + elapsed time and adding a first-frame watchdog for the silent-hang case.

**Architecture:** Two pure decision functions in `Sources/SemicolynKit/Mosh/` (Linux-tested via XCTest), consumed by the App-tier `attachMoshIfPossible` `onEnd`/watchdog wiring (macOS-CI-verified). The `firstFrameSeen` boolean is removed from the exit decision.

**Tech Stack:** Swift 6 (SemicolynKit, strict-concurrency, `Sendable`), XCTest on Linux via the `semicolyn-dev` Docker image; SwiftUI/App tier for wiring.

## Global Constraints

- Every source file carries an SPDX header: `// SPDX-FileCopyrightText: 2026 True Positive LLC` + `// SPDX-License-Identifier: GPL-3.0-only`.
- Kit code: no `import UIKit`/`SwiftUI`; `Sendable` public types; annotate arg/return types.
- `graceWindow` default **3.0s**; `watchdogWindow` default **10.0s** (half-open: `elapsed < 3.0` → fallback, `== 3.0` → crashBanner).
- Exact device regression string: `"Mosh connection failed — using SSH"` (note the em dash `—`).
- Conventional commits; feature branch `fix/mosh-exit-classification` (already created); squash-merge to `main`.
- Kit tests run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter MoshExitDecisionTests`.

---

### Task 1: `MoshExitDecision` + `MoshWatchdogAction` Kit seams

**Files:**
- Create: `Sources/SemicolynKit/Mosh/MoshExitDecision.swift`
- Test: `Tests/SemicolynKitTests/MoshExitDecisionTests.swift`

**Interfaces:**
- Consumes: nothing (leaf pure functions).
- Produces:
  - `enum MoshExitDecision: Equatable, Sendable { case fallbackSSH, crashBanner, ended }`
  - `func moshExitDecision(reason: String?, elapsed: TimeInterval, graceWindow: TimeInterval = 3.0) -> MoshExitDecision`
  - `enum MoshWatchdogAction: Equatable, Sendable { case fallbackSSH, noop }`
  - `func moshWatchdogAction(sawAnyCallback: Bool) -> MoshWatchdogAction`

- [ ] **Step 1: Write the failing test**

Create `Tests/SemicolynKitTests/MoshExitDecisionTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class MoshExitDecisionTests: XCTestCase {
    // Clean exit (rc == 0 → nil reason) is a normal session end regardless of time.
    func testNilReasonIsEndedEarly() {
        XCTAssertEqual(moshExitDecision(reason: nil, elapsed: 0.05), .ended)
    }
    func testNilReasonIsEndedLate() {
        XCTAssertEqual(moshExitDecision(reason: nil, elapsed: 120), .ended)
    }

    // Nonzero exit inside the grace window = handshake never came up → SSH fallback.
    func testFailureAtZeroIsFallback() {
        XCTAssertEqual(moshExitDecision(reason: "boom", elapsed: 0), .fallbackSSH)
    }
    // Boundary: 2.999 < 3.0 → fallback.
    func testFailureJustUnderGraceIsFallback() {
        XCTAssertEqual(moshExitDecision(reason: "boom", elapsed: 2.999), .fallbackSSH)
    }
    // Boundary: exactly 3.0 is NOT inside the half-open window → crashBanner.
    func testFailureAtGraceBoundaryIsCrashBanner() {
        XCTAssertEqual(moshExitDecision(reason: "boom", elapsed: 3.0), .crashBanner)
    }
    func testFailureJustOverGraceIsCrashBanner() {
        XCTAssertEqual(moshExitDecision(reason: "boom", elapsed: 3.001), .crashBanner)
    }
    func testFailureLongAfterIsCrashBanner() {
        XCTAssertEqual(moshExitDecision(reason: "boom", elapsed: 30), .crashBanner)
    }

    // Regression pin: the EXACT device trace — reason string at 0.09s → fallback.
    func testDeviceTraceStringAtNinetyMsIsFallback() {
        XCTAssertEqual(
            moshExitDecision(reason: "Mosh connection failed — using SSH", elapsed: 0.09),
            .fallbackSSH)
    }

    // Custom grace window is honored (BVA around a 5s window).
    func testCustomGraceWindow() {
        XCTAssertEqual(moshExitDecision(reason: "boom", elapsed: 4.9, graceWindow: 5.0), .fallbackSSH)
        XCTAssertEqual(moshExitDecision(reason: "boom", elapsed: 5.0, graceWindow: 5.0), .crashBanner)
    }

    // Watchdog: no callback seen by deadline → SSH fallback; any callback → noop.
    func testWatchdogNoCallbackIsFallback() {
        XCTAssertEqual(moshWatchdogAction(sawAnyCallback: false), .fallbackSSH)
    }
    func testWatchdogAnyCallbackIsNoop() {
        XCTAssertEqual(moshWatchdogAction(sawAnyCallback: true), .noop)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter MoshExitDecisionTests`
Expected: FAIL to compile — `cannot find 'moshExitDecision' in scope` (and the two enums / `moshWatchdogAction`).

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SemicolynKit/Mosh/MoshExitDecision.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// How a Mosh loop exit should be handled by `ConnectionViewModel`. Extracted here
/// (pure, Linux-tested) so the decision is covered off the Apple-only bridge gate.
///
/// The former `firstFrameSeen` discriminator was removed: real mosh emits an
/// init/clear framebuffer diff BEFORE the UDP handshake is confirmed, so
/// `onFirstFrame` fired for a connection that then failed — a device trace showed a
/// nonzero exit 90ms after `onFirstFrame`, wrongly routed to the crash banner. Exit
/// reason + elapsed time classify correctly instead.
public enum MoshExitDecision: Equatable, Sendable {
    /// Handshake never really came up (nonzero exit inside the grace window) →
    /// SSH on the retained connection + banner.
    case fallbackSSH
    /// A live session died (nonzero exit after the grace window) → mid-session crash banner.
    case crashBanner
    /// Clean exit (rc == 0, `nil` reason) → session ended normally.
    case ended
}

/// Classify a Mosh loop exit.
/// - Parameters:
///   - reason: the `onEnd` reason string; `nil` ⟺ a clean (rc == 0) exit.
///   - elapsed: seconds from `sess.start()` to `onEnd`.
///   - graceWindow: the handshake grace window (half-open: `elapsed < graceWindow`
///     is a handshake failure). Default 3.0s.
public func moshExitDecision(reason: String?, elapsed: TimeInterval,
                             graceWindow: TimeInterval = 3.0) -> MoshExitDecision {
    guard reason != nil else { return .ended }
    return elapsed < graceWindow ? .fallbackSSH : .crashBanner
}

/// The first-frame watchdog action. The exit timer only fires when mosh *exits*; a
/// hung UDP path where `mosh_main` neither renders a frame nor returns leaves a
/// permanent blank screen. The App arms a watchdog after `sess.start()`; if no
/// callback (`onFirstFrame` or `onEnd`) has fired by the deadline, fall back to SSH.
public enum MoshWatchdogAction: Equatable, Sendable {
    case fallbackSSH
    case noop
}

/// Decide the watchdog action given whether the loop signalled any life by the deadline.
public func moshWatchdogAction(sawAnyCallback: Bool) -> MoshWatchdogAction {
    sawAnyCallback ? .noop : .fallbackSSH
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter MoshExitDecisionTests`
Expected: PASS — `Executed 12 tests, with 0 failures`.

- [ ] **Step 5: Run the full Kit suite to confirm no regression**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS — all tests (prior count + 12) green.

- [ ] **Step 6: Commit**

```bash
git add Sources/SemicolynKit/Mosh/MoshExitDecision.swift Tests/SemicolynKitTests/MoshExitDecisionTests.swift
git commit -m "feat(mosh): moshExitDecision + moshWatchdogAction Kit seams

Classify a Mosh loop exit by reason + elapsed time instead of the unreliable
firstFrameSeen flag: clean exit -> .ended; nonzero <3s -> .fallbackSSH;
nonzero >=3s -> .crashBanner. Plus moshWatchdogAction for the no-callback hang.
Pins the device-trace regression string at 90ms -> fallbackSSH. Kit-tested."
```

---

### Task 2: Wire `moshExitDecision` into `attachMoshIfPossible` `onEnd`

**Files:**
- Modify: `App/ConnectionViewModel.swift` (the `sess.onEnd` closure in `attachMoshIfPossible`, ~lines 602–635)

**Interfaces:**
- Consumes: `moshExitDecision(reason:elapsed:)`, `MoshExitDecision` from Task 1.
- Produces: nothing new for later tasks (behavior change only).

**Note:** App tier — NOT Linux-buildable. Verified by macOS CI, not `swift test`. Follow the existing branch bodies exactly; only the *selector* changes from `if moshFirstFrameSeen` to a `switch moshExitDecision(...)`.

- [ ] **Step 1: Capture the start time before `sess.start()`**

Find (in `attachMoshIfPossible`, just before the existing `sess.start()` / its DebugLog):

```swift
            DebugLog.shared.log("mosh: sess.start() — UDP session launching, state=.shell")
            sess.start()
```

Replace with (add the monotonic timestamp):

```swift
            let moshStartedAt = ProcessInfo.processInfo.systemUptime
            DebugLog.shared.log("mosh: sess.start() — UDP session launching, state=.shell")
            sess.start()
```

(`systemUptime` is a monotonic clock — the same source `TmuxRuntime` uses for context poll timing — so it is immune to wall-clock changes.)

- [ ] **Step 2: Replace the `firstFrameSeen` branch in `onEnd` with the decision**

Find the `sess.onEnd` closure body (the part after the `DebugLog ... onEnd firstFrameSeen=...` line):

```swift
                if self.moshFirstFrameSeen {
                    // Post-first-frame exit ...
                    self.moshSession?.stop()
                    self.moshSession = nil
                    self.moshFirstFrameSeen = false
                    DebugLog.shared.log("mosh: post-first-frame exit → crash banner")
                    self.crashBanner = .tmuxEnded
                    return
                }
                // Pre-first-frame exit ...
                self.moshSession?.stop()
                self.moshSession = nil
                self.moshFallback = "Mosh UDP unreachable (check firewall) — using SSH"
                DebugLog.shared.log("mosh: pre-first-frame exit (UDP blocked) → SSH fallback")
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.attachSSHShell(conn: conn, host: host, defaults: defaults)
                    } catch {
                        DebugLog.shared.log("mosh: SSH fallback THREW \(String(describing: error)) → .failed")
                        self.state = .failed(String(describing: error))
                    }
                }
```

Replace that whole block with:

```swift
                let elapsed = ProcessInfo.processInfo.systemUptime - moshStartedAt
                switch moshExitDecision(reason: reason, elapsed: elapsed) {
                case .crashBanner:
                    self.moshSession?.stop()
                    self.moshSession = nil
                    self.moshFirstFrameSeen = false
                    DebugLog.shared.log("mosh: exit crashBanner (elapsed=\(String(format: "%.2f", elapsed))s) → crash banner")
                    self.crashBanner = .tmuxEnded
                    return
                case .ended:
                    // Clean exit (rc == 0). v1: surface via the same session-ended state
                    // as a clean tmux exit (no alarming "crashed" copy needed).
                    self.moshSession?.stop()
                    self.moshSession = nil
                    self.moshFirstFrameSeen = false
                    DebugLog.shared.log("mosh: exit ended (clean, elapsed=\(String(format: "%.2f", elapsed))s) → session ended")
                    self.crashBanner = .tmuxEnded
                    return
                case .fallbackSSH:
                    self.moshSession?.stop()
                    self.moshSession = nil
                    self.moshFallback = "Mosh connection failed — using SSH"
                    DebugLog.shared.log("mosh: exit fallbackSSH (elapsed=\(String(format: "%.2f", elapsed))s) → SSH fallback")
                    Task { [weak self] in
                        guard let self else { return }
                        do {
                            try await self.attachSSHShell(conn: conn, host: host, defaults: defaults)
                        } catch {
                            DebugLog.shared.log("mosh: SSH fallback THREW \(String(describing: error)) → .failed")
                            self.state = .failed(String(describing: error))
                        }
                    }
                }
```

- [ ] **Step 3: Verify the `reason` binding is in scope**

Confirm the closure signature is `sess.onEnd = { [weak self] reason in` (it was renamed from `_` in an earlier diagnostics commit). If it still reads `{ [weak self] _ in`, change `_` to `reason`. The `DebugLog(... reason=\(reason ?? "nil"))` line above already references `reason`, so it is in scope.

- [ ] **Step 4: Commit**

```bash
git add App/ConnectionViewModel.swift
git commit -m "fix(mosh): classify onEnd by reason+elapsed, not firstFrameSeen

A nonzero mosh exit within 3s of start (handshake failure) now falls back to
SSH even when onFirstFrame already fired for the pre-handshake init diff —
fixing the build-22 device trace (blank terminal + crash banner on first
connect). Nonzero >=3s still shows the crash banner; a clean exit ends the
session. Uses monotonic systemUptime for elapsed."
```

---

### Task 3: Arm the first-frame watchdog in `attachMoshIfPossible`

**Files:**
- Modify: `App/ConnectionViewModel.swift` (the `.mosh` case of `attachMoshIfPossible`; a stored watchdog `Task` property + arm/cancel wiring)

**Interfaces:**
- Consumes: `moshWatchdogAction(sawAnyCallback:)`, `MoshWatchdogAction` from Task 1.
- Produces: nothing new.

**Note:** App tier — macOS-CI-verified. The watchdog cancels on `onFirstFrame` OR `onEnd`; its sole job is the no-callback-at-all hang (a session that got an init frame but then fails fast is already handled by Task 2's <3s classification).

- [ ] **Step 1: Add a stored watchdog task property**

Near the other Mosh state properties (search for `moshFirstFrameSeen` / `moshSession` declarations), add:

```swift
    /// First-frame watchdog: fires an SSH fallback if the Mosh loop signals no life
    /// (no onFirstFrame, no onEnd) within the window. Cancelled by either callback.
    private var moshWatchdog: Task<Void, Never>?
```

- [ ] **Step 2: Cancel the watchdog from `onFirstFrame` and `onEnd`**

In `sess.onFirstFrame`, after `self?.moshFirstFrameSeen = true`, add cancellation:

```swift
            sess.onFirstFrame = { [weak self] in
                DebugLog.shared.log("mosh: onFirstFrame — UDP handshake up, frames flowing")
                self?.moshFirstFrameSeen = true
                self?.moshWatchdog?.cancel(); self?.moshWatchdog = nil
                DebugLog.shared.log("mosh: watchdog cancelled (onFirstFrame)")
            }
```

At the very top of the `sess.onEnd` closure (right after `guard let self else { return }`), add:

```swift
                self.moshWatchdog?.cancel(); self.moshWatchdog = nil
```

- [ ] **Step 3: Arm the watchdog after `sess.start()`**

Immediately after `sess.start()` and the `moshSession = sess` assignment (before `state = .shell` / `return true`), add:

```swift
            moshWatchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)   // 10s watchdog window
                guard !Task.isCancelled, let self else { return }
                // No onFirstFrame/onEnd cancelled us → the loop signalled no life.
                guard case .fallbackSSH = moshWatchdogAction(sawAnyCallback: false) else { return }
                DebugLog.shared.log("mosh: watchdog fired (no frame/exit in 10s) → SSH fallback")
                self.moshSession?.stop()
                self.moshSession = nil
                self.moshFallback = "Mosh didn't connect — using SSH"
                do {
                    try await self.attachSSHShell(conn: conn, host: host, defaults: defaults)
                } catch {
                    DebugLog.shared.log("mosh: watchdog SSH fallback THREW \(String(describing: error)) → .failed")
                    self.state = .failed(String(describing: error))
                }
            }
```

(The `moshWatchdogAction(sawAnyCallback: false)` call is trivially `.fallbackSSH` here — reaching this line already means neither callback cancelled the task — but it routes the decision through the tested Kit seam rather than hard-coding the branch.)

- [ ] **Step 4: Cancel the watchdog in `teardown()`**

In `teardown()` (search for where `moshSession` is stopped/cleared), add:

```swift
        moshWatchdog?.cancel(); moshWatchdog = nil
```

- [ ] **Step 5: Commit**

```bash
git add App/ConnectionViewModel.swift
git commit -m "fix(mosh): first-frame watchdog for the silent-UDP-hang case

If the Mosh loop neither renders a frame nor exits within 10s, proactively
fall back to SSH instead of leaving a permanent blank screen. Cancelled by
onFirstFrame or onEnd; cleared in teardown. Routes through the Kit
moshWatchdogAction seam."
```

---

### Task 4: Amend the M3/M4 spec's first-frame dividing line

**Files:**
- Modify: `docs/superpowers/specs/2026-07-03-mosh-m3-m4-bridge-wiring-design.md` (the dividing-line paragraph ~lines 207–209 and the failure-mode rows ~217–220)

**Interfaces:** none (docs).

- [ ] **Step 1: Add an amendment note under the dividing-line paragraph**

Find the paragraph beginning "Dividing line: **before the first frame** arrives ...". Immediately after it, insert:

```markdown
> **Amendment 2026-07-07 (see `2026-07-07-mosh-exit-classification-design.md`):** the
> `firstFrameSeen` discriminator was removed. Real mosh emits an init/clear framebuffer
> diff BEFORE the UDP handshake is confirmed, so `onFirstFrame` fires for a connection that
> then fails (device trace: nonzero exit 90ms after `onFirstFrame`). Exits are now classified
> by **reason + elapsed time**: a nonzero exit within a 3s grace window → SSH fallback (even if
> a frame was "seen"); ≥3s → crash banner; a clean exit → session ended. A separate 10s
> first-frame watchdog covers a hung UDP path that never calls back.
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-07-03-mosh-m3-m4-bridge-wiring-design.md
git commit -m "docs(spec): amend M3/M4 first-frame dividing line (exit classification)"
```

---

## Self-Review

**Spec coverage:**
- Piece 1 `moshExitDecision` → Task 1 (impl+tests) + Task 2 (wiring). ✅
- Piece 2 watchdog (`moshWatchdogAction` + 10s timer) → Task 1 (seam+tests) + Task 3 (wiring). ✅
- `.ended` clean-exit v1 handling (reuse `.tmuxEnded`) → Task 2 Step 2 `.ended` case. ✅
- Spec amendment → Task 4. ✅
- Boundary/regression tests (2.999/3.0, device string @ 0.09s) → Task 1 Step 1. ✅

**Placeholder scan:** No TBD/TODO; every code step shows full code; commands have expected output. ✅

**Type consistency:** `moshExitDecision(reason:elapsed:graceWindow:)`, `MoshExitDecision.{fallbackSSH,crashBanner,ended}`, `moshWatchdogAction(sawAnyCallback:)`, `MoshWatchdogAction.{fallbackSSH,noop}`, `moshWatchdog: Task<Void, Never>?` — used identically in Tasks 1→2→3. ✅

**Notes:** Tasks 2/3 are App-tier (not Linux-buildable); their compile signal is macOS CI on the PR, per repo convention. Task 1 is the only Linux-TDD'd unit and carries the real behavioral coverage.
