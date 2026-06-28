<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Phase 3 Plan D — Context Detection + Mid-Session Crash Banner — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the per-pane foreground-process context state machine (engine + tmux signal + observable, no keybar UI yet) and the mid-session tmux-crash red banner with raw-shell recovery.

**Architecture:** Two independent deliverables sharing the repo's two-tier split.
- **Part A (context detection):** all decision logic is pure, `Sendable`, Linux-tested SemicolynKit (`PaneContextMachine` dwell SM, `PaneContextStore`, `PromotionRegistry`, the `list-panes` listing parser + encoder), mirroring the `tmuxLaunchDecision` pattern. A thin App-tier driver polls `pane_current_command` over the existing `tmux -CC` command channel (~1 Hz), feeds the store, and publishes a per-pane observable. **The keybar is the only future consumer; it is Phase 4 and out of scope here — Plan D commits the *wire*, not the visual** (mirrors "predictor engine done / UI pending").
- **Part B (crash banner):** a pure `classifyTmuxClosure` decision distinguishes a clean `%exit` from an unexpected `-CC` EOF; the App reuses the still-alive `Connection` to drop the user into a raw shell and shows the one non-auto-dismissing red banner in the app.

**Tech Stack:** Swift 6 (strict concurrency, `Sendable`), XCTest on the Linux fast loop; SwiftUI + the UniFFI `Connection`/`ShellSession` bridge for App-tier wiring (macOS-CI-validated only).

## Global Constraints

- **Two tiers, two test surfaces.** Pure logic lives in `Sources/SemicolynKit/` with XCTest and **no `import UIKit`/`SwiftUI`/`CryptoKit`**. App code (`App/`, anything `import SwiftUI`) does NOT compile on Linux and is validated only by the macOS CI job. Keep App tasks a thin wiring layer.
- **Specs are locked.** `docs/superpowers/specs/2026-06-14-context-detection-design.md` (context) and `docs/superpowers/specs/2026-06-14-degraded-mode-design.md` §"Mid-session tmux crash recovery" (banner). Do not re-decide locked points.
- **Dwell thresholds (verbatim):** engage **250 ms**, disengage **1500 ms**. Entry is short (intentional), exit is long (absorbs `:!ls`/`:sh` excursions).
- **Bundled v1 promotion list (verbatim, spec §11):** `vim`/`nvim` → `:` `*` `%`; `less`/`more`/`man` → `?` `<` `>`; `python`/`python3`/`ipython` → `:` `[` `]` `=`; `node` → same as python; `psql`/`mysql` → `\` `;`; `sqlite3` → `;` `.`; `redis-cli` → `:` `\`. (`htop`/`top`/`mc` are Fn-spec auto-engage, NOT symbol promotions — excluded here.)
- **Unknown process = silent fallback.** Neither bundled nor user-overridden → `engagedContext = null`, no hint/nag/prompt. **User override wins over bundled. Always.**
- **Crash banner is the documented exception to the transient-banner rule** — red, top of screen, persists until the user dismisses or acts. No auto-retry of `-CC`, no layout restoration, no "your work is safe" reassurance.
- **Every new source file carries the SPDX header** (`GPL-3.0-only`, © True Positive LLC); REUSE-compliant.
- **Conventional commits**, feature branch `feat/phase-3d-context-crash`, squash-merge to `main`.
- **Build/test commands:** `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <Suite>` for SemicolynKit; App tasks compile only on the macOS CI job.

---

## File Structure

**Part A — created (SemicolynKit, Linux-tested):**
- `Sources/SemicolynKit/Context/Promotion.swift` — `PromotionSlot`, `PromotionSet`, `PromotionRegistry` (+ `merge`, `bundledDefault`, Codable).
- `Sources/SemicolynKit/Context/PromotionCatalog.swift` — `load(userOverrideJSON:)` → merged registry + optional warning.
- `Sources/SemicolynKit/Context/PaneContextMachine.swift` — per-pane dwell state machine.
- `Sources/SemicolynKit/Context/PaneContextStore.swift` — `PaneID → machine`, prune, `context(for:)`.
- `Sources/SemicolynKit/Context/PaneCommandListing.swift` — pure parser for `list-panes` result lines.

**Part A — modified:**
- `Sources/SemicolynKit/Tmux/TmuxCommand.swift` — add `listPaneCommands()`.
- `App/TmuxRuntime.swift` — context store + ~1 Hz poll + observable callback (CI).
- `App/ConnectionViewModel.swift` — `@Published var paneContexts` (CI).

**Part B — created:**
- `Sources/SemicolynKit/Tmux/TmuxClosure.swift` — `classifyTmuxClosure(lifecycle:)` (Linux-tested).
- `App/CrashBanner.swift` — red, persistent banner (CI).

**Part B — modified:**
- `App/TmuxRuntime.swift` — expose `lifecycle`.
- `App/ConnectionViewModel.swift` — `crashBanner` state + reattach/start-new/dismiss + refined `-CC` EOF handling (CI).
- `App/SessionView.swift` — overlay `CrashBanner` (CI).

**Tests created:** `PromotionTests`, `PromotionCatalogTests`, `PaneContextMachineTests`, `PaneContextStoreTests`, `PaneCommandListingTests`, `TmuxClosureTests` under `Tests/SemicolynKitTests/`; `TmuxCommandTests` extended.

---

## Setup

- [ ] **Step 0: Branch**

```bash
cd <repo-root>
git checkout -b feat/phase-3d-context-crash
```

---

## Part A — Context Detection

### Task 1: Promotion model + catalog

**Files:**
- Create: `Sources/SemicolynKit/Context/Promotion.swift`
- Create: `Sources/SemicolynKit/Context/PromotionCatalog.swift`
- Test: `Tests/SemicolynKitTests/PromotionTests.swift`, `Tests/SemicolynKitTests/PromotionCatalogTests.swift`

**Interfaces:**
- Produces:
  - `struct PromotionSlot: Equatable, Sendable, Codable { let tap: String; let up: String?; let down: String? }`
  - `struct PromotionSet: Equatable, Sendable, Codable { let promote: [PromotionSlot] }`
  - `struct PromotionRegistry: Equatable, Sendable { let sets: [String: PromotionSet]; func set(for: String) -> PromotionSet?; var knownProcesses: Set<String>; static func merge(bundled:user:) -> PromotionRegistry; static let bundledDefault: PromotionRegistry }`
  - `enum PromotionCatalog { static func load(userOverrideJSON: Data?) -> (registry: PromotionRegistry, warning: String?) }`

- [ ] **Step 1: Write the failing tests**

`Tests/SemicolynKitTests/PromotionTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class PromotionTests: XCTestCase {
    func testBundledDefaultCoversSpecProcesses() {
        let reg = PromotionRegistry.bundledDefault
        // Every spec §11 process name is present.
        for name in ["vim", "nvim", "less", "more", "man", "python", "python3",
                     "ipython", "node", "psql", "mysql", "sqlite3", "redis-cli"] {
            XCTAssertNotNil(reg.set(for: name), "missing bundled set for \(name)")
        }
        // htop/top/mc are Fn-spec, NOT symbol promotions.
        XCTAssertNil(reg.set(for: "htop"))
        XCTAssertNil(reg.set(for: "top"))
    }

    func testBundledVimSlotsMatchSpec() {
        let vim = PromotionRegistry.bundledDefault.set(for: "vim")
        XCTAssertEqual(vim?.promote.map(\.tap), [":", "*", "%"])
        XCTAssertEqual(vim?.promote.first, PromotionSlot(tap: ":", up: ";", down: nil))
        XCTAssertEqual(vim?.promote.last, PromotionSlot(tap: "%", up: "^", down: "$"))
    }

    func testKnownProcessesIsKeySet() {
        let reg = PromotionRegistry(sets: ["vim": PromotionSet(promote: [PromotionSlot(tap: ":", up: nil, down: nil)])])
        XCTAssertEqual(reg.knownProcesses, ["vim"])
        XCTAssertNil(reg.set(for: "zsh"))
    }

    func testMergeUserOverrideWinsPerProcess() {
        let bundled = PromotionRegistry(sets: [
            "vim": PromotionSet(promote: [PromotionSlot(tap: ":", up: nil, down: nil)]),
            "psql": PromotionSet(promote: [PromotionSlot(tap: ";", up: nil, down: nil)]),
        ])
        let user = PromotionRegistry(sets: [
            "vim": PromotionSet(promote: [PromotionSlot(tap: "Z", up: nil, down: nil)]),  // overrides
            "jq": PromotionSet(promote: [PromotionSlot(tap: ".", up: nil, down: nil)]),    // new
        ])
        let merged = PromotionRegistry.merge(bundled: bundled, user: user)
        // User's whole set replaces the bundled one for vim.
        XCTAssertEqual(merged.set(for: "vim")?.promote.map(\.tap), ["Z"])
        // Untouched bundled entry survives.
        XCTAssertEqual(merged.set(for: "psql")?.promote.map(\.tap), [";"])
        // New user process is registered.
        XCTAssertEqual(merged.set(for: "jq")?.promote.map(\.tap), ["."])
    }
}
```

`Tests/SemicolynKitTests/PromotionCatalogTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class PromotionCatalogTests: XCTestCase {
    func testNilOverrideReturnsBundledNoWarning() {
        let (reg, warning) = PromotionCatalog.load(userOverrideJSON: nil)
        XCTAssertEqual(reg, PromotionRegistry.bundledDefault)
        XCTAssertNil(warning)
    }

    func testValidJSONOverrideDecodesAndMerges() throws {
        // Includes a backslash promotion to prove JSON escaping round-trips.
        let json = Data("""
        { "vim": { "promote": [ {"tap": "Z"} ] },
          "awk": { "promote": [ {"tap": "\\\\", "up": "|"} ] } }
        """.utf8)
        let (reg, warning) = PromotionCatalog.load(userOverrideJSON: json)
        XCTAssertNil(warning)
        XCTAssertEqual(reg.set(for: "vim")?.promote.map(\.tap), ["Z"])   // user wins
        XCTAssertEqual(reg.set(for: "awk")?.promote.first, PromotionSlot(tap: "\\", up: "|", down: nil))
        XCTAssertNotNil(reg.set(for: "psql"))   // untouched bundled entry survives
    }

    func testMalformedJSONFallsBackToBundledWithWarning() {
        let (reg, warning) = PromotionCatalog.load(userOverrideJSON: Data("{ not json".utf8))
        XCTAssertEqual(reg, PromotionRegistry.bundledDefault)   // never crash; full fallback
        XCTAssertNotNil(warning)                                // one-time inline warning surfaced
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PromotionTests`
Expected: FAIL — `cannot find 'PromotionRegistry' in scope`.

- [ ] **Step 3: Implement `Promotion.swift`**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// One promoted keybar slot: a primary `tap` char plus optional swipe-up /
/// swipe-down secondaries, following the existing per-slot interaction model.
public struct PromotionSlot: Equatable, Sendable, Codable {
    public let tap: String
    public let up: String?
    public let down: String?
    public init(tap: String, up: String? = nil, down: String? = nil) {
        self.tap = tap; self.up = up; self.down = down
    }
}

/// The ordered promotion entries a process contributes to the scrollable keybar.
public struct PromotionSet: Equatable, Sendable, Codable {
    public let promote: [PromotionSlot]
    public init(promote: [PromotionSlot]) { self.promote = promote }
}

/// Process-name → promotion set. The keybar (Phase 4) maps an engaged context to
/// its set; Plan D only needs `knownProcesses` to gate the state machine.
public struct PromotionRegistry: Equatable, Sendable {
    public let sets: [String: PromotionSet]
    public init(sets: [String: PromotionSet]) { self.sets = sets }

    /// The promotion set for `process`, or nil when neither bundled nor overridden.
    public func set(for process: String) -> PromotionSet? { sets[process] }

    /// Names with a promotion set — the only processes the state machine engages on.
    public var knownProcesses: Set<String> { Set(sets.keys) }

    /// Merge `user` over `bundled`: a user entry replaces the bundled set for that
    /// process **whole** (user wins, always); other bundled entries survive.
    public static func merge(bundled: PromotionRegistry, user: PromotionRegistry) -> PromotionRegistry {
        PromotionRegistry(sets: bundled.sets.merging(user.sets) { _, userSet in userSet })
    }

    /// The curated v1 list (context-detection spec §11). `htop`/`top`/`mc` are
    /// Fn-spec auto-engage, not symbol promotions, so they are intentionally absent.
    public static let bundledDefault: PromotionRegistry = {
        func s(_ slots: PromotionSlot...) -> PromotionSet { PromotionSet(promote: slots) }
        let editor = s(.init(tap: ":", up: ";"), .init(tap: "*", up: "#"), .init(tap: "%", up: "^", down: "$"))
        let pager = s(.init(tap: "?"), .init(tap: "<"), .init(tap: ">"))
        let repl = s(.init(tap: ":"), .init(tap: "[", up: "{"), .init(tap: "]", up: "}"), .init(tap: "=", up: "+"))
        let sqlMeta = s(.init(tap: "\\"), .init(tap: ";"))
        return PromotionRegistry(sets: [
            "vim": editor, "nvim": editor,
            "less": pager, "more": pager, "man": pager,
            "python": repl, "python3": repl, "ipython": repl, "node": repl,
            "psql": sqlMeta, "mysql": sqlMeta,
            "sqlite3": s(.init(tap: ";"), .init(tap: ".")),
            "redis-cli": s(.init(tap: ":"), .init(tap: "\\")),
        ])
    }()
}
```

- [ ] **Step 4: Implement `PromotionCatalog.swift`**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Resolves the active promotion registry: bundled defaults overlaid with an
/// optional advanced-user JSON override. A malformed override never crashes and
/// never partially applies — it falls back to bundled entirely and returns a
/// one-time warning string for the settings surface to show.
public enum PromotionCatalog {
    /// JSON shape: `{ "<process>": { "promote": [ {"tap","up?","down?"} ] } }`.
    public static func load(userOverrideJSON: Data?) -> (registry: PromotionRegistry, warning: String?) {
        guard let data = userOverrideJSON else { return (.bundledDefault, nil) }
        do {
            let user = try JSONDecoder().decode([String: PromotionSet].self, from: data)
            return (PromotionRegistry.merge(bundled: .bundledDefault, user: PromotionRegistry(sets: user)), nil)
        } catch {
            return (.bundledDefault, "Keybar promotion override file is invalid — using defaults.")
        }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PromotionTests --filter PromotionCatalogTests`
Expected: PASS (all).

- [ ] **Step 6: Commit**

```bash
git add Sources/SemicolynKit/Context/Promotion.swift Sources/SemicolynKit/Context/PromotionCatalog.swift Tests/SemicolynKitTests/PromotionTests.swift Tests/SemicolynKitTests/PromotionCatalogTests.swift
git commit -m "feat(context): promotion-set model + bundled catalog with user-override merge"
```

---

### Task 2: Per-pane context state machine

**Files:**
- Create: `Sources/SemicolynKit/Context/PaneContextMachine.swift`
- Test: `Tests/SemicolynKitTests/PaneContextMachineTests.swift`

**Interfaces:**
- Consumes: `PromotionRegistry.knownProcesses` (the `Set<String>` of gating names).
- Produces:
  - `struct PaneContextMachine: Equatable, Sendable { init(knownProcesses: Set<String>, engageDwell: TimeInterval = 0.25, disengageDwell: TimeInterval = 1.5); var engagedContext: String?; var currentProcess: String?; mutating func observe(_ process: String?, at now: TimeInterval) -> Bool }`
  - `observe` returns `true` iff `engagedContext` changed on that call. `process == nil` means the signal is unavailable. Time is injected (monotonic seconds); repeated `observe` with the same value advances the dwell — there is no separate timer.

- [ ] **Step 1: Write the failing tests** (`Tests/SemicolynKitTests/PaneContextMachineTests.swift`)

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class PaneContextMachineTests: XCTestCase {
    private func machine() -> PaneContextMachine {
        PaneContextMachine(knownProcesses: ["vim", "python", "less"])
    }

    // MARK: engage dwell (250ms) — boundary values
    func testEngageFiresAtThresholdNotBefore() {
        var m = machine()
        XCTAssertFalse(m.observe("vim", at: 0.0))     // candidate starts
        XCTAssertNil(m.engagedContext)
        XCTAssertFalse(m.observe("vim", at: 0.24))    // 0.24 < 0.25 → not yet
        XCTAssertNil(m.engagedContext)
        XCTAssertTrue(m.observe("vim", at: 0.25))     // 0.25 >= 0.25 → engage, change=true
        XCTAssertEqual(m.engagedContext, "vim")
    }

    func testCandidateChangeRestartsEngageTimer() {
        var m = machine()
        _ = m.observe("vim", at: 0.0)
        _ = m.observe("python", at: 0.1)             // restart with new candidate
        XCTAssertFalse(m.observe("python", at: 0.34)) // only 0.24 since restart
        XCTAssertNil(m.engagedContext)
        XCTAssertTrue(m.observe("python", at: 0.35))  // 0.25 since restart → engage python
        XCTAssertEqual(m.engagedContext, "python")
    }

    func testUnknownProcessNeverEngages() {
        var m = machine()
        XCTAssertFalse(m.observe("awk", at: 0.0))
        XCTAssertFalse(m.observe("awk", at: 10.0))
        XCTAssertNil(m.engagedContext)
        XCTAssertEqual(m.currentProcess, "awk")
    }

    // MARK: disengage dwell (1500ms) — boundary values
    func testDisengageFiresAtThresholdNotBefore() {
        var m = machine()
        _ = m.observe("vim", at: 0.0); _ = m.observe("vim", at: 0.25)   // engaged
        XCTAssertFalse(m.observe("zsh", at: 10.0))  // away from vim → disengage timer starts
        XCTAssertEqual(m.engagedContext, "vim")
        XCTAssertFalse(m.observe("zsh", at: 11.49)) // 1.49 < 1.5 → still engaged
        XCTAssertEqual(m.engagedContext, "vim")
        XCTAssertTrue(m.observe("zsh", at: 11.5))   // 1.5 >= 1.5 → disengage, change=true
        XCTAssertNil(m.engagedContext)
    }

    func testTransientExcursionCancelsDisengage() {
        var m = machine()
        _ = m.observe("vim", at: 0.0); _ = m.observe("vim", at: 0.25)
        XCTAssertFalse(m.observe("bash", at: 10.0))  // :!ls excursion
        XCTAssertFalse(m.observe("vim", at: 10.5))   // back before 1.5s → cancel, no change
        XCTAssertEqual(m.engagedContext, "vim")
        XCTAssertFalse(m.observe("vim", at: 30.0))   // stays engaged
        XCTAssertEqual(m.engagedContext, "vim")
    }

    func testUnavailableSignalDecaysToNil() {
        var m = machine()
        _ = m.observe("vim", at: 0.0); _ = m.observe("vim", at: 0.25)
        XCTAssertFalse(m.observe(nil, at: 10.0))     // signal lost → disengage timer
        XCTAssertTrue(m.observe(nil, at: 11.6))      // > 1.5s later → decays to nil
        XCTAssertNil(m.engagedContext)
    }

    func testSwitchToNewKnownAppSupersedesViaFasterEngage() {
        var m = machine()
        _ = m.observe("vim", at: 0.0); _ = m.observe("vim", at: 0.25)   // engaged vim
        XCTAssertFalse(m.observe("python", at: 10.0)) // away from vim AND python candidate
        XCTAssertTrue(m.observe("python", at: 10.26)) // engage (0.25) beats disengage (1.5)
        XCTAssertEqual(m.engagedContext, "python")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PaneContextMachineTests`
Expected: FAIL — `cannot find 'PaneContextMachine' in scope`.

- [ ] **Step 3: Implement `PaneContextMachine.swift`**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// One pane's context state machine (context-detection spec §"Per-pane state
/// machine"). Pure and time-injected: `observe(process:at:)` is the only input,
/// `now` is monotonic seconds, and repeated calls with the same reading advance
/// the dwell timers — there is no internal clock or timer. Asymmetric dwell:
/// entering an app is intentional (short 250 ms engage); leaving is often a
/// transient subprocess excursion (long 1500 ms disengage) that must not flap.
public struct PaneContextMachine: Equatable, Sendable {
    /// Latest `pane_current_command` reading (nil when the signal is unavailable).
    public private(set) var currentProcess: String?
    /// The process whose promotion set currently drives the keybar (or nil).
    public private(set) var engagedContext: String?

    private let knownProcesses: Set<String>
    private let engageDwell: TimeInterval
    private let disengageDwell: TimeInterval

    private var pendingEngage: String?
    private var pendingEngageSince: TimeInterval?
    private var disengageSince: TimeInterval?

    public init(knownProcesses: Set<String>,
                engageDwell: TimeInterval = 0.25,
                disengageDwell: TimeInterval = 1.5) {
        self.knownProcesses = knownProcesses
        self.engageDwell = engageDwell
        self.disengageDwell = disengageDwell
    }

    /// Feed the latest reading. Returns true iff `engagedContext` changed.
    @discardableResult
    public mutating func observe(_ process: String?, at now: TimeInterval) -> Bool {
        currentProcess = process
        let before = engagedContext

        // 1. Reading equals the engaged context: cancel any decay, drop candidate.
        if let engaged = engagedContext, process == engaged {
            disengageSince = nil
            pendingEngage = nil
            pendingEngageSince = nil
            return false
        }

        // 2. Reading is away from the engaged context: advance the disengage timer.
        if engagedContext != nil {
            if disengageSince == nil { disengageSince = now }
            if let since = disengageSince, now - since >= disengageDwell {
                engagedContext = nil
                disengageSince = nil
            }
        }

        // 3. Reading is a known app and not (yet) engaged: advance the engage timer.
        if let p = process, knownProcesses.contains(p), engagedContext != p {
            if pendingEngage != p { pendingEngage = p; pendingEngageSince = now }
            if let since = pendingEngageSince, now - since >= engageDwell {
                engagedContext = p
                pendingEngage = nil
                pendingEngageSince = nil
                disengageSince = nil
            }
        } else {
            pendingEngage = nil
            pendingEngageSince = nil
        }

        return engagedContext != before
    }
}
```

- [ ] **Step 4: Run to verify passing**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PaneContextMachineTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Context/PaneContextMachine.swift Tests/SemicolynKitTests/PaneContextMachineTests.swift
git commit -m "feat(context): per-pane dwell state machine (250ms engage / 1500ms disengage)"
```

---

### Task 3: Multi-pane context store

**Files:**
- Create: `Sources/SemicolynKit/Context/PaneContextStore.swift`
- Test: `Tests/SemicolynKitTests/PaneContextStoreTests.swift`

**Interfaces:**
- Consumes: `PaneContextMachine`, `PaneID`.
- Produces:
  - `struct PaneContextStore: Sendable { init(knownProcesses: Set<String>); mutating func observe(_ readings: [(PaneID, String)], at now: TimeInterval) -> Set<PaneID>; func context(for: PaneID) -> String? }`
  - `observe` applies one full `list-panes` snapshot: updates/creates a machine per reading, **prunes machines for panes absent from the snapshot** (closed panes), and returns the set of panes whose `engagedContext` changed. `context(for:)` reads a pane's engaged context immediately (focus changes need no re-debounce — the App reads the focused pane directly).

- [ ] **Step 1: Write the failing tests** (`Tests/SemicolynKitTests/PaneContextStoreTests.swift`)

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class PaneContextStoreTests: XCTestCase {
    private let p0 = PaneID(raw: 0)
    private let p1 = PaneID(raw: 1)

    func testPerPaneIndependentEngagement() {
        var store = PaneContextStore(knownProcesses: ["vim", "python"])
        _ = store.observe([(p0, "vim"), (p1, "python")], at: 0.0)
        let changed = store.observe([(p0, "vim"), (p1, "python")], at: 0.25)
        XCTAssertEqual(changed, [p0, p1])             // both crossed the 250ms threshold
        XCTAssertEqual(store.context(for: p0), "vim")
        XCTAssertEqual(store.context(for: p1), "python")
    }

    func testOnlyChangedPanesReported() {
        var store = PaneContextStore(knownProcesses: ["vim", "python"])
        _ = store.observe([(p0, "vim"), (p1, "zsh")], at: 0.0)
        let changed = store.observe([(p0, "vim"), (p1, "zsh")], at: 0.25)
        XCTAssertEqual(changed, [p0])                 // p1 (zsh, unknown) never engaged
        XCTAssertNil(store.context(for: p1))
    }

    func testClosedPaneIsPrunedAndForgotten() {
        var store = PaneContextStore(knownProcesses: ["vim"])
        _ = store.observe([(p0, "vim"), (p1, "vim")], at: 0.0)
        _ = store.observe([(p0, "vim"), (p1, "vim")], at: 0.25)
        XCTAssertEqual(store.context(for: p1), "vim")
        // p1 disappears from the snapshot → pruned.
        _ = store.observe([(p0, "vim")], at: 0.5)
        XCTAssertNil(store.context(for: p1))
        XCTAssertEqual(store.context(for: p0), "vim")
    }

    func testUnknownPaneContextIsNil() {
        let store = PaneContextStore(knownProcesses: ["vim"])
        XCTAssertNil(store.context(for: p0))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PaneContextStoreTests`
Expected: FAIL — `cannot find 'PaneContextStore' in scope`.

- [ ] **Step 3: Implement `PaneContextStore.swift`**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Holds one `PaneContextMachine` per live pane and applies whole `list-panes`
/// snapshots. The per-pane observable from the context-detection spec
/// ("`PaneState.currentContext`"); the keybar (Phase 4) is the only consumer.
public struct PaneContextStore: Sendable {
    private var machines: [PaneID: PaneContextMachine] = [:]
    private let knownProcesses: Set<String>

    public init(knownProcesses: Set<String>) { self.knownProcesses = knownProcesses }

    /// Apply one full snapshot of `(pane, pane_current_command)` readings. Creates
    /// a machine for new panes, prunes panes absent from the snapshot (closed),
    /// and returns the panes whose `engagedContext` changed this call.
    @discardableResult
    public mutating func observe(_ readings: [(PaneID, String)], at now: TimeInterval) -> Set<PaneID> {
        var changed: Set<PaneID> = []
        var live: Set<PaneID> = []
        for (pane, process) in readings {
            live.insert(pane)
            var machine = machines[pane] ?? PaneContextMachine(knownProcesses: knownProcesses)
            if machine.observe(process, at: now) { changed.insert(pane) }
            machines[pane] = machine
        }
        machines = machines.filter { live.contains($0.key) }   // prune closed panes
        return changed
    }

    /// The pane's engaged context, read immediately (no re-debounce on focus change).
    public func context(for pane: PaneID) -> String? { machines[pane]?.engagedContext }
}
```

- [ ] **Step 4: Run to verify passing**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PaneContextStoreTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Context/PaneContextStore.swift Tests/SemicolynKitTests/PaneContextStoreTests.swift
git commit -m "feat(context): multi-pane context store with snapshot apply + prune"
```

---

### Task 4: `list-panes` encoder + listing parser

**Files:**
- Modify: `Sources/SemicolynKit/Tmux/TmuxCommand.swift` (add `listPaneCommands()`)
- Create: `Sources/SemicolynKit/Context/PaneCommandListing.swift`
- Test: `Tests/SemicolynKitTests/TmuxCommandTests.swift` (extend), `Tests/SemicolynKitTests/PaneCommandListingTests.swift`

**Interfaces:**
- Produces:
  - `TmuxCommand.listPaneCommands() -> String` → `list-panes -a -F "#{pane_id} #{pane_current_command}"`.
  - `func parsePaneCommandListing(_ lines: [String]) -> [(PaneID, String)]` — splits each `%<n> <command>` line on the first space; skips lines with no valid `%N` pane token or no command.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/SemicolynKitTests/TmuxCommandTests.swift`:

```swift
    func testListPaneCommandsFormat() {
        XCTAssertEqual(TmuxCommand.listPaneCommands(),
                       "list-panes -a -F \"#{pane_id} #{pane_current_command}\"")
        // Framing-safe: never contains a raw newline/carriage return.
        XCTAssertFalse(TmuxCommand.listPaneCommands().contains("\n"))
        XCTAssertFalse(TmuxCommand.listPaneCommands().contains("\r"))
    }
```

`Tests/SemicolynKitTests/PaneCommandListingTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class PaneCommandListingTests: XCTestCase {
    func testParsesPaneIDAndCommand() {
        let parsed = parsePaneCommandListing(["%0 zsh", "%3 vim", "%12 python3"])
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed[0].0, PaneID(raw: 0)); XCTAssertEqual(parsed[0].1, "zsh")
        XCTAssertEqual(parsed[1].0, PaneID(raw: 3)); XCTAssertEqual(parsed[1].1, "vim")
        XCTAssertEqual(parsed[2].0, PaneID(raw: 12)); XCTAssertEqual(parsed[2].1, "python3")
    }

    func testCommandWithSpacesKeepsTail() {
        let parsed = parsePaneCommandListing(["%1 ruby script.rb"])
        XCTAssertEqual(parsed.first?.1, "ruby script.rb")  // only the first space splits
    }

    func testSkipsMalformedAndEmptyLines() {
        let parsed = parsePaneCommandListing(["", "garbage", "@7 notapane", "%2", "%4 bash"])
        // "" / "garbage" / "@7 …" (wrong sigil) / "%2" (no command) all rejected.
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.0, PaneID(raw: 4))
        XCTAssertEqual(parsed.first?.1, "bash")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PaneCommandListingTests --filter TmuxCommandTests`
Expected: FAIL — `type 'TmuxCommand' has no member 'listPaneCommands'` / `cannot find 'parsePaneCommandListing'`.

- [ ] **Step 3: Add the encoder** — insert into `TmuxCommand` in `Sources/SemicolynKit/Tmux/TmuxCommand.swift`, after `refreshClientSize`:

```swift
    /// List every pane across all windows as `<pane_id> <pane_current_command>`,
    /// one per line, for context detection. The format string is a constant (no
    /// interpolated input) and contains no `\n`/`\r`, so framing is never forgeable.
    public static func listPaneCommands() -> String {
        "list-panes -a -F \"#{pane_id} #{pane_current_command}\""
    }
```

- [ ] **Step 4: Implement `PaneCommandListing.swift`**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Parse the result lines of `TmuxCommand.listPaneCommands()` — each
/// `%<id> <pane_current_command>` — into `(PaneID, command)` pairs. Lines with no
/// valid `%N` token or no command are skipped (best-effort; never throws).
public func parsePaneCommandListing(_ lines: [String]) -> [(PaneID, String)] {
    var result: [(PaneID, String)] = []
    for line in lines {
        guard let spaceIdx = line.firstIndex(of: " ") else { continue }
        let token = line[line.startIndex..<spaceIdx]
        guard let pane = PaneID(token: token) else { continue }
        let command = String(line[line.index(after: spaceIdx)...])
        guard !command.isEmpty else { continue }
        result.append((pane, command))
    }
    return result
}
```

Note: `PaneID(token:)` is `init?(token: Substring)` in `TmuxIDs.swift` (file-internal `extension PaneID`). It is already `@testable`-visible to SemicolynKit; `parsePaneCommandListing` is in the same module so it can call it directly.

- [ ] **Step 5: Run to verify passing**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PaneCommandListingTests --filter TmuxCommandTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/SemicolynKit/Tmux/TmuxCommand.swift Sources/SemicolynKit/Context/PaneCommandListing.swift Tests/SemicolynKitTests/PaneCommandListingTests.swift Tests/SemicolynKitTests/TmuxCommandTests.swift
git commit -m "feat(context): list-panes command encoder + pane_current_command listing parser"
```

---

### Task 5: App wiring — poll the signal + publish the observable

**Files:**
- Modify: `App/TmuxRuntime.swift`
- Modify: `App/ConnectionViewModel.swift`

**Validation:** App tier — compiles/validates only on the macOS CI job. No Linux test.

**Interfaces:**
- Consumes: `PaneContextStore`, `parsePaneCommandListing`, `PromotionCatalog.bundledDefault` knownProcesses, `TmuxCommand.listPaneCommands`, the controller's `ResolvedCommand`/`CommandOutcome`.
- Produces on `TmuxRuntime`: `var onContextsChanged: (() -> Void)?`, `func paneContext(_ pane: PaneID) -> String?`; starts a ~1 Hz poll once attached. On `ConnectionViewModel`: `@Published private(set) var paneContexts: [PaneID: String]`.

- [ ] **Step 1: Extend `TmuxRuntime`** — add the context store, a tracked-write helper, the poll loop, and resolved-listing routing.

In `App/TmuxRuntime.swift`, add stored properties near the existing callbacks:

```swift
    /// Per-pane foreground-process context (context-detection spec). Updated by the
    /// ~1 Hz `list-panes` poll; the keybar (Phase 4) is the only future consumer.
    private var contextStore = PaneContextStore(
        knownProcesses: PromotionRegistry.bundledDefault.knownProcesses)
    /// Fired after a poll changed any pane's engaged context.
    var onContextsChanged: (() -> Void)?
    /// In-flight context-poll submission ids awaiting their result block.
    private var contextPollIDs: Set<UInt64> = []
    /// The repeating poll task; cancelled on teardown via `stop()`.
    private var pollTask: Task<Void, Never>?
```

Add a tracked submit + the poll lifecycle:

```swift
    /// Submit a command and return its correlation id (nil unless attached).
    @discardableResult
    private func writeTracked(_ line: String) -> UInt64? {
        guard let sub = controller.submit(line), let writer else { return nil }
        writer.enqueue(sub.wire)
        return sub.id
    }

    /// Begin polling `pane_current_command` once control mode is attached.
    func startContextPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let id = self.writeTracked(TmuxCommand.listPaneCommands()) {
                    self.contextPollIDs.insert(id)
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)   // ~1 Hz
            }
        }
    }

    /// Stop polling and release the channel (called on teardown).
    func stop() {
        pollTask?.cancel(); pollTask = nil
        writer?.finish(); writer = nil
    }

    /// The engaged context for `pane`, or nil.
    func paneContext(_ pane: PaneID) -> String? { contextStore.context(for: pane) }
```

In `ingest(_:)`, after the existing `if out.stateChanged { … }` line and before the lifecycle check, route any context-poll result into the store:

```swift
        for resolved in out.resolved where contextPollIDs.remove(resolved.id) != nil {
            if case .ok(let lines) = resolved.outcome {
                let now = ProcessInfo.processInfo.systemUptime
                if !contextStore.observe(parsePaneCommandListing(lines), at: now).isEmpty {
                    onContextsChanged?()
                }
            }
        }
```

- [ ] **Step 2: Expose the observable on `ConnectionViewModel`** — add the published property and wire it in `attachTmux`.

Add near the other `@Published` properties:

```swift
    /// Per-pane engaged context (process name) for the keybar (Phase 4). Empty in
    /// raw-PTY mode. Re-derived from the runtime whenever a poll changes a pane.
    @Published private(set) var paneContexts: [PaneID: String] = [:]
```

In `attachTmux(conn:)`, after `runtime.onStateChanged = { … }` and before `runtime.onExit = …`, add:

```swift
        runtime.onContextsChanged = { [weak self, weak runtime] in
            guard let self, let runtime else { return }
            var map: [PaneID: String] = [:]
            for pane in self.renderablePanes {
                if let ctx = runtime.paneContext(pane) { map[pane] = ctx }
            }
            self.paneContexts = map
        }
```

After `state = .shell` at the end of `attachTmux`, start the poll:

```swift
        runtime.startContextPolling()
```

In `teardown()`, stop the runtime and clear the observable. Replace `tmux = nil` with:

```swift
        tmux?.stop()
        tmux = nil
        paneContexts = [:]
```

- [ ] **Step 3: Push to the branch and let CI compile the App target**

```bash
git add App/TmuxRuntime.swift App/ConnectionViewModel.swift
git commit -m "feat(context): poll pane_current_command over -CC and publish per-pane context"
git push -u github feat/phase-3d-context-crash
```

Then watch the macOS job (the only signal that App code compiles):

```bash
gh run watch $(gh run list --branch feat/phase-3d-context-crash --limit 1 --json databaseId -q '.[0].databaseId')
```
Expected: `macos` job green. (`linux-rust` flaking on "sshd fixtures not reachable" is unrelated — `gh run rerun <id> --failed`.)

---

## Part B — Mid-Session Crash Banner

### Task 6: Closure classification (pure)

**Files:**
- Create: `Sources/SemicolynKit/Tmux/TmuxClosure.swift`
- Test: `Tests/SemicolynKitTests/TmuxClosureTests.swift`

**Interfaces:**
- Consumes: `TmuxLifecycle` (from `TmuxSessionController.swift`).
- Produces:
  - `enum TmuxClosureKind: Equatable, Sendable { case cleanExit(reason: String?); case crashed }`
  - `func classifyTmuxClosure(lifecycle: TmuxLifecycle) -> TmuxClosureKind` — `.exited` ⇒ `.cleanExit` (a `%exit` was seen: user/clean teardown); every other lifecycle ⇒ `.crashed` (the `-CC` channel hit EOF with no `%exit`).

- [ ] **Step 1: Write the failing tests** (`Tests/SemicolynKitTests/TmuxClosureTests.swift`)

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class TmuxClosureTests: XCTestCase {
    func testCleanExitCarriesReason() {
        XCTAssertEqual(classifyTmuxClosure(lifecycle: .exited(reason: "server exited")),
                       .cleanExit(reason: "server exited"))
        XCTAssertEqual(classifyTmuxClosure(lifecycle: .exited(reason: nil)),
                       .cleanExit(reason: nil))
    }

    func testEOFWhileAttachedIsCrash() {
        // Channel closed with no %exit while attached → crash.
        XCTAssertEqual(classifyTmuxClosure(lifecycle: .attached), .crashed)
    }

    func testEOFWhileAttachingIsCrash() {
        XCTAssertEqual(classifyTmuxClosure(lifecycle: .attaching), .crashed)
    }

    func testIdleClosureDefaultsToCrash() {
        // Defensive: a channel can't close before start in practice.
        XCTAssertEqual(classifyTmuxClosure(lifecycle: .idle), .crashed)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TmuxClosureTests`
Expected: FAIL — `cannot find 'classifyTmuxClosure' in scope`.

- [ ] **Step 3: Implement `TmuxClosure.swift`**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// How a `tmux -CC` control-mode channel ended (degraded-mode spec §"Mid-session
/// tmux crash recovery").
public enum TmuxClosureKind: Equatable, Sendable {
    /// A `%exit` was observed first — the user or server ended the session cleanly.
    case cleanExit(reason: String?)
    /// The channel hit EOF with no `%exit` — tmux died (OOM, `kill-server`, segfault).
    case crashed
}

/// Classify a `-CC` channel close from the controller lifecycle at EOF time. Only
/// `.exited` (a parsed `%exit`) is clean; any other state means the stream dropped
/// unexpectedly and we must offer crash recovery.
public func classifyTmuxClosure(lifecycle: TmuxLifecycle) -> TmuxClosureKind {
    if case .exited(let reason) = lifecycle { return .cleanExit(reason: reason) }
    return .crashed
}
```

- [ ] **Step 4: Run to verify passing**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TmuxClosureTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Tmux/TmuxClosure.swift Tests/SemicolynKitTests/TmuxClosureTests.swift
git commit -m "feat(tmux): classify -CC channel closure as clean exit vs crash"
```

---

### Task 7: Crash banner UI + recovery wiring

**Files:**
- Create: `App/CrashBanner.swift`
- Modify: `App/TmuxRuntime.swift` (expose `lifecycle`)
- Modify: `App/ConnectionViewModel.swift` (crash state + recovery handlers + refined EOF handling)
- Modify: `App/SessionView.swift` (overlay the banner)

**Validation:** App tier — macOS CI job only.

**Interfaces:**
- Consumes: `classifyTmuxClosure(lifecycle:)`, `TmuxLifecycle`, the retained `Connection`, `openRawShell(conn:)`, `attachTmux(conn:)`.
- Produces: `enum CrashBannerState { case tmuxEnded }`; `ConnectionViewModel.crashBanner: CrashBannerState?`, `func reattachTmux()`, `func startNewTmux()`, `func dismissCrashBanner()`; `TmuxRuntime.lifecycle: TmuxLifecycle`.

- [ ] **Step 1: Expose lifecycle on `TmuxRuntime`** — add to `App/TmuxRuntime.swift`:

```swift
    /// The controller's lifecycle, read when the channel closes to tell a clean
    /// `%exit` from a crash (degraded-mode spec).
    var lifecycle: TmuxLifecycle { controller.lifecycle }
```

- [ ] **Step 2: Implement `App/CrashBanner.swift`**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// The one banner that does NOT auto-dismiss (degraded-mode spec §"Mid-session
/// tmux crash recovery"): tmux died mid-session, the SSH transport is alive, and
/// the user is now on a fresh raw shell. Red, top of screen, persists until the
/// user picks an action or dismisses.
struct CrashBanner: View {
    let onReattach: () -> Void
    let onStartNew: () -> Void
    let onDismiss: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "xmark.octagon.fill")
                Text("tmux session ended — your shell is still running.").font(.caption).bold()
                Spacer()
            }
            HStack(spacing: 12) {
                Button("Reattach", action: onReattach).buttonStyle(.borderedProminent).tint(.white)
                Button("Start new tmux", action: onStartNew).buttonStyle(.bordered)
                Spacer()
                Button("Dismiss", action: onDismiss).buttonStyle(.plain)
            }
            .font(.caption)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .foregroundStyle(.white)
        .background(Color(theme.state.broken).opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
    }
}
```

- [ ] **Step 3: Add crash state + handlers to `ConnectionViewModel`**

Add the state enum (top-level in the file, or nested) and a published property:

```swift
    /// Set when tmux crashed mid-session and we dropped to a raw shell on the same
    /// connection. The crash banner persists until the user acts.
    @Published var crashBanner: CrashBannerState?
```

with, at file scope:

```swift
/// Crash-banner presentation state (degraded-mode spec). One case today.
enum CrashBannerState: Equatable { case tmuxEnded }
```

Refine the tmux exec-channel close handler. In `attachTmux(conn:)`, replace the existing:

```swift
        sink.onExit = { [weak self] exit in
            self?.state = .failed(exit.error ?? "Session closed")
        }
```

with a crash-aware version (capture `conn` and `runtime`):

```swift
        sink.onExit = { [weak self, weak runtime] exit in
            guard let self else { return }
            // A clean %exit is already handled by runtime.onExit (session ended).
            // An unexpected EOF while the connection is alive is a tmux crash:
            // drop to a raw shell on the same conn and raise the persistent banner.
            if let runtime, case .crashed = classifyTmuxClosure(lifecycle: runtime.lifecycle) {
                Task { await self.recoverFromTmuxCrash(conn: conn) }
            }
        }
```

Add the recovery + action handlers (new methods on the view model):

```swift
    /// Tmux crashed: reuse the live connection for a raw shell, then show the
    /// persistent crash banner. If the connection is also gone, surface a failure.
    private func recoverFromTmuxCrash(conn: Connection) async {
        tmux?.stop(); tmux = nil
        do {
            try await openRawShell(conn: conn)   // sets session/rawWriter, tmuxState=nil, state=.shell
            paneContexts = [:]
            crashBanner = .tmuxEnded
        } catch {
            state = .failed("tmux ended and the connection is no longer reachable.")
        }
    }

    /// Banner action — reattach control mode on the live connection. `-CC
    /// new-session -A` attaches to the server-side session if it survived, else
    /// creates a fresh one.
    func reattachTmux() {
        guard let conn = connection else { return }
        crashBanner = nil
        Task { try? await attachTmux(conn: conn) }
    }

    /// Banner action — start a fresh tmux. Same `-CC new-session -A` path; if the
    /// old session somehow survived this reattaches to it (acceptable for v1 —
    /// distinct fresh-session naming is a follow-up).
    func startNewTmux() {
        guard let conn = connection else { return }
        crashBanner = nil
        Task { try? await attachTmux(conn: conn) }
    }

    /// Banner action — stay in degraded raw-shell mode for the rest of the session.
    func dismissCrashBanner() { crashBanner = nil }
```

Note: `openRawShell` already sets `connection = conn`, so `connection` remains valid for the banner actions after recovery.

- [ ] **Step 4: Overlay the banner in `SessionView`** — in `App/SessionView.swift`, add a second `.overlay(alignment: .top)` on the tmux branch's `VStack` (the `if let tmuxState` block), after the existing `DegradedBanner` overlay, OR fold into it. Add below the degraded overlay closure:

```swift
                    .overlay(alignment: .top) {
                        if vm.crashBanner != nil {
                            CrashBanner(
                                onReattach: { vm.reattachTmux() },
                                onStartNew: { vm.startNewTmux() },
                                onDismiss: { vm.dismissCrashBanner() })
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .animation(.easeInOut, value: vm.crashBanner)
```

Because recovery sets `tmuxState = nil` (raw mode), also mirror the overlay on the `else` (raw `TerminalScreen`) branch so the banner shows after the drop-to-raw transition.

- [ ] **Step 5: Commit and validate on CI**

```bash
git add App/CrashBanner.swift App/TmuxRuntime.swift App/ConnectionViewModel.swift App/SessionView.swift
git commit -m "feat(tmux): mid-session crash banner with raw-shell recovery (reattach / start-new / dismiss)"
git push github feat/phase-3d-context-crash
gh run watch $(gh run list --branch feat/phase-3d-context-crash --limit 1 --json databaseId -q '.[0].databaseId')
```
Expected: `macos` job green.

---

## Wrap-up

- [ ] **Full SemicolynKit suite green**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: all existing tests + the new context/closure suites pass.

- [ ] **Update `TODO.md`** — flip the Phase 3 row to "Plans A+B+C+D done", move Plan D off "Next", and note context detection ships the *engine + signal + observable* (keybar visual consumption remains Phase 4). Commit `docs: mark Phase 3 Plan D (context detection + crash banner) done`.

- [ ] **Open the PR** to `github` `main` (squash-merge). Summarize: per-pane context state machine + `pane_current_command` poll + per-pane observable (no keybar UI yet); mid-session crash banner with raw-shell recovery.

---

## Self-Review notes

- **Spec coverage (context-detection):** per-pane SM + asymmetric dwell → Task 2; `pane_current_command` signal (polling fallback, spec-permitted) → Task 4/A5; bundled v1 list §11 + user-override-wins + malformed-fallback → Task 1; `PaneState.currentContext` observable → Task 3/A5; unknown-process silent fallback → Task 2 (`testUnknownProcessNeverEngages`); pane-focus immediate read → Task 3 `context(for:)`. **Out of scope (Phase 4):** keybar promoted-slot visual, engage/disengage animation, per-pane pin, global kill-switch — all keybar-UI, none committed by Plan D. The signal source choice is **polling** (works on tmux 3.0+; control-mode subscriptions are 3.2+; spec §"Acquisition" permits either).
- **Spec coverage (degraded-mode crash):** EOF-vs-`%exit` detection → Task 6; auto-drop to raw shell on same connection, no re-auth → Task 7 `recoverFromTmuxCrash`; persistent red banner with Reattach / Start-new / Dismiss → Task 7; no auto-retry / no layout restoration / no false reassurance → honored (manual actions only, fresh raw shell, honest copy).
- **Known v1 limitation:** Reattach and Start-new both use `-CC new-session -A`, so they converge if the server-side session survived. Distinct fresh-session naming is a deliberate follow-up, not a gap (crashes are rare; the spec offers both but our `-A` attach-or-create collapses them).
