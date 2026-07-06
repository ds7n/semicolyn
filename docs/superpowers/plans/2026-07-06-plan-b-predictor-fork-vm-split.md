<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Plan B — Predictor keystroke-fork + ViewModel split + measurement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Take the predictor off the keystroke send-path (send-first, observe-forked), coalesce suggestion recomputation, split the god-`ConnectionViewModel` so a suggestion tick can't invalidate the whole session view tree, and add the first keystroke-latency measurement — while keeping the testable *policy* in Linux-tested Kit and the App-tier wiring thin.

**Architecture:** Applies the Humble-Object seam to the fork itself. The *decisions* — which bytes are predictor-relevant, when to recompute suggestions (coalescing), whether a burst is quiet enough to publish — become pure `Sendable` units in `Sources/SemicolynKit/` with real TDD (Linux-verified). The App-tier `PredictorActor` (a Swift `actor` = FIFO mailbox + off-main executor + serial ordering), the `sendTerminalInput` reorder, the `ConnectionViewModel` split, and the `os_signpost` hooks are thin wiring validated by macOS-CI compile + on-device pass — they carry no logic a unit test could own.

**Tech Stack:** Swift 6 (strict concurrency, `Sendable`, `actor`), XCTest, `os.signpost`, SwiftUI `ObservableObject`, Docker dev image `semicolyn-dev`.

## Global Constraints

- Every source file carries an SPDX header: `// SPDX-FileCopyrightText: 2026 True Positive LLC` then `// SPDX-License-Identifier: GPL-3.0-only`.
- `Sources/SemicolynKit/` is pure/Linux-tested: Swift 6 strict-concurrency, `Sendable`, **no `import UIKit`/`SwiftUI`/`CryptoKit`**.
- Tests must be real (repo standard): EP + BVA, assert observable EXACT values (no tautologies); a negative/boundary test asserts the *specific* expected value.
- **The keystroke is sacred:** in `sendTerminalInput`, the byte MUST be written to the transport (mosh/tmux/raw) BEFORE any predictor observation runs. No predictor work may sit between the user's keypress and the wire.
- **SwiftTerm grid reads are `@MainActor`-only:** the L1 echo oracle (`passwordDetector.currentCursor()` / `settleLine`) reads the live `TerminalView` grid and therefore cannot move off the main actor. The FIFO carries already-echo-anchored data; the grid read stays a deferred main-actor step.
- **Preserve the L1/L4a invariants:** the per-call echo *anchor* is captured before delivery (never shared across calls); per-line token commit + opt-out latch + echo-settle ordering must remain sequential per line. Learning still gates on `echoConfirmed && !optedOut`.
- Conventional commits. Work on branch `feat/predictor-fork-vm-split`; squash-merge to `main`.
- Linux loop: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`. NO Swift toolchain on host. App-tier files (`App/**`) compile only on macOS CI.

---

## Phase 1 — Linux-testable policy core (Kit, TDD)

### Task 1: `PredictorInputFilter` — pure predictor-relevant scalar extraction

**Files:**
- Create: `Sources/SemicolynKit/Predictor/PredictorInputFilter.swift`
- Create: `Tests/SemicolynKitTests/PredictorInputFilterTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public func predictorScalars(_ bytes: [UInt8]) -> [Unicode.Scalar]` — extracts the printable-ASCII scalars (0x20 space through 0x7e `~`) the predictor cares about, matching the existing inline filter in `observePredictorInput`. Empty result ⇒ this chunk has no predictor-relevant input (no echo anchor / no settle needed).

- [ ] **Step 1: Write the failing test**

Create `Tests/SemicolynKitTests/PredictorInputFilterTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Pure extraction of predictor-relevant printable scalars from raw input bytes.
final class PredictorInputFilterTests: XCTestCase {
    private func s(_ str: String) -> [Unicode.Scalar] { Array(str.unicodeScalars) }

    // EP: plain printable ASCII passes through unchanged.
    func testPrintableAsciiPassesThrough() {
        XCTAssertEqual(predictorScalars(Array("ls".utf8)), s("ls"))
    }

    // BVA: space (0x20) is the low boundary — included.
    func testSpaceIsIncluded() {
        XCTAssertEqual(predictorScalars([0x20]), s(" "))
    }

    // BVA: tilde (0x7e) is the high boundary — included.
    func testTildeIsIncluded() {
        XCTAssertEqual(predictorScalars([0x7e]), s("~"))
    }

    // BVA: 0x1f (just below space) is excluded.
    func testBelowSpaceExcluded() {
        XCTAssertEqual(predictorScalars([0x1f]), [])
    }

    // BVA: 0x7f (DEL, just above tilde) is excluded.
    func testDelExcluded() {
        XCTAssertEqual(predictorScalars([0x7f]), [])
    }

    // Control bytes (newline, CR, ESC) are dropped; printable neighbours survive.
    func testControlBytesDroppedPrintableKept() {
        XCTAssertEqual(predictorScalars([0x61, 0x0d, 0x0a, 0x62]), s("ab"))
    }

    // Empty input ⇒ empty (no predictor-relevant scalars).
    func testEmptyInput() {
        XCTAssertEqual(predictorScalars([]), [])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PredictorInputFilterTests`
Expected: FAIL — `cannot find 'predictorScalars' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `Sources/SemicolynKit/Predictor/PredictorInputFilter.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Extract the printable-ASCII scalars the predictor cares about — space (0x20)
/// through tilde (0x7e) — from a raw input byte chunk. An empty result means the
/// chunk carries no predictor-relevant input (no echo anchor or settle is needed).
/// Mirrors the filter previously inlined in `ConnectionViewModel.observePredictorInput`.
public func predictorScalars(_ bytes: [UInt8]) -> [Unicode.Scalar] {
    bytes.compactMap { b in
        ((0x21...0x7e).contains(b) || b == 0x20) ? Unicode.Scalar(UInt32(b)) : nil
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PredictorInputFilterTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Predictor/PredictorInputFilter.swift \
        Tests/SemicolynKitTests/PredictorInputFilterTests.swift
git commit -m "feat(kit): extract predictor-relevant scalar filter to PredictorInputFilter + BVA tests"
```

---

### Task 2: `SuggestionRefreshCoalescer` — pure burst-collapse policy

**Files:**
- Create: `Sources/SemicolynKit/Predictor/SuggestionRefreshCoalescer.swift`
- Create: `Tests/SemicolynKitTests/SuggestionRefreshCoalescerTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: a value type deciding whether a suggestion recompute should fire *now* or be deferred, so a burst of keystrokes recomputes suggestions once rather than per-keystroke (today `refreshPredictorSuggestions()` fires twice per keystroke — inline + settle). Time is injected (no wall-clock in Kit).

  ```swift
  public struct SuggestionRefreshCoalescer: Sendable {
      public init(quietWindow: Double)              // seconds of quiet before a refresh is "due"
      public mutating func requestRefresh(at now: Double)   // record a refresh request
      public func isDue(at now: Double) -> Bool             // true iff quietWindow elapsed since last request
      public var lastRequested: Double? { get }
  }
  ```
  The App drives it: on each observe, call `requestRefresh(at:)`; schedule a check at `now + quietWindow`; when the check fires, only actually recompute if `isDue(at:)` (i.e. no newer request arrived). This collapses a burst into one trailing recompute.

- [ ] **Step 1: Write the failing test**

Create `Tests/SemicolynKitTests/SuggestionRefreshCoalescerTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Pure trailing-debounce policy: a burst of refresh requests collapses to one
/// recompute once the quiet window elapses with no newer request.
final class SuggestionRefreshCoalescerTests: XCTestCase {
    // Not due before the quiet window elapses.
    func testNotDueBeforeQuietWindow() {
        var c = SuggestionRefreshCoalescer(quietWindow: 0.05)
        c.requestRefresh(at: 1.00)
        XCTAssertFalse(c.isDue(at: 1.02))   // only 20ms elapsed < 50ms
    }

    // Due exactly at the boundary (quietWindow elapsed).
    func testDueAtBoundary() {
        var c = SuggestionRefreshCoalescer(quietWindow: 0.05)
        c.requestRefresh(at: 1.00)
        XCTAssertTrue(c.isDue(at: 1.05))    // exactly 50ms elapsed
    }

    // A newer request within the window resets the clock — the earlier check is no longer due.
    func testNewerRequestResetsWindow() {
        var c = SuggestionRefreshCoalescer(quietWindow: 0.05)
        c.requestRefresh(at: 1.00)
        c.requestRefresh(at: 1.03)          // burst continues
        XCTAssertFalse(c.isDue(at: 1.05))   // measured from 1.03, only 20ms elapsed
        XCTAssertTrue(c.isDue(at: 1.08))    // 50ms after the LATEST request
    }

    // Never requested ⇒ never due (nothing to recompute).
    func testNeverRequestedNeverDue() {
        let c = SuggestionRefreshCoalescer(quietWindow: 0.05)
        XCTAssertFalse(c.isDue(at: 99.0))
        XCTAssertNil(c.lastRequested)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter SuggestionRefreshCoalescerTests`
Expected: FAIL — `cannot find 'SuggestionRefreshCoalescer' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `Sources/SemicolynKit/Predictor/SuggestionRefreshCoalescer.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Trailing-debounce policy for suggestion recomputation. Each keystroke calls
/// `requestRefresh(at:)`; a check scheduled `quietWindow` later recomputes only if
/// `isDue(at:)` — i.e. no newer request arrived — so a typing burst collapses to a
/// single trailing recompute instead of one per keystroke. Time is injected so the
/// policy is pure and Linux-testable (no wall-clock in Kit).
public struct SuggestionRefreshCoalescer: Sendable {
    public private(set) var lastRequested: Double?
    private let quietWindow: Double

    public init(quietWindow: Double) { self.quietWindow = quietWindow }

    public mutating func requestRefresh(at now: Double) { lastRequested = now }

    public func isDue(at now: Double) -> Bool {
        guard let last = lastRequested else { return false }
        return now - last >= quietWindow
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter SuggestionRefreshCoalescerTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Predictor/SuggestionRefreshCoalescer.swift \
        Tests/SemicolynKitTests/SuggestionRefreshCoalescerTests.swift
git commit -m "feat(kit): add SuggestionRefreshCoalescer trailing-debounce policy + BVA tests"
```

---

## Phase 2 — App-tier wiring (macOS-CI compile + on-device verified; NO local test cycle)

> These tasks touch `App/**`, which compiles only on the macOS CI job and is behaviorally verified on-device. There is no local `swift test` for them. Each task's "test" is: (a) it compiles under Swift 6 strict concurrency on macOS CI, and (b) a named on-device check. Do NOT claim a local test pass. The implementer writes the code exactly and commits; verification is the macOS CI run + the device pass the controller coordinates.

### Task 3: Send-first reorder + fork predictor via `predictorScalars`

**Files:**
- Modify: `App/ConnectionViewModel.swift` (`sendTerminalInput` ~179-188; `observePredictorInput` ~813-857)

**Interfaces:**
- Consumes: `predictorScalars(_:)` (Task 1).
- Produces: no new public API; changes call ORDER and uses the Kit filter.

- [ ] **Step 1: Reorder `sendTerminalInput` — write first, observe second**

Change `sendTerminalInput` so the transport write precedes observation (the keystroke is sacred):

```swift
    func sendTerminalInput(_ bytes: [UInt8]) {
        // The keystroke is sacred: write to the transport BEFORE any predictor work,
        // so send latency is independent of predictor cost (Plan B).
        if let moshSession {
            moshSession.writeInput(Data(bytes))
        } else if let tmux {
            tmux.sendInput(bytes)
        } else {
            rawWriter?.enqueue(bytes)
        }
        observePredictorInput(bytes)
    }
```

- [ ] **Step 2: Use the Kit scalar filter in `observePredictorInput`**

Replace the inline `compactMap` filter at the top of `observePredictorInput` with the extracted Kit function (behavior-identical, now shared + tested):

```swift
        let scalars = predictorScalars(bytes)
```

(Delete the old 3-line `let scalars: [Unicode.Scalar] = bytes.compactMap { ... }` block. Everything downstream — `anchor`, `settleLine(scalars:)` — is unchanged.)

- [ ] **Step 3: Commit**

```bash
git add App/ConnectionViewModel.swift
git commit -m "refactor(app): send keystroke before predictor observe + use Kit predictorScalars"
```

Verification (controller-coordinated, not local): macOS CI compiles `App`; on-device check — typing feels no worse and suggestions still populate; typing a password (non-echoed) still does not learn.

---

### Task 4: `PredictorActor` — off-main FIFO consumer of the pure engine

**Files:**
- Create: `App/PredictorActor.swift`
- Modify: `App/ConnectionViewModel.swift` (own the actor; route consume through it; publish coalesced)

**Interfaces:**
- Consumes: `PredictorEngine` (Kit `struct` with `mutating record`, non-mutating `suggestions(forPrefix:after:)`), `InputTokenTracker`, `SuggestionRefreshCoalescer` (Task 2).
- Produces:
  ```swift
  actor PredictorActor {
      init(engine: PredictorEngine)
      // Serial mailbox = FIFO; preserves per-line ordering.
      func record(_ tokens: [CommittedToken], echoConfirmed: Bool, optedOut: Bool)
      func suggestions(forPrefix prefix: String, after previous: String?) -> [String]
      func beginLine()
      func snapshotState() -> LearnedState          // for persistence/purge
      func purgeLearned()
      func forgetLastLine()
  }
  ```
  The actor OWNS the `PredictorEngine` value (moved off `ConnectionViewModel`). The heavy consume (`record`, vocab update) and the `suggestions` computation run on the actor's executor, off the main actor. The `ConnectionViewModel` `await`s `suggestions(...)` then publishes on main. The grid-reading echo oracle (`passwordDetector`) stays on `ConnectionViewModel` (main actor) — the actor never touches the grid.

- [ ] **Step 1: Create the actor**

Create `App/PredictorActor.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SemicolynKit

/// Off-main-actor owner of the predictor engine. Its serial mailbox IS the FIFO
/// that decouples predictor work from the keystroke send-path: `ConnectionViewModel`
/// writes the byte to the transport, then hands already-echo-classified tokens here
/// via `await`. Consuming (record + vocab) and `suggestions` run on this actor's
/// executor, never on main; the SwiftTerm grid-reading echo oracle stays on the VM's
/// main actor and never crosses this boundary. Serial isolation preserves the
/// per-line commit/record ordering the L1/L4a invariants require.
actor PredictorActor {
    private var engine: PredictorEngine

    init(engine: PredictorEngine) { self.engine = engine }

    func beginLine() { engine.beginLine() }

    func record(_ tokens: [CommittedToken], echoConfirmed: Bool, optedOut: Bool) {
        for c in tokens {
            engine.record(c.token, after: c.previous,
                          echoConfirmed: echoConfirmed, optedOut: optedOut)
        }
    }

    func suggestions(forPrefix prefix: String, after previous: String?) -> [String] {
        engine.suggestions(forPrefix: prefix, after: previous)
    }

    func snapshotState() -> LearnedState { engine.state }
    func purgeLearned() { engine.purgeLearned() }
    func forgetLastLine() { engine.forgetLastLine() }
}
```

- [ ] **Step 2: Route `ConnectionViewModel` through the actor**

In `ConnectionViewModel`: replace the stored `private var engine: PredictorEngine?` with `private var predictor: PredictorActor?`. In `observePredictorInput`, the newline branch's `engine.beginLine()` + `engine.record(...)` loop becomes an `await predictor.record(pendingLineTokens, echoConfirmed:optedOut:)` (wrapped in a `Task`, since the surrounding `asyncAfter` closure is main-actor sync — hop into a `Task { await ... }`). `refreshPredictorSuggestions` becomes:

```swift
    private func refreshPredictorSuggestions() {
        guard let predictor else { predictorSuggestions = []; return }
        let prefix = tracker.current, prev = tracker.previous
        Task { [weak self] in
            let raw = await predictor.suggestions(forPrefix: prefix, after: prev)
            await MainActor.run {
                self?.predictorSuggestions = self?.predictorChips(current: prefix, suggestions: raw) ?? []
            }
        }
    }
```

Wire the coalescer: hold `private var refreshCoalescer = SuggestionRefreshCoalescer(quietWindow: 0.04)`; on each observe call `refreshCoalescer.requestRefresh(at: <now>)` and schedule the actual `refreshPredictorSuggestions()` behind an `isDue` check at `+40ms`, replacing the unconditional double-call (inline + settle) with one trailing recompute. Keep the existing 40ms echo-settle hop for the grid read (that stays main-actor).

- [ ] **Step 3: Commit**

```bash
git add App/PredictorActor.swift App/ConnectionViewModel.swift
git commit -m "feat(app): PredictorActor off-main FIFO consumer + coalesced suggestion refresh"
```

Verification (controller-coordinated): macOS CI compiles under Swift 6 strict concurrency (the actor-boundary `Sendable` checks are the real gate here — `CommittedToken`/`LearnedState` are already `Sendable`); on-device — suggestions still appear after typing; learned words persist across the session; password lines still never learn; no perceptible input lag.

---

### Task 5: `os_signpost` keystroke-latency measurement

**Files:**
- Create: `App/PerfSignposts.swift`
- Modify: `App/ConnectionViewModel.swift` (`sendTerminalInput` — bracket the write)
- Create: `docs/perf-measurement.md`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum PerfSignposts` with an `OSSignposter` and an interval around the sacred write path.

- [ ] **Step 1: Create the signpost helper**

Create `App/PerfSignposts.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import os

/// First performance instrumentation (Plan B §B3). `input` brackets the sacred
/// keystroke→transport-write path so its latency is independent of predictor cost
/// and can be watched in Instruments. Zero cost when not being traced.
enum PerfSignposts {
    static let input = OSSignposter(subsystem: "dev.truepositive.semicolyn", category: "input")
}
```

- [ ] **Step 2: Bracket the write in `sendTerminalInput`**

Wrap ONLY the transport write (not the observe) in an interval:

```swift
    func sendTerminalInput(_ bytes: [UInt8]) {
        let state = PerfSignposts.input.beginInterval("send")
        if let moshSession {
            moshSession.writeInput(Data(bytes))
        } else if let tmux {
            tmux.sendInput(bytes)
        } else {
            rawWriter?.enqueue(bytes)
        }
        PerfSignposts.input.endInterval("send", state)
        observePredictorInput(bytes)
    }
```

- [ ] **Step 3: Document how to capture a trace**

Create `docs/perf-measurement.md`:

```markdown
<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Measuring keystroke latency

The `send` os_signpost interval (`PerfSignposts.input`, subsystem
`dev.truepositive.semicolyn`, category `input`) brackets the sacred keystroke →
transport-write path. Because the predictor now runs AFTER the write (Plan B),
this interval's duration should be independent of predictor cost.

**Capture (on device or Simulator):**
1. Xcode → Product → Profile (⌘I) → **os_signpost** (or **Time Profiler**) template.
2. Type a burst / paste into an active session.
3. Filter Instruments to subsystem `dev.truepositive.semicolyn`, category `input`.
4. Read the `send` interval durations. Regression = the distribution creeps up,
   especially correlating with predictor/keybar activity — which would mean
   something re-coupled work onto the send path.

This is the number that makes "snappy" objective instead of a fear.
```

- [ ] **Step 4: Commit**

```bash
git add App/PerfSignposts.swift App/ConnectionViewModel.swift docs/perf-measurement.md
git commit -m "feat(app): os_signpost keystroke-latency measurement on the sacred send path + docs"
```

Verification (controller-coordinated): macOS CI compiles; on-device Instruments trace shows the `send` interval and its duration does not track predictor activity.

---

## Phase 3 — ViewModel split (App-tier; macOS-CI compile + on-device verified)

### Task 6: Split `ConnectionViewModel` into focused observable slices

**Files:**
- Create: `App/SessionCoreModel.swift`, `App/TmuxViewModel.swift`, `App/PredictorViewModel.swift`
- Modify: `App/ConnectionViewModel.swift` (becomes a thin coordinator owning the three), and the observing views (`App/SessionView.swift`, `App/Keybar/PredictorStripView.swift`, `App/Keybar/PromotionSlotView.swift`, `App/Keybar/KeybarView.swift`, `App/Keybar/KeyboardCommandsView.swift`, `App/Keybar/KeybarSlotViews.swift`)

**Interfaces:**
- Consumes: `PredictorActor` (Task 4).
- Produces: three `@MainActor final class … : ObservableObject` slices so a mutation in one does not invalidate views observing another:
  - `SessionCoreModel` — `state`, `pendingPrompt`, `presentedSheet`, `degraded`, `crashBanner`, `moshFallback`, `tmuxDiag` (connection lifecycle + banners → `SessionView`).
  - `TmuxViewModel` — `tmuxState`, `terminalTitle`, `paneContexts` (pane container + tab strip).
  - `PredictorViewModel` — `predictorSuggestions`, `fnState` (the Keybar/predictor-strip views).

  `ConnectionViewModel` retains connection ownership + the main-actor echo oracle and holds the three as `@Published private(set)` children (or the views observe the children directly via `@ObservedObject`). Exact ownership wiring is an implementer judgment call validated by compile; the REQUIREMENT is that a `predictorSuggestions` mutation must not force `SessionView`'s body to re-evaluate.

- [ ] **Step 1: Create the three slice classes**

Create each as a `@MainActor final class … : ObservableObject` moving the `@Published` properties listed above out of `ConnectionViewModel`. (Full property lists per the Interfaces block; each carries the SPDX header.) Example shape for `PredictorViewModel.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

@MainActor
final class PredictorViewModel: ObservableObject {
    @Published private(set) var predictorSuggestions: [String] = []
    @Published private(set) var fnState = FnState()

    func setSuggestions(_ s: [String]) { predictorSuggestions = s }
    func setFnState(_ f: FnState) { fnState = f }
}
```

(`SessionCoreModel` and `TmuxViewModel` follow the same shape with their own property sets.)

- [ ] **Step 2: Rewire `ConnectionViewModel` to own + delegate to the slices**

`ConnectionViewModel` holds `let core = SessionCoreModel()`, `let tmuxVM = TmuxViewModel()`, `let predictorVM = PredictorViewModel()`. Every former `self.<prop> = x` becomes `self.<slice>.set…(x)`. `refreshPredictorSuggestions`'s publish target becomes `self.predictorVM.setSuggestions(...)`.

- [ ] **Step 3: Point the views at their slice**

In each observing view, replace whole-VM observation with the specific slice (e.g. `PredictorStripView` takes `@ObservedObject var predictorVM: PredictorViewModel` instead of the whole `ConnectionViewModel`). `SessionView` composes the slices from the coordinator.

- [ ] **Step 4: Commit**

```bash
git add App/SessionCoreModel.swift App/TmuxViewModel.swift App/PredictorViewModel.swift \
        App/ConnectionViewModel.swift App/SessionView.swift App/Keybar/
git commit -m "refactor(app): split ConnectionViewModel into SessionCore/Tmux/Predictor observable slices"
```

Verification (controller-coordinated): macOS CI compiles; on-device — typing updates only the predictor strip (not a full-screen redraw); window/pane changes update the tmux views; all existing behavior intact. This is the task most likely to need a fix loop; keep the diff reviewable.

---

## Self-Review

**1. Spec coverage (Plan B = spec §B1 split, §B2 fork, §B3 measurement):**
- §B2 fork (send-first + FIFO consumer + coalesce) → Tasks 1 (filter), 2 (coalescer), 3 (reorder), 4 (`PredictorActor` + coalesced publish). ✅
- §B3 measurement (`os_signpost` on keystroke path) → Task 5. ✅
- §B1 split (`SessionCoreModel`/`TmuxViewModel`/`PredictorViewModel`) → Task 6. ✅
- Grid-read constraint honored: the actor never touches `passwordDetector`; the echo oracle stays main-actor (Tasks 4 interface note + Global Constraints). ✅
- L1/L4a ordering preserved: per-call anchor unchanged (Task 3 leaves `anchor`/`settleLine` intact); per-line record moved to the actor's SERIAL mailbox (Task 4). ✅

**2. Placeholder scan:** Phase 1 tasks carry complete code + exact commands. Phase 2/3 tasks carry complete code for new files and exact edit shapes; where wiring is genuinely an implementer judgment call (slice ownership, `Task {}` hop placement) it is called out explicitly as such with the binding REQUIREMENT stated — not left as "TODO". No "handle edge cases"/"similar to Task N". ✅

**3. Type consistency:** `predictorScalars(_:) -> [Unicode.Scalar]` identical across Task 1 + Task 3. `SuggestionRefreshCoalescer(quietWindow:)` / `requestRefresh(at:)` / `isDue(at:)` identical across Task 2 + Task 4. `PredictorActor.record(_:echoConfirmed:optedOut:)` / `suggestions(forPrefix:after:)` identical across Task 4 + Task 6. `CommittedToken` / `LearnedState` / `PredictorEngine.suggestions(forPrefix:after:)` match the real Kit surface read from source. ✅

## Honesty note on testability

Phase 1 (Tasks 1–2) is real TDD, Linux-verified in ~2 min — the reusable *policy* of the fork. Phases 2–3 (Tasks 3–6) are App-tier: their only automated gate is the macOS CI Swift-6 compile (which for the actor boundary is a genuine `Sendable`/isolation check, not nothing), and their behavioral gate is a named on-device pass the controller coordinates. This is the irreducible floor — the iOS runtime cannot be exercised off-macOS (confirmed in the xtool evaluation). The plan pushes as much as honestly possible into Phase 1 rather than pretending Phase 2–3 have local tests.
