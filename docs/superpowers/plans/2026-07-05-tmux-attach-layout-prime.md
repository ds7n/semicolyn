<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# tmux Attach-Time Layout Prime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When `tmux -CC` attaches to a session that emits no spontaneous window/layout events, the app proactively discovers the current windows so panes render (fixing the on-device blank-terminal + no-keyboard bug where the diagnostic read `wins=0 · layout=NO`).

**Architecture:** The pure `TmuxSessionController` detects the `.attaching → .attached` edge in `feed()` and returns two prime commands (`refresh-client -C 80x24` + a `list-windows` query). `TmuxRuntime` writes them, tracks the `list-windows` command id, and on its reply parses the window rows into synthesized `windowAdd`/`layoutChange`/`sessionWindowChanged` events fed back through `state.apply(...)` — so the renderer's guard (which needs an active window + visible layout) is satisfied and pane views (and the keyboard) appear.

**Tech Stack:** Swift 6 (SemicolynKit, Linux-tested via `swift test`; App tier macOS-CI-gated), XCTest.

## Global Constraints

- **Two tiers:** `Sources/SemicolynKit/` = pure logic, Swift 6 strict-concurrency, `Sendable`, NO `import UIKit`/`SwiftUI`, Linux-tested with `swift test`. `App/` = macOS-CI-only (invisible to `swift test`).
- **Every source file carries an SPDX header:** `// SPDX-FileCopyrightText: 2026 True Positive LLC` + `// SPDX-License-Identifier: GPL-3.0-only`.
- **Conventional commits**; feature branch `fix/tmux-attach-layout-prime` (already created, spec committed `dbc33c7`); squash-merge to `main`.
- **Tests must be real** (repo standards): equivalence-partitioning + boundary values, assert observable values (no tautologies), a negative test asserts the *specific* failure.
- **Kit test command (controller runs it; Docker socket is sandbox-blocked for subagents):**
  `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <Suite>`
  Implementer subagents must FLAG a Docker/tooling error, not misdiagnose it as a code bug; commit work regardless so the controller can verify.
- **App tier (Task 4) is macOS-CI-gated** — it does not compile under `swift test`; verify by reading + the macOS CI job.
- **Prime commands (exact strings):**
  - `refresh-client -C 80x24`
  - `list-windows -F "#{window_id} #{window_active} #{window_layout}"`

## Design deviation note (none)

The plan follows the spec exactly. The one spec choice made concrete: the controller **returns the prime command strings** on the attach edge (not a bare `justAttached` bool), and window/layout state is populated by **synthesizing events** through the existing `state.apply(_:)` path (single source of truth), not a bespoke mutator.

## File structure

**Kit (Linux-tested):**
- `Sources/SemicolynKit/Tmux/TmuxCommand.swift` — MODIFY: add `listWindowsForLayout()` (the `list-windows -F …` string).
- `Sources/SemicolynKit/Tmux/WindowListing.swift` — CREATE: `ParsedWindow` DTO + `parseWindowListing(_:)` (mirrors `parsePaneCommandListing`) + `windowListingEvents(_:)` (rows → `[ControlModeEvent]`).
- `Sources/SemicolynKit/Tmux/TmuxSessionController.swift` — MODIFY: add `attachedPrimeCommands: [String]` to `TmuxControllerOutput`; populate it once on the `.attaching → .attached` edge inside `feed()`.

**Tests (Linux-tested):**
- `Tests/SemicolynKitTests/WindowListingTests.swift` — CREATE (parse + events).
- `Tests/SemicolynKitTests/TmuxSessionControllerTests.swift` — extend (prime-on-edge) — or the file that already tests the controller; add there.

**App (macOS-CI-gated):**
- `App/TmuxRuntime.swift` — MODIFY: write the prime commands from `feed` output; track the `list-windows` id; on its `.ok(lines)` reply, apply `windowListingEvents` and fire `onStateChanged`.

> **Test-file naming:** SemicolynKitTests live at the ROOT of `Tests/SemicolynKitTests/` (NOT a `Tmux/` subdir). Verify with `ls Tests/SemicolynKitTests/ | grep -i <name>`; add to the existing controller-test file if one exists rather than duplicating a suite.

---

### Task 1: `TmuxCommand.listWindowsForLayout()`

**Files:**
- Modify: `Sources/SemicolynKit/Tmux/TmuxCommand.swift`
- Test: `Tests/SemicolynKitTests/TmuxCommandTests.swift` (add to the existing TmuxCommand test file; if none, create it with the SPDX header + `import XCTest` + `@testable import SemicolynKit`)

**Interfaces:**
- Produces: `TmuxCommand.listWindowsForLayout() -> String` returning exactly `list-windows -F "#{window_id} #{window_active} #{window_layout}"`.

- [ ] **Step 1: Write the failing test**

```swift
func testListWindowsForLayoutCommand() {
    XCTAssertEqual(TmuxCommand.listWindowsForLayout(),
                   "list-windows -F \"#{window_id} #{window_active} #{window_layout}\"")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TmuxCommandTests`
Expected: FAIL — `listWindowsForLayout` undefined (compile error).

- [ ] **Step 3: Write minimal implementation**

In `TmuxCommand.swift`, next to `listPaneCommands()`:

```swift
/// `list-windows` formatted for attach-time layout discovery: each row is
/// `<window_id> <window_active> <window_layout>` (e.g. `@0 1 abcd,80x24,0,0,0`).
/// Parsed by ``parseWindowListing(_:)`` when `-CC` attaches to a session that
/// emitted no spontaneous `%window-add`/`%layout-change`.
public static func listWindowsForLayout() -> String {
    "list-windows -F \"#{window_id} #{window_active} #{window_layout}\""
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TmuxCommandTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Tmux/TmuxCommand.swift Tests/SemicolynKitTests/TmuxCommandTests.swift
git commit -m "feat(tmux): listWindowsForLayout command for attach-time discovery"
```

---

### Task 2: `parseWindowListing` + `windowListingEvents`

**Files:**
- Create: `Sources/SemicolynKit/Tmux/WindowListing.swift`
- Test: `Tests/SemicolynKitTests/WindowListingTests.swift`

**Interfaces:**
- Consumes: `WindowID(token:)` (sigil `@`), `PaneLayout.parse(_:) -> PaneLayout?`, `ControlModeEvent` cases `windowAdd(WindowID)` / `layoutChange(WindowID, layout:visible:flags:)` / `sessionWindowChanged(SessionID, active:WindowID)`.
- Produces:
  - `public struct ParsedWindow: Equatable, Sendable { public let id: WindowID; public let active: Bool; public let layout: PaneLayout }`
  - `public func parseWindowListing(_ lines: [String]) -> [ParsedWindow]`
  - `public func windowListingEvents(_ windows: [ParsedWindow], sessionID: SessionID) -> [ControlModeEvent]`

- [ ] **Step 1: Write the failing tests**

Create `WindowListingTests.swift` (SPDX header + `import XCTest` + `@testable import SemicolynKit`):

```swift
func testParseSingleWindow() {
    let rows = ["@0 1 abcd,80x24,0,0,0"]
    let parsed = parseWindowListing(rows)
    XCTAssertEqual(parsed.count, 1)
    XCTAssertEqual(parsed[0].id, WindowID(raw: 0))
    XCTAssertTrue(parsed[0].active)
    XCTAssertEqual(parsed[0].layout, PaneLayout.parse("abcd,80x24,0,0,0"))
}

func testParseMultipleWindowsOneActive() {
    let rows = ["@0 0 abcd,80x24,0,0,0", "@1 1 abcd,80x24,0,0,1"]
    let parsed = parseWindowListing(rows)
    XCTAssertEqual(parsed.map(\.id), [WindowID(raw: 0), WindowID(raw: 1)])
    XCTAssertEqual(parsed.map(\.active), [false, true])
}

func testParseSkipsMalformedRows() {
    // Missing layout, bad window token, and a totally malformed line are skipped;
    // the one valid row survives.
    let rows = ["@0 1", "garbage", "notawindow 1 abcd,80x24,0,0,0", "@2 1 abcd,80x24,0,0,0"]
    let parsed = parseWindowListing(rows)
    XCTAssertEqual(parsed.map(\.id), [WindowID(raw: 2)])
}

func testWindowListingEventsSynthesizesAddLayoutAndActive() {
    let win = ParsedWindow(id: WindowID(raw: 3), active: true,
                           layout: PaneLayout.parse("abcd,80x24,0,0,0")!)
    let events = windowListingEvents([win], sessionID: SessionID(raw: 0))
    // A window-add + a layout-change for the window, and a session-window-changed
    // to the active one.
    XCTAssertTrue(events.contains(.windowAdd(WindowID(raw: 3))))
    XCTAssertTrue(events.contains(where: {
        if case let .layoutChange(w, _, _, _) = $0 { return w == WindowID(raw: 3) }
        return false
    }))
    XCTAssertTrue(events.contains(.sessionWindowChanged(SessionID(raw: 0), active: WindowID(raw: 3))))
}
```

> Confirm `PaneLayout.parse("abcd,80x24,0,0,0")` returns non-nil during Step 4 (the checksum `abcd` is 4 hex chars, then `WxH,X,Y,paneID`). If the sample layout string is rejected by the real parser, adjust it to a real tmux layout the parser accepts (check an existing `PaneLayoutTests` fixture for a known-good string) and update all rows consistently.

- [ ] **Step 2: Run tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter WindowListingTests`
Expected: FAIL — `ParsedWindow`/`parseWindowListing`/`windowListingEvents` undefined.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SemicolynKit/Tmux/WindowListing.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// One row of `TmuxCommand.listWindowsForLayout()` output, parsed.
public struct ParsedWindow: Equatable, Sendable {
    public let id: WindowID
    public let active: Bool
    public let layout: PaneLayout
    public init(id: WindowID, active: Bool, layout: PaneLayout) {
        self.id = id; self.active = active; self.layout = layout
    }
}

/// Parse `list-windows -F "#{window_id} #{window_active} #{window_layout}"` output:
/// each row is `@<n> <0|1> <layout>`. Best-effort — a row with a bad window token,
/// a non-`0|1` active flag, or an unparseable layout is skipped (never throws).
/// Mirrors ``parsePaneCommandListing(_:)``.
public func parseWindowListing(_ lines: [String]) -> [ParsedWindow] {
    var result: [ParsedWindow] = []
    for line in lines {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let id = WindowID(token: parts[0]),
              parts[1] == "0" || parts[1] == "1",
              let layout = PaneLayout.parse(parts[2]) else { continue }
        result.append(ParsedWindow(id: id, active: parts[1] == "1", layout: layout))
    }
    return result
}

/// Turn parsed windows into the control-mode events that populate
/// ``TmuxSessionState`` — a `windowAdd` + `layoutChange` per window, and a single
/// `sessionWindowChanged` to the active window (last active wins if several are
/// flagged). Feeding these through `state.apply(_:)` keeps all state mutation in
/// the one canonical path.
public func windowListingEvents(_ windows: [ParsedWindow], sessionID: SessionID) -> [ControlModeEvent] {
    var events: [ControlModeEvent] = []
    var active: WindowID?
    for w in windows {
        events.append(.windowAdd(w.id))
        events.append(.layoutChange(w.id, layout: w.layout, visible: w.layout, flags: ""))
        if w.active { active = w.id }
    }
    if let active { events.append(.sessionWindowChanged(sessionID, active: active)) }
    return events
}
```

> `WindowID(token:)` takes a `Substring`; `parts[0]` from `split` is a `Substring`, so it passes directly. `PaneLayout.parse` accepts `some StringProtocol`, so `parts[2]` (Substring) works.

- [ ] **Step 4: Run tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter WindowListingTests`
Expected: PASS. If a layout sample was rejected, fix the fixture (Step 1 note) and re-run.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Tmux/WindowListing.swift Tests/SemicolynKitTests/WindowListingTests.swift
git commit -m "feat(tmux): parseWindowListing + windowListingEvents (attach layout discovery)"
```

---

### Task 3: Controller emits prime commands on the attach edge

**Files:**
- Modify: `Sources/SemicolynKit/Tmux/TmuxSessionController.swift` (the `TmuxControllerOutput` struct + `feed()`)
- Test: `Tests/SemicolynKitTests/TmuxSessionControllerTests.swift` (add to the existing controller-test file; verify its name first)

**Interfaces:**
- Consumes: `TmuxCommand.listWindowsForLayout()` (Task 1).
- Produces: `TmuxControllerOutput.attachedPrimeCommands: [String]` — the commands to send when this `feed` crossed `.attaching → .attached`; empty otherwise, and empty on all subsequent feeds (fires once).

- [ ] **Step 1: Write the failing test**

Add to the controller test suite. Use the suite's existing helper for driving an attach (a controller + feeding a `%session-changed` line); if there's an existing "attaches on session-changed" test, mirror its setup.

```swift
func testFeedEmitsPrimeCommandsOnAttachEdgeOnce() {
    var controller = TmuxSessionController()
    // Before attach: no prime.
    let pre = controller.feed(Array("%begin 1 1\n%end 1 1\n".utf8))
    XCTAssertTrue(pre.attachedPrimeCommands.isEmpty)
    // The %session-changed that flips .attaching → .attached.
    let atEdge = controller.feed(Array("%session-changed $0 semicolyn\n".utf8))
    XCTAssertEqual(atEdge.attachedPrimeCommands,
                   ["refresh-client -C 80x24",
                    TmuxCommand.listWindowsForLayout()])
    // A later feed does NOT re-emit the prime.
    let after = controller.feed(Array("%window-add @0\n".utf8))
    XCTAssertTrue(after.attachedPrimeCommands.isEmpty)
}
```

> If `TmuxSessionController` is a `struct` (value type), the test must use `var controller` and the calls mutate in place — confirm `feed` is `mutating`. Adjust the `%begin/%end`/`%session-changed` wire lines to whatever the existing controller tests use as the canonical attach sequence (the exact framing matters to the parser).

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TmuxSessionControllerTests`
Expected: FAIL — `attachedPrimeCommands` is not a member of `TmuxControllerOutput`.

- [ ] **Step 3: Write minimal implementation**

In `TmuxSessionController.swift`, add the field to `TmuxControllerOutput` (with a default in the init so existing constructions still compile):

```swift
public struct TmuxControllerOutput: Equatable, Sendable {
    public var lifecycleChanged: Bool
    public var stateChanged: Bool
    public var resolved: [ResolvedCommand]
    public var paneOutput: [PaneOutputChunk]
    /// Commands the runtime must send because this feed attached control mode
    /// (`.attaching → .attached`). Empty except on that one edge — see the
    /// attach-layout-prime design.
    public var attachedPrimeCommands: [String]
    public init(lifecycleChanged: Bool, stateChanged: Bool,
                resolved: [ResolvedCommand], paneOutput: [PaneOutputChunk],
                attachedPrimeCommands: [String] = []) {
        self.lifecycleChanged = lifecycleChanged
        self.stateChanged = stateChanged
        self.resolved = resolved
        self.paneOutput = paneOutput
        self.attachedPrimeCommands = attachedPrimeCommands
    }
}
```

In `feed()`, compute the prime after the event loop, from the lifecycle edge:

```swift
        let justAttached = beforeLifecycle == .attaching && lifecycle == .attached
        let prime = justAttached
            ? ["refresh-client -C 80x24", TmuxCommand.listWindowsForLayout()]
            : []

        return TmuxControllerOutput(
            lifecycleChanged: lifecycle != beforeLifecycle,
            stateChanged: state != beforeState,
            resolved: resolved,
            paneOutput: paneOutput,
            attachedPrimeCommands: prime
        )
```

> The edge is `beforeLifecycle == .attaching && lifecycle == .attached`, so it can only be true on the single feed that flips it — subsequent feeds have `beforeLifecycle == .attached`, so `prime` is empty. No extra "already primed" flag needed. `TmuxLifecycle` is `Equatable`, so `== .attaching`/`== .attached` compile.

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TmuxSessionControllerTests`
Expected: PASS. Any other `TmuxControllerOutput(...)` construction in Kit still compiles (the new param has a default).

- [ ] **Step 5: Full Kit suite regression check**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS across the whole suite (no `TmuxControllerOutput` equality tests broken by the new field — if one compares an expected output literal, it now needs `attachedPrimeCommands: []`; fix any such test to include the default).

- [ ] **Step 6: Commit**

```bash
git add Sources/SemicolynKit/Tmux/TmuxSessionController.swift Tests/SemicolynKitTests/TmuxSessionControllerTests.swift
git commit -m "feat(tmux): emit attach-prime commands on the .attaching→.attached edge"
```

---

### Task 4: Runtime sends the prime + applies the list-windows reply

**Files:**
- Modify: `App/TmuxRuntime.swift`
- Verified by: **macOS CI** (App tier — not `swift test`).

**Interfaces:**
- Consumes: `TmuxControllerOutput.attachedPrimeCommands` (Task 3); `parseWindowListing` + `windowListingEvents` (Task 2); `TmuxCommand.listWindowsForLayout()` (Task 1). Existing `write(_:)`, `writeTracked(_:) -> UInt64?`, `controller.state`, `controller.apply(...)` — NOTE the controller applies events via `state.apply(_:)` internally; the runtime needs a way to feed synthesized events. If `controller` exposes no public `apply(event:)`, feed the events by re-encoding is NOT possible — instead add a minimal public `applyEvents(_ events: [ControlModeEvent])` to `TmuxSessionController` that runs `state.apply(_:)` for each and returns whether state changed. (Do this as part of THIS task; it is a 4-line pure addition mirroring `feed`'s inner loop. Add a Kit test for it in `TmuxSessionControllerTests`: applying `windowListingEvents(...)` yields `state.windows.count > 0` and a non-nil `visibleLayout` on the active window.)
- Produces: a runtime that, on attach, sends both prime commands and populates window/layout state from the `list-windows` reply.

- [ ] **Step 1: Add `TmuxSessionController.applyEvents` (Kit, TDD)**

Add to `TmuxSessionController` (near `feed`):

```swift
/// Apply externally-synthesized events (e.g. from a `list-windows` reply parsed
/// by ``windowListingEvents(_:sessionID:)``) through the same `state.apply(_:)`
/// path `feed` uses. Returns true if any changed structural state. Used by the
/// runtime to populate windows when tmux emitted none on attach.
public mutating func applyEvents(_ events: [ControlModeEvent]) -> Bool {
    let before = state
    for event in events { state.apply(event) }
    return state != before
}
```

Add the Kit test (in `TmuxSessionControllerTests`):

```swift
func testApplyEventsPopulatesWindowsAndLayout() {
    var controller = TmuxSessionController()
    let win = ParsedWindow(id: WindowID(raw: 0), active: true,
                           layout: PaneLayout.parse("abcd,80x24,0,0,0")!)
    let changed = controller.applyEvents(windowListingEvents([win], sessionID: SessionID(raw: 0)))
    XCTAssertTrue(changed)
    XCTAssertEqual(controller.state.windows.count, 1)
    XCTAssertEqual(controller.state.activeWindow, WindowID(raw: 0))
    XCTAssertNotNil(controller.state.window(WindowID(raw: 0))?.visibleLayout)
}
```

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TmuxSessionControllerTests` — verify it FAILS (undefined), implement, verify PASS. This is the **end-to-end proof of the fix** at the Kit layer: no spontaneous events, yet `windows>0` + `visibleLayout` after applying the reply. Commit:

```bash
git add Sources/SemicolynKit/Tmux/TmuxSessionController.swift Tests/SemicolynKitTests/TmuxSessionControllerTests.swift
git commit -m "feat(tmux): applyEvents to populate state from a list-windows reply"
```

- [ ] **Step 2: Wire the runtime (App tier — macOS-CI-verified)**

In `App/TmuxRuntime.swift`, add a set to track prime `list-windows` ids (mirror `contextPollIDs`):

```swift
/// In-flight `list-windows` (attach-prime) submission ids awaiting their reply.
private var primeWindowIDs: Set<UInt64> = []
```

In `ingest`, after the existing `feed` handling, send the prime commands and record the `list-windows` id. Add this inside `ingest`, after `if out.stateChanged { onStateChanged?(controller.state) }` and before the existing context-poll `for resolved` loop:

```swift
        // Attach-prime: on the .attaching→.attached edge the controller asks us to
        // discover the current windows (tmux emits none spontaneously on attach to
        // an existing session — the blank-panes bug). Send refresh-client (a nudge)
        // + a tracked list-windows whose reply we parse below.
        for cmd in out.attachedPrimeCommands {
            if cmd == TmuxCommand.listWindowsForLayout() {
                if let id = writeTracked(cmd) { primeWindowIDs.insert(id) }
            } else {
                write(cmd)
            }
        }
```

Extend the resolved-command handling to consume the `list-windows` reply. Modify the existing `for resolved in out.resolved` loop so it ALSO checks `primeWindowIDs`:

```swift
        for resolved in out.resolved {
            if contextPollIDs.remove(resolved.id) != nil {
                if case .ok(let lines) = resolved.outcome {
                    let now = ProcessInfo.processInfo.systemUptime
                    if !contextStore.observe(parsePaneCommandListing(lines), at: now).isEmpty {
                        onContextsChanged?()
                    }
                }
            } else if primeWindowIDs.remove(resolved.id) != nil {
                if case .ok(let lines) = resolved.outcome {
                    let events = windowListingEvents(parseWindowListing(lines),
                                                     sessionID: controller.state.sessionID ?? SessionID(raw: 0))
                    if controller.applyEvents(events) { onStateChanged?(controller.state) }
                }
            }
        }
```

> `controller.state.sessionID` — confirm the property name on `TmuxSessionState` (the spec/state uses `sessionID`/`sessionName`). If `sessionID` is not public/available, use `SessionID(raw: 0)`; `state.apply(.sessionWindowChanged(...))` only uses the active `WindowID` (see `TmuxSessionState`: `if sessionID == nil || sessionID == s { activeWindow = w }`), so a `raw: 0` fallback still sets `activeWindow` when the state's `sessionID` is nil. Prefer the real `sessionID` when available for exactness.
> Remove the OLD standalone `for resolved in out.resolved where contextPollIDs.remove(...)` loop — it is replaced by the combined loop above (do not leave both, or ids get double-consumed).

- [ ] **Step 3: Verify via macOS CI**

Commit, push, watch the macOS job (the only signal this App code compiles):
Run: `gh run watch <id>` after push. Expected: `macos` job green.

- [ ] **Step 4: Commit**

```bash
git add App/TmuxRuntime.swift
git commit -m "feat(app): send attach-prime + apply list-windows reply (tmux blank-panes fix)"
```

---

### Task 5: Full-branch verification

**Files:**
- Verified by: full Kit suite + macOS CI + on-device (the diagnostic overlay, kept from PR #48).

- [ ] **Step 1: Full Kit suite**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS, count ≥ prior + the new tests.

- [ ] **Step 2: Push + full CI**

Run: `git push -u github fix/tmux-attach-layout-prime` then open the PR:
`gh pr create --repo ds7n/semicolyn --fill --title "fix(tmux): attach-time layout prime — fixes blank panes / no keyboard"`
Expected: `linux-swift`, `lint`, `macos` green. If `linux-rust` flakes on `sshd fixtures not reachable`, rerun that job (`gh run rerun <id> --failed`) — the diff has no Rust.

- [ ] **Step 3: (after merge) TestFlight + on-device confirm**

Trigger the TestFlight lane on `main`; on device, connect and confirm the diagnostic overlay now reads `wins=1+ · layout=yes · panes=1+` (was `wins=0 · layout=NO`), the terminal renders, and the keyboard appears. Once confirmed, a FOLLOW-UP branch removes the diagnostic overlay (`onDiagnostic`, `tmuxDiag`, `emitDiagnostic`, the SessionView overlay).

---

## Self-review

**Spec coverage:**
- Prime on the `.attaching→.attached` edge, once → Task 3. ✓
- Both `refresh-client -C 80x24` + `list-windows` → Tasks 1, 3, 4. ✓
- Pure controller decides prime; runtime sends → Tasks 3, 4. ✓
- `parseWindowListing` (EP: single/multi/zoomed-via-layout/malformed) + synthesized events → Task 2. ✓
- Runtime tracks list-windows id + applies reply → Task 4. ✓
- End-to-end "no spontaneous events yet windows populate" test → Task 4 Step 1. ✓
- Re-attach uses same path → inherent (both go through `feed`'s edge). ✓
- Diagnostic overlay kept, removed in follow-up → Task 5 Step 3. ✓

**Placeholder scan:** no TBD/TODO; every code step shows code. The three "confirm the sample layout string / attach wire framing / sessionID property name" notes are grounding caveats with concrete fallbacks, not placeholders.

**Type consistency:** `ParsedWindow`/`parseWindowListing`/`windowListingEvents` names consistent Tasks 2→4. `attachedPrimeCommands` consistent Tasks 3→4. `listWindowsForLayout()` consistent Tasks 1→3→4. `applyEvents` consistent within Task 4. The `windowListingEvents` `layout:visible:flags:` matches the real `ControlModeEvent.layoutChange` signature (verified against `ControlModeEvent.swift`).
