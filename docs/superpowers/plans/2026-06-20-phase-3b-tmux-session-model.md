# Phase 3b — tmux session/pane model Implementation Plan

**Status:** Complete — 17 tests green (`swift test`); model on `master`. Correctness review found no bugs.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Maintain the structural state (windows, pane-geometry trees, active window/pane, session identity, ended-state) of the attached tmux session by applying Phase-3a `ControlModeEvent`s.

**Architecture:** A pure value-type `TmuxSessionState` struct in `NeotildeKit` with `mutating func apply(_ event: ControlModeEvent)`. It owns structure only — terminal content stays in SwiftTerm. Lenient: events for unknown windows are ignored. A `PaneLayout.panes` helper flattens a layout tree to leaf panes for the renderer.

**Tech Stack:** Swift 6 (`NeotildeKit`, platform-agnostic), XCTest, run on Linux via `docker compose run --rm dev swift test`.

## Global Constraints

- Every source/test file begins with `// SPDX-FileCopyrightText: 2026 True Positive LLC` then `// SPDX-License-Identifier: GPL-3.0-only`.
- Spec of record: `docs/superpowers/specs/2026-06-20-tmux-session-model-design.md`.
- Placement: Swift in `Sources/NeotildeKit/Tmux/`. No Apple-only APIs (must compile + test on Linux). No `Observation`/SwiftUI — pure value type.
- Model is **structure only**; ignores `.output`, `.commandResult`, `.unknown`, `.malformed`, `.sessionsChanged`.
- Lenient: events referencing an unknown window are ignored (no crash, no synthesized window).
- All `TmuxSessionState` fields are `private(set)`; mutation only via `apply`.
- Public model types are `Equatable, Sendable`.
- Testing tier: **Core** (non-trivial state logic over already-validated input) — EP + lifecycle; every assertion checks exact state.
- Conventional commits; commit after every green step. Work on branch `feat/phase-3b-tmux-model`; squash-merge at the end.
- Consumes Phase-3a types verbatim: `ControlModeEvent`, `PaneID`, `WindowID`, `SessionID`, `PaneLayout`, `Geometry` (already on `master`).
- Test command (all tasks): `docker compose run --rm dev swift test --filter <TestClassName>`.

---

### Task 0: Branch

- [ ] **Step 1: Create the feature branch**

Run:
```bash
git checkout -b feat/phase-3b-tmux-model
```

---

### Task 1: `PaneLayout.panes` render helper

**Files:**
- Modify: `Sources/NeotildeKit/Tmux/PaneLayout.swift` (append an extension)
- Test: `Tests/NeotildeKitTests/PaneLayoutPanesTests.swift`

**Interfaces:**
- Consumes: existing `PaneLayout` (`.leaf`/`.columns`/`.rows`), `PaneID`, `Geometry`.
- Produces: `extension PaneLayout { public var panes: [(pane: PaneID, geometry: Geometry)] }` — depth-first flatten to leaf panes, in tree order.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/NeotildeKitTests/PaneLayoutPanesTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class PaneLayoutPanesTests: XCTestCase {
    func testSingleLeafFlattens() {
        let layout: PaneLayout = .leaf(PaneID(raw: 1), Geometry(w: 80, h: 24, x: 0, y: 0))
        let flat = layout.panes
        XCTAssertEqual(flat.count, 1)
        XCTAssertEqual(flat[0].pane, PaneID(raw: 1))
        XCTAssertEqual(flat[0].geometry, Geometry(w: 80, h: 24, x: 0, y: 0))
    }
    func testColumnsFlattenInOrder() {
        let layout: PaneLayout = .columns([
            .leaf(PaneID(raw: 1), Geometry(w: 40, h: 24, x: 0, y: 0)),
            .leaf(PaneID(raw: 2), Geometry(w: 39, h: 24, x: 41, y: 0)),
        ], Geometry(w: 80, h: 24, x: 0, y: 0))
        XCTAssertEqual(layout.panes.map(\.pane), [PaneID(raw: 1), PaneID(raw: 2)])
    }
    func testNestedFlattensDepthFirst() {
        let layout: PaneLayout = .columns([
            .leaf(PaneID(raw: 1), Geometry(w: 40, h: 24, x: 0, y: 0)),
            .rows([
                .leaf(PaneID(raw: 2), Geometry(w: 39, h: 12, x: 41, y: 0)),
                .leaf(PaneID(raw: 3), Geometry(w: 39, h: 11, x: 41, y: 13)),
            ], Geometry(w: 39, h: 24, x: 41, y: 0)),
        ], Geometry(w: 80, h: 24, x: 0, y: 0))
        XCTAssertEqual(layout.panes.map(\.pane),
                       [PaneID(raw: 1), PaneID(raw: 2), PaneID(raw: 3)])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose run --rm dev swift test --filter PaneLayoutPanesTests`
Expected: FAIL — `value of type 'PaneLayout' has no member 'panes'`.

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/NeotildeKit/Tmux/PaneLayout.swift`:

```swift
extension PaneLayout {
    /// Depth-first flatten to leaf panes with their geometry, for the renderer.
    public var panes: [(pane: PaneID, geometry: Geometry)] {
        switch self {
        case let .leaf(id, geo):
            return [(id, geo)]
        case let .columns(children, _), let .rows(children, _):
            return children.flatMap { $0.panes }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose run --rm dev swift test --filter PaneLayoutPanesTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/NeotildeKit/Tmux/PaneLayout.swift Tests/NeotildeKitTests/PaneLayoutPanesTests.swift
git commit -m "feat: add PaneLayout.panes depth-first flatten helper"
```

---

### Task 2: `TmuxSessionState` + window-lifecycle events

**Files:**
- Create: `Sources/NeotildeKit/Tmux/TmuxSessionState.swift`
- Test: `Tests/NeotildeKitTests/TmuxSessionStateTests.swift`

**Interfaces:**
- Consumes: `ControlModeEvent`, `WindowID`, `SessionID`, `PaneID`, `PaneLayout`.
- Produces:
  - `struct TmuxWindow: Equatable, Sendable` — `let id: WindowID`, `var name`, `var layout: PaneLayout?`, `var visibleLayout: PaneLayout?`, `var activePane: PaneID?`; memberwise-style `init(id:name:layout:visibleLayout:activePane:)` with defaults.
  - `struct TmuxSessionState: Equatable, Sendable` — `private(set)` fields `sessionID`, `sessionName`, `windows: [TmuxWindow]`, `activeWindow`, `ended`, `exitReason`; `init()`; `func window(_:) -> TmuxWindow?`; `mutating func apply(_:)`.
- This task implements the window-lifecycle cases (`windowAdd`/`windowClose`/`windowRenamed`/`windowPaneChanged`); all other event cases are a single no-op `break` here and are implemented in Task 3.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/NeotildeKitTests/TmuxSessionStateTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class TmuxSessionStateTests: XCTestCase {
    private func state(_ events: [ControlModeEvent]) -> TmuxSessionState {
        var s = TmuxSessionState()
        for e in events { s.apply(e) }
        return s
    }

    func testWindowAddAppendsInOrder() {
        let s = state([.windowAdd(WindowID(raw: 1)), .windowAdd(WindowID(raw: 2))])
        XCTAssertEqual(s.windows.map(\.id), [WindowID(raw: 1), WindowID(raw: 2)])
        XCTAssertEqual(s.window(WindowID(raw: 1))?.name, "")
    }
    func testWindowAddDedupes() {
        let s = state([.windowAdd(WindowID(raw: 1)),
                       .windowRenamed(WindowID(raw: 1), name: "shell"),
                       .windowAdd(WindowID(raw: 1))]) // second add must not reset
        XCTAssertEqual(s.windows.count, 1)
        XCTAssertEqual(s.window(WindowID(raw: 1))?.name, "shell")
    }
    func testWindowClose() {
        let s = state([.windowAdd(WindowID(raw: 1)), .windowAdd(WindowID(raw: 2)),
                       .windowClose(WindowID(raw: 1))])
        XCTAssertEqual(s.windows.map(\.id), [WindowID(raw: 2)])
    }
    func testWindowRenamed() {
        let s = state([.windowAdd(WindowID(raw: 1)),
                       .windowRenamed(WindowID(raw: 1), name: "logs")])
        XCTAssertEqual(s.window(WindowID(raw: 1))?.name, "logs")
    }
    func testWindowPaneChanged() {
        let s = state([.windowAdd(WindowID(raw: 1)),
                       .windowPaneChanged(WindowID(raw: 1), active: PaneID(raw: 5))])
        XCTAssertEqual(s.window(WindowID(raw: 1))?.activePane, PaneID(raw: 5))
    }
    func testEventsForUnknownWindowAreIgnored() {
        let s = state([.windowRenamed(WindowID(raw: 9), name: "ghost"),
                       .windowPaneChanged(WindowID(raw: 9), active: PaneID(raw: 1))])
        XCTAssertTrue(s.windows.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose run --rm dev swift test --filter TmuxSessionStateTests`
Expected: FAIL — `cannot find 'TmuxSessionState' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/NeotildeKit/Tmux/TmuxSessionState.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// One tmux window: a named pane-geometry tree with an active pane.
public struct TmuxWindow: Equatable, Sendable {
    public let id: WindowID
    public var name: String
    public var layout: PaneLayout?          // full window layout (nil until first %layout-change)
    public var visibleLayout: PaneLayout?   // what to render (differs when a pane is zoomed)
    public var activePane: PaneID?

    public init(id: WindowID, name: String = "", layout: PaneLayout? = nil,
                visibleLayout: PaneLayout? = nil, activePane: PaneID? = nil) {
        self.id = id
        self.name = name
        self.layout = layout
        self.visibleLayout = visibleLayout
        self.activePane = activePane
    }
}

/// Structural state of the single tmux session Neotilde is attached to. Mutated only
/// by applying control-mode events; terminal content lives elsewhere (SwiftTerm).
public struct TmuxSessionState: Equatable, Sendable {
    public private(set) var sessionID: SessionID?
    public private(set) var sessionName: String?
    public private(set) var windows: [TmuxWindow]
    public private(set) var activeWindow: WindowID?
    public private(set) var ended: Bool
    public private(set) var exitReason: String?

    public init() {
        sessionID = nil
        sessionName = nil
        windows = []
        activeWindow = nil
        ended = false
        exitReason = nil
    }

    /// The window with `id`, or nil if absent.
    public func window(_ id: WindowID) -> TmuxWindow? { windows.first { $0.id == id } }

    private func index(of id: WindowID) -> Int? { windows.firstIndex { $0.id == id } }

    /// Apply one control-mode event, updating structural state. Non-structural
    /// events and events for unknown windows are ignored.
    public mutating func apply(_ event: ControlModeEvent) {
        switch event {
        case let .windowAdd(w):
            if index(of: w) == nil { windows.append(TmuxWindow(id: w)) }
        case let .windowClose(w):
            windows.removeAll { $0.id == w }
            if activeWindow == w { activeWindow = nil }
        case let .windowRenamed(w, name):
            if let i = index(of: w) { windows[i].name = name }
        case let .windowPaneChanged(w, pane):
            if let i = index(of: w) { windows[i].activePane = pane }
        // Implemented in Task 3:
        case .layoutChange, .sessionChanged, .sessionWindowChanged, .exit,
             // Ignored (non-structural):
             .sessionsChanged, .output, .commandResult, .unknown, .malformed:
            break
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose run --rm dev swift test --filter TmuxSessionStateTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/NeotildeKit/Tmux/TmuxSessionState.swift Tests/NeotildeKitTests/TmuxSessionStateTests.swift
git commit -m "feat: add TmuxSessionState with window-lifecycle events"
```

---

### Task 3: layout, session/active, exit, and ignored events

**Files:**
- Modify: `Sources/NeotildeKit/Tmux/TmuxSessionState.swift` (replace the placeholder cases in `apply`)
- Test: `Tests/NeotildeKitTests/TmuxSessionStateTests.swift` (append cases)

**Interfaces:**
- Consumes: same Phase-3a types.
- Produces: full `apply` behavior — `layoutChange` sets `layout`+`visibleLayout`; `sessionChanged` sets `sessionID`+`sessionName`; `sessionWindowChanged` sets `activeWindow` when the session matches (or is unknown); `exit` sets `ended`+`exitReason`; `sessionsChanged`/`output`/`commandResult`/`unknown`/`malformed` remain no-ops.

- [ ] **Step 1: Write the failing test**

Append these methods to `final class TmuxSessionStateTests`:

```swift
    func testLayoutChangeStoresBothLayouts() {
        let full: PaneLayout = .columns([
            .leaf(PaneID(raw: 1), Geometry(w: 40, h: 24, x: 0, y: 0)),
            .leaf(PaneID(raw: 2), Geometry(w: 39, h: 24, x: 41, y: 0)),
        ], Geometry(w: 80, h: 24, x: 0, y: 0))
        let zoomed: PaneLayout = .leaf(PaneID(raw: 1), Geometry(w: 80, h: 24, x: 0, y: 0))
        let s = state([.windowAdd(WindowID(raw: 1)),
                       .layoutChange(WindowID(raw: 1), layout: full, visible: zoomed, flags: "Z")])
        XCTAssertEqual(s.window(WindowID(raw: 1))?.layout, full)
        XCTAssertEqual(s.window(WindowID(raw: 1))?.visibleLayout, zoomed)
    }
    func testLayoutChangeForUnknownWindowIgnored() {
        let leaf: PaneLayout = .leaf(PaneID(raw: 1), Geometry(w: 80, h: 24, x: 0, y: 0))
        let s = state([.layoutChange(WindowID(raw: 9), layout: leaf, visible: leaf, flags: "*")])
        XCTAssertTrue(s.windows.isEmpty)
    }
    func testSessionChangedSetsIdentity() {
        let s = state([.sessionChanged(SessionID(raw: 0), name: "neotilde-a3f7c2e9")])
        XCTAssertEqual(s.sessionID, SessionID(raw: 0))
        XCTAssertEqual(s.sessionName, "neotilde-a3f7c2e9")
    }
    func testSessionWindowChangedSetsActiveWindow() {
        let s = state([.sessionChanged(SessionID(raw: 0), name: "s"),
                       .windowAdd(WindowID(raw: 2)),
                       .sessionWindowChanged(SessionID(raw: 0), active: WindowID(raw: 2))])
        XCTAssertEqual(s.activeWindow, WindowID(raw: 2))
    }
    func testSessionWindowChangedForOtherSessionIgnored() {
        let s = state([.sessionChanged(SessionID(raw: 0), name: "s"),
                       .sessionWindowChanged(SessionID(raw: 7), active: WindowID(raw: 2))])
        XCTAssertNil(s.activeWindow)
    }
    func testClosingActiveWindowClearsActive() {
        let s = state([.sessionChanged(SessionID(raw: 0), name: "s"),
                       .windowAdd(WindowID(raw: 1)),
                       .sessionWindowChanged(SessionID(raw: 0), active: WindowID(raw: 1)),
                       .windowClose(WindowID(raw: 1))])
        XCTAssertNil(s.activeWindow)
        XCTAssertTrue(s.windows.isEmpty)
    }
    func testExitSetsEndedAndReason() {
        let s = state([.exit(reason: "lost server")])
        XCTAssertTrue(s.ended)
        XCTAssertEqual(s.exitReason, "lost server")
    }
    func testContentEventsCauseNoStructuralChange() {
        let s = state([.windowAdd(WindowID(raw: 1)),
                       .output(pane: PaneID(raw: 1), data: [0x68, 0x69]),
                       .commandResult(number: 1, outcome: .ok(["x"])),
                       .unknown(verb: "pause", raw: "%pause %0"),
                       .malformed(raw: "junk", reason: "x"),
                       .sessionsChanged])
        XCTAssertEqual(s, state([.windowAdd(WindowID(raw: 1))]))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose run --rm dev swift test --filter TmuxSessionStateTests`
Expected: FAIL — the new cases hit the no-op `break`, so e.g. `testSessionChangedSetsIdentity` finds `sessionID == nil`.

- [ ] **Step 3: Write minimal implementation**

Replace the `apply(_:)` method's placeholder block. The full method becomes:

```swift
    public mutating func apply(_ event: ControlModeEvent) {
        switch event {
        case let .windowAdd(w):
            if index(of: w) == nil { windows.append(TmuxWindow(id: w)) }
        case let .windowClose(w):
            windows.removeAll { $0.id == w }
            if activeWindow == w { activeWindow = nil }
        case let .windowRenamed(w, name):
            if let i = index(of: w) { windows[i].name = name }
        case let .windowPaneChanged(w, pane):
            if let i = index(of: w) { windows[i].activePane = pane }
        case let .layoutChange(w, layout, visible, _):
            if let i = index(of: w) {
                windows[i].layout = layout
                windows[i].visibleLayout = visible
            }
        case let .sessionChanged(s, name):
            sessionID = s
            sessionName = name
        case let .sessionWindowChanged(s, w):
            if sessionID == nil || sessionID == s { activeWindow = w }
        case let .exit(reason):
            ended = true
            exitReason = reason
        case .sessionsChanged, .output, .commandResult, .unknown, .malformed:
            break
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose run --rm dev swift test --filter TmuxSessionStateTests`
Expected: PASS (14 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/NeotildeKit/Tmux/TmuxSessionState.swift Tests/NeotildeKitTests/TmuxSessionStateTests.swift
git commit -m "feat: apply layout/session/exit events to TmuxSessionState"
```

---

### Task 4: Full-suite verification + merge

- [ ] **Step 1: Run the entire Swift suite**

Run: `docker compose run --rm dev swift test`
Expected: PASS — all NeotildeKit suites green (prior tests + the new `PaneLayoutPanes` and `TmuxSessionState` suites).

- [ ] **Step 2: Squash-merge to master**

```bash
git checkout master
git merge --squash feat/phase-3b-tmux-model
git commit -m "Merge feat/phase-3b-tmux-model: tmux session/pane model"
git branch -D feat/phase-3b-tmux-model
```

- [ ] **Step 3: Update docs**

Mark this plan **Complete** in its header; update the README status line to note Phase 3b (tmux session/pane model) is done with its test count. Commit as `docs: sync project docs`.

---

## Self-review notes

- **Spec coverage:** placement/representation (Task 2 value-type struct), state shape (Task 2 fields + `TmuxWindow`), `apply` table all rows (Task 2 window cases; Task 3 layout/session/exit/ignored), insertion ordering (Task 2 `windowAdd` append + test), `sessionWindowChanged` guard (Task 3), `window(_:)` lookup (Task 2), `PaneLayout.panes` (Task 1), lenient unknown-window ignore (Task 2/3 tests), zoomed `layout != visibleLayout` (Task 3 test), Core-tier exact-state assertions (every task). All spec sections map to a task.
- **Type consistency:** `TmuxSessionState`/`TmuxWindow` field names and `apply`/`window(_:)`/`index(of:)` signatures are identical across Tasks 2 and 3; `PaneLayout.panes` tuple labels (`pane`,`geometry`) match between Task 1 def and use.
- **Deferred (per spec):** command encoder, session controller/handshake, SwiftTerm/SwiftUI, multi-session, index-faithful ordering.
