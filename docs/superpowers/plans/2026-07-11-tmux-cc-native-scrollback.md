<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# tmux -CC Native Scrollback (Spec A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each tmux `-CC` pane real, scrollable history by seeding it once from tmux via `capture-pane`, then letting SwiftTerm's native buffer accumulate live `%output` and scroll locally.

**Architecture:** A pure `capturePaneCommand(...)` builder (SemicolynKit) + a pure `PaneSeedState` ordering state machine (SemicolynKit, buffers `%output` during the seed window) + an App-tier `PaneHistorySeeder` that, on a pane's first render, sends the capture command through `TmuxRuntime`, feeds the returned history into the pane's SwiftTerm view before live output, and re-seeds on `%pause`/reconnect/resize. The capture response already arrives as a parsed `commandResult(.ok([String]))` block from the existing `ControlModeParser` — we reuse that, mirroring the existing window-prime correlation path (`primeWindowIDs`).

**Tech Stack:** Swift 6, XCTest, SwiftTerm (`feed()`), tmux 3.4 control mode.

## Global Constraints

- **Two-tier rule:** `Sources/SemicolynKit/` = pure logic, Linux-tested, `Sendable`, **no `import UIKit`/`SwiftUI`**. `App/` = Apple-only, validated only by the macOS CI job. — from `CLAUDE.md`.
- **SPDX header** on every new source file: `// SPDX-FileCopyrightText: 2026 True Positive LLC` / `// SPDX-License-Identifier: GPL-3.0-only`.
- **Tests are real** (`docs/superpowers/specs/2026-06-18-testing-standards-design.md`): EP + boundary; assert exact observable values; a negative test asserts the specific result.
- **Conventional commits**; one feature branch `feat/tmux-cc-scrollback`.
- **Linux test:** `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <Name>` (no host Swift; runs in `semicolyn-dev` Docker; disable sandbox if the Docker socket is blocked).
- **App-tier tasks are not Linux-buildable** — their gate is the macOS CI job on the PR, and on-device behavior is observable via the diagnostics stream (PR #79).
- **capture-pane flags (spec):** `capture-pane -p -e -S -<N> -t %<paneID>` — escapes preserved, **no `-J`**, **no `-a`**. `N` = `TerminalSettings.scrollbackLines` (default 5000; presets 1000/2000/5000/10000/`Int.max`). `Int.max` → whole-history shorthand `-S -`. `N == 0` → no command (skip seeding).
- **Ordering (spec):** `%output` for a pane that is mid-seed is buffered and flushed **in order after** the history; reseed clears the pane's scrollback first (no duplication).
- **Scope:** Spec A = scrollback core only. Mouse-gate, `clearSelection`, render-storm dedup, window-switch/pane-zoom gestures are **Spec B** — do NOT touch them here.

## File Structure

**New (SemicolynKit, Linux-tested):**
- `Sources/SemicolynKit/Tmux/CapturePaneCommand.swift` — pure `capturePaneCommand(paneID:lines:)` builder.
- `Sources/SemicolynKit/Tmux/PaneSeedState.swift` — pure per-pane seed/ordering state machine.
- `Tests/SemicolynKitTests/CapturePaneCommandTests.swift`, `Tests/SemicolynKitTests/PaneSeedStateTests.swift`

**New (App, macOS-CI-only):**
- `App/PaneHistorySeeder.swift` — orchestrates capture send/receive + SwiftTerm seeding + resync, per pane.

**Modified (App):**
- `App/TmuxRuntime.swift` — add a tracked `captureHistory(pane:lines:)` send + route capture responses (mirror `primeWindowIDs`); expose a `%pause`/`%continue`/reconnect hook for resync; route `%output` through the seeder.
- `App/TmuxPaneContainer.swift` — on a pane's first render (`installHalo`), kick the seeder; **remove** our custom scroll fighting (see Task 6) so SwiftTerm's native scroll owns the drag.

**Reused (no change):** `ControlModeParser` (already yields `commandResult(.ok([String]))` for a `%begin/%end` block), `ControlModeEvent.CommandOutcome`, `TerminalSettings.scrollbackLines`.

---

## Task 1: `capturePaneCommand` — command builder (pure, Linux)

**Files:**
- Create: `Sources/SemicolynKit/Tmux/CapturePaneCommand.swift`
- Test: `Tests/SemicolynKitTests/CapturePaneCommandTests.swift`

**Interfaces:**
- Consumes: `PaneID` (existing, `PaneID(raw: UInt32)`).
- Produces: `public func capturePaneCommand(paneID: PaneID, lines: Int) -> String?` — returns the control-mode command line (no trailing newline), or `nil` when `lines <= 0` (seeding disabled). For `lines == Int.max` emits the whole-history form `-S -`; otherwise `-S -<lines>`. Target token is `%<raw>`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/SemicolynKitTests/CapturePaneCommandTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Builder for the `capture-pane` history-seed command (escapes kept, no join).
final class CapturePaneCommandTests: XCTestCase {
    // EP: a normal line count → -S -<N>, escapes (-e), print (-p), pane target %<raw>.
    func testBuildsNormalCapture() {
        XCTAssertEqual(
            capturePaneCommand(paneID: PaneID(raw: 3), lines: 5000),
            "capture-pane -p -e -S -5000 -t %3")
    }

    // BVA: Int.max → whole-history shorthand `-S -` (no number).
    func testUnlimitedUsesWholeHistoryShorthand() {
        XCTAssertEqual(
            capturePaneCommand(paneID: PaneID(raw: 7), lines: Int.max),
            "capture-pane -p -e -S - -t %7")
    }

    // BVA: lines == 1 → -S -1.
    func testSingleLine() {
        XCTAssertEqual(
            capturePaneCommand(paneID: PaneID(raw: 0), lines: 1),
            "capture-pane -p -e -S -1 -t %0")
    }

    // Negative: lines == 0 → nil (seeding disabled), no command emitted.
    func testZeroLinesIsNil() {
        XCTAssertNil(capturePaneCommand(paneID: PaneID(raw: 3), lines: 0))
    }

    // Negative: negative lines → nil (defensive).
    func testNegativeLinesIsNil() {
        XCTAssertNil(capturePaneCommand(paneID: PaneID(raw: 3), lines: -10))
    }

    // No -J (join): the command must NOT contain -J (preserve tmux wrapping).
    func testNoJoinFlag() {
        let cmd = capturePaneCommand(paneID: PaneID(raw: 1), lines: 100) ?? ""
        XCTAssertFalse(cmd.contains("-J"), "capture must not join wrapped lines: \(cmd)")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter CapturePaneCommandTests`
Expected: FAIL — `cannot find 'capturePaneCommand' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/SemicolynKit/Tmux/CapturePaneCommand.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Build the tmux control-mode `capture-pane` command that seeds a pane's scrollback
/// history (spec: tmux -CC native scrollback). Flags: `-p` print to stdout, `-e`
/// preserve escape sequences (so colors/attributes survive), `-S -<N>` start N lines
/// back into history. **No `-J`** — keep tmux's real line wrapping so seeded history
/// matches the live buffer width. **No `-a`** — alt-screen history is out of scope.
/// `N == Int.max` uses tmux's whole-history shorthand `-S -`. Returns `nil` when
/// `lines <= 0` (seeding disabled). No trailing newline (the transport appends one).
public func capturePaneCommand(paneID: PaneID, lines: Int) -> String? {
    guard lines > 0 else { return nil }
    let start = (lines == Int.max) ? "-" : "-\(lines)"
    return "capture-pane -p -e -S \(start) -t %\(paneID.raw)"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter CapturePaneCommandTests`
Expected: PASS (all 6).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Tmux/CapturePaneCommand.swift Tests/SemicolynKitTests/CapturePaneCommandTests.swift
git commit -m "feat(tmux): capture-pane history-seed command builder (pure)"
```

---

## Task 2: `PaneSeedState` — seed/ordering state machine (pure, Linux)

**Files:**
- Create: `Sources/SemicolynKit/Tmux/PaneSeedState.swift`
- Test: `Tests/SemicolynKitTests/PaneSeedStateTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public struct PaneSeedState: Equatable, Sendable` with:
  - `public init()` — starts `.unseeded`.
  - `public var needsSeed: Bool` — true when `.unseeded` (the seeder should issue a capture).
  - `public mutating func beginSeeding()` — `.unseeded` → `.seeding` (call when the capture command is sent). Idempotent if already seeding.
  - `public mutating func onOutput(_ bytes: [UInt8]) -> [UInt8]` — routes live pane output: while `.seeding`, buffers `bytes` and returns `[]` (feed nothing yet); while `.seeded`, returns `bytes` (feed live); while `.unseeded`, buffers and returns `[]` (hold until first seed — output can precede the first render's capture).
  - `public mutating func completeSeed(history: [UInt8]) -> [UInt8]` — `.seeding`/`.unseeded` → `.seeded`; returns `history` followed by all buffered output, in arrival order (the caller feeds this after clearing scrollback). Clears the buffer.
  - `public mutating func resync()` — any state → `.unseeded` with an empty buffer (a fresh seed will follow).

- [ ] **Step 1: Write the failing tests**

Create `Tests/SemicolynKitTests/PaneSeedStateTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Ordering state machine that seeds a tmux pane's history before live output,
/// buffering %output that races the capture response.
final class PaneSeedStateTests: XCTestCase {
    // EP: fresh state needs a seed.
    func testFreshNeedsSeed() {
        let s = PaneSeedState()
        XCTAssertTrue(s.needsSeed)
    }

    // Output arriving before any seed is buffered (returns nothing to feed yet).
    func testOutputBeforeSeedIsBuffered() {
        var s = PaneSeedState()
        XCTAssertEqual(s.onOutput([1, 2]), [])
    }

    // Core ordering: history is fed FIRST, then buffered output in arrival order.
    func testCompleteSeedEmitsHistoryThenBufferedOutput() {
        var s = PaneSeedState()
        s.beginSeeding()
        XCTAssertEqual(s.onOutput([10]), [])       // buffered during seeding
        XCTAssertEqual(s.onOutput([11, 12]), [])   // buffered during seeding
        // history ++ o1 ++ o2
        XCTAssertEqual(s.completeSeed(history: [0, 1, 2]), [0, 1, 2, 10, 11, 12])
        XCTAssertFalse(s.needsSeed)
    }

    // After seeding, live output passes straight through.
    func testAfterSeedOutputPassesThrough() {
        var s = PaneSeedState()
        s.beginSeeding()
        _ = s.completeSeed(history: [])
        XCTAssertEqual(s.onOutput([9, 9]), [9, 9])
    }

    // Buffer is cleared after completeSeed (no replay on the next output).
    func testBufferClearedAfterSeed() {
        var s = PaneSeedState()
        s.beginSeeding()
        _ = s.onOutput([5])
        _ = s.completeSeed(history: [])   // flushes [5]
        XCTAssertEqual(s.onOutput([6]), [6])   // only the new byte, no [5] replay
    }

    // resync returns to needing a seed and drops any buffered output.
    func testResyncReturnsToUnseeded() {
        var s = PaneSeedState()
        s.beginSeeding()
        _ = s.completeSeed(history: [1])
        s.resync()
        XCTAssertTrue(s.needsSeed)
    }

    // A second seed (after resync) starts clean: buffered-during-second-seed output
    // flushes after the new history, with no first-seed leftovers.
    func testResyncThenReseedIsClean() {
        var s = PaneSeedState()
        s.beginSeeding()
        _ = s.completeSeed(history: [1, 2])
        s.resync()
        s.beginSeeding()
        _ = s.onOutput([7])
        XCTAssertEqual(s.completeSeed(history: [3, 4]), [3, 4, 7])   // no 1,2 leftovers
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PaneSeedStateTests`
Expected: FAIL — `cannot find 'PaneSeedState' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/SemicolynKit/Tmux/PaneSeedState.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Per-pane ordering state machine for tmux -CC history seeding. Ensures a pane's
/// captured history is fed to the terminal BEFORE any live `%output`, and that live
/// output racing the capture response is buffered and replayed in order after it.
///
/// Lifecycle: `.unseeded` → `beginSeeding()` → `.seeding` → `completeSeed(history:)`
/// → `.seeded`. `resync()` (on `%pause`/reconnect/resize) returns to `.unseeded` and
/// drops the buffer so a fresh capture reseeds cleanly.
public struct PaneSeedState: Equatable, Sendable {
    private enum Phase: Equatable { case unseeded, seeding, seeded }
    private var phase: Phase = .unseeded
    private var pending: [UInt8] = []

    public init() {}

    /// True while a capture is still needed (`.unseeded`). The seeder issues a
    /// `capture-pane` when this is true and then calls `beginSeeding()`.
    public var needsSeed: Bool { phase == .unseeded }

    /// Mark that a capture has been issued. Idempotent while already seeding.
    public mutating func beginSeeding() {
        if phase == .unseeded { phase = .seeding }
    }

    /// Route live pane output. Buffers (returns `[]`) until the pane is seeded; once
    /// seeded, returns the bytes for immediate feed.
    public mutating func onOutput(_ bytes: [UInt8]) -> [UInt8] {
        switch phase {
        case .seeded:
            return bytes
        case .unseeded, .seeding:
            pending.append(contentsOf: bytes)
            return []
        }
    }

    /// Complete the seed: returns `history` followed by all buffered output in arrival
    /// order (the caller clears scrollback, then feeds this), and clears the buffer.
    public mutating func completeSeed(history: [UInt8]) -> [UInt8] {
        let flush = history + pending
        pending.removeAll()
        phase = .seeded
        return flush
    }

    /// Return to `.unseeded` (a resync trigger). Drops any buffered output; the next
    /// capture reseeds from scratch.
    public mutating func resync() {
        phase = .unseeded
        pending.removeAll()
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter PaneSeedStateTests`
Expected: PASS (all 7).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Tmux/PaneSeedState.swift Tests/SemicolynKitTests/PaneSeedStateTests.swift
git commit -m "feat(tmux): PaneSeedState — history-before-live ordering (pure)"
```

---

## Task 3: Confirm the real capture-pane response framing (investigation, no code)

**Files:** none (produces a note the App tasks rely on).

**Why:** the spec's one open item — confirm how tmux 3.4 returns a `capture-pane` response over `-CC` so the App seeder joins the body correctly. From code review, `ControlModeParser` already turns a `%begin N … body … %end N` block into `commandResult(number: N, outcome: .ok([String]))` where the `[String]` is the verbatim body lines. We need to confirm: (a) the capture body arrives as that block's `.ok` lines, and (b) how to reconstruct feedable bytes from `[String]` lines (join with `\n`? do `-e` escapes survive as literal bytes in the lines?).

- [ ] **Step 1: Capture a real sample from the host**

Ask the user (or, if a tmux host is reachable, run) a real control-mode capture. The user pastes the raw bytes tmux sends for:
`capture-pane -p -e -S -50 -t %<somePane>`
issued inside a `tmux -CC` session with some colored scrollback. Look for the `%begin N`/`%end N` framing and whether body lines contain literal `\033[` escape bytes.

- [ ] **Step 2: Record the finding — CONFIRMED against a real tmux 3.4 host (2026-07-11)**

A real `capture-pane -p -e -S -50 -t captest | cat -v` returned:
```
^[[31mred line^[[39m
^[[32mgreen line^[[39m
plain line
<~35 trailing BLANK lines>
```
Confirmed:
- **Escapes pass through** (`-e` works): `^[[31m` = `ESC[31m`. tmux resets with `ESC[39m` (default-fg), not `ESC[0m` — SwiftTerm handles both. So body lines carry literal escape bytes; feed them as-is.
- **One screen row per body line**, `\n`-separable → the `[String]` block body joins with `"\n"`.
- **`capture-pane` pads with TRAILING BLANK LINES** to the full pane height (empty bottom rows are returned as blank lines). These are screen padding, NOT scrollback — feeding them as history would push real content up and leave a blank gap. **So: trim trailing blank/whitespace-only lines from the body before joining.** (This is why the reconstruction is a tested pure helper, Task 3 Step 3, not an inline join.)

- [ ] **Step 3: Add a pure `reconstructHistory` helper (Linux-tested)**

Because the reconstruction (join + trailing-blank trim) is real logic, make it pure and tested rather than inline App code. Add to `Sources/SemicolynKit/Tmux/CapturePaneCommand.swift`:

```swift
/// Reconstruct feedable history bytes from a `capture-pane` control-block body. tmux
/// returns one screen row per line and pads the bottom of the pane with trailing blank
/// lines; those are screen padding, not scrollback, so they are trimmed. Remaining lines
/// are joined with "\n" (with a trailing "\n" if any content remains) and UTF-8 encoded.
/// Body lines carry literal escape sequences (`capture-pane -e`) which pass through
/// unchanged. Empty input → empty bytes.
public func reconstructHistory(fromLines lines: [String]) -> [UInt8] {
    var end = lines.count
    while end > 0, lines[end - 1].allSatisfy(\.isWhitespace) { end -= 1 }
    guard end > 0 else { return [] }
    return Array((lines[0..<end].joined(separator: "\n") + "\n").utf8)
}
```

Add tests to `Tests/SemicolynKitTests/CapturePaneCommandTests.swift`:
```swift
    // Reconstruct: joins content lines with \n + trailing \n; escapes preserved.
    func testReconstructJoinsContentLines() {
        let out = reconstructHistory(fromLines: ["\u{1b}[31mred\u{1b}[39m", "plain"])
        XCTAssertEqual(out, Array("\u{1b}[31mred\u{1b}[39m\nplain\n".utf8))
    }

    // Trailing blank lines (capture-pane bottom padding) are trimmed.
    func testReconstructTrimsTrailingBlanks() {
        let out = reconstructHistory(fromLines: ["a", "b", "", "   ", ""])
        XCTAssertEqual(out, Array("a\nb\n".utf8))
    }

    // All-blank input → empty (no spurious newline).
    func testReconstructAllBlankIsEmpty() {
        XCTAssertEqual(reconstructHistory(fromLines: ["", "  "]), [])
    }

    // Empty input → empty.
    func testReconstructEmptyIsEmpty() {
        XCTAssertEqual(reconstructHistory(fromLines: []), [])
    }

    // Interior blank lines are KEPT (only trailing trimmed).
    func testReconstructKeepsInteriorBlanks() {
        let out = reconstructHistory(fromLines: ["a", "", "b"])
        XCTAssertEqual(out, Array("a\n\nb\n".utf8))
    }
```

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter CapturePaneCommandTests`
Expected: PASS (6 original + 5 new = 11).

- [ ] **Step 4: Commit**

```bash
git add Sources/SemicolynKit/Tmux/CapturePaneCommand.swift Tests/SemicolynKitTests/CapturePaneCommandTests.swift docs/superpowers/plans/2026-07-11-tmux-cc-native-scrollback.md
git commit -m "feat(tmux): reconstructHistory — join capture body + trim trailing blanks (pure)"
```

---

## Task 4: `TmuxRuntime` — send capture + route response + resync hook (App, macOS-CI-only)

> **Not Linux-buildable.** macOS CI is the gate; device via diagnostics.

**Files:**
- Modify: `App/TmuxRuntime.swift`

**Interfaces:**
- Consumes: `capturePaneCommand(paneID:lines:)` (Task 1); `writeTracked(_:) -> UInt64?`, the `for resolved in out.resolved { if <idSet>.remove(resolved.id) != nil { if case .ok(let lines) = resolved.outcome … } }` pattern (existing, see the `primeWindowIDs` path ~line 100).
- Produces (for `PaneHistorySeeder`/`TmuxPaneContainer` to call):
  - `func captureHistory(pane: PaneID, lines: Int) -> UInt64?` — builds+sends the capture command (tracked), remembers the id keyed to the pane, returns the correlation id (nil if disabled/not attached).
  - A callback `var onHistoryCaptured: ((PaneID, [UInt8]) -> Void)?` — fired when a capture response resolves, with the pane and the reconstructed history bytes (lines joined per Task 3).
  - A callback `var onPaneResync: ((PaneID) -> Void)?` or a broadcast `var onResyncAll: (() -> Void)?` — fired on `%pause`/`%continue` and on reconnect, so the seeder can mark panes unseeded. (Wire to whatever pause/reconnect signal the runtime already surfaces; if none exists yet, add a minimal hook where the control channel reports a gap.)

- [ ] **Step 1: Add the capture send + correlation map**

In `App/TmuxRuntime.swift`, near `contextPollIDs`/`primeWindowIDs`, add:
```swift
    /// Correlation ids for in-flight `capture-pane` history seeds, keyed to the pane.
    private var historyCaptureIDs: [UInt64: PaneID] = [:]
    /// Fired when a capture response resolves: (pane, reconstructed history bytes).
    var onHistoryCaptured: ((PaneID, [UInt8]) -> Void)?
```
And the send method (mirrors `startContextPolling`'s `writeTracked` usage):
```swift
    /// Send a `capture-pane` history seed for `pane` (N = scrollback setting). Tracks
    /// the correlation id so the response can be routed back. No-op / nil if seeding is
    /// disabled (lines <= 0) or not attached.
    func captureHistory(pane: PaneID, lines: Int) -> UInt64? {
        guard let cmd = capturePaneCommand(paneID: pane, lines: lines),
              let id = writeTracked(cmd) else { return nil }
        historyCaptureIDs[id] = pane
        DebugLog.shared.log("tmux capture: pane=%\(pane.raw) lines=\(lines) id=\(id)")
        return id
    }
```

- [ ] **Step 2: Route the capture response**

In the `for resolved in out.resolved { … }` loop (alongside the `contextPollIDs`/`primeWindowIDs` branches ~line 94-100), add a branch:
```swift
            } else if let pane = historyCaptureIDs.removeValue(forKey: resolved.id) {
                if case .ok(let lines) = resolved.outcome {
                    // Reconstruct feedable bytes: join body rows + trim capture-pane's
                    // trailing blank padding (see Task 3 — confirmed vs real tmux 3.4).
                    let bytes = reconstructHistory(fromLines: lines)
                    DebugLog.shared.log("tmux capture REPLY: pane=%\(pane.raw) lines=\(lines.count) bytes=\(bytes.count)")
                    onHistoryCaptured?(pane, bytes)
                } else {
                    DebugLog.shared.log("tmux capture REPLY: pane=%\(pane.raw) NOT .ok (capture errored)")
                    onHistoryCaptured?(pane, [])   // fail toward live-only
                }
            }
```

- [ ] **Step 3: Add a resync signal on pause/reconnect**

Add:
```swift
    /// Fired when a pane's history may be stale (%pause/%continue, reconnect, resize
    /// desync) — the seeder should mark affected panes unseeded and re-capture.
    var onResyncAll: (() -> Void)?
```
Fire `onResyncAll?()` where the runtime detects a control-mode gap / `%continue` / reconnect. If the parser surfaces `%pause`/`%continue` as an event, hook there; otherwise fire it from the reconnect path in the transport. (If neither hook exists cleanly, add a single call at the point the control channel re-attaches — reconnect is the highest-value resync trigger and is definitely reachable.)

- [ ] **Step 4: Verify (macOS CI)** — commit; the App-tier gate is Task 8.

- [ ] **Step 5: Commit**

```bash
git add App/TmuxRuntime.swift
git commit -m "feat(app): TmuxRuntime capture-pane send + response routing + resync hook"
```

---

## Task 5: `PaneHistorySeeder` — orchestrate seeding + SwiftTerm feed (App, macOS-CI-only)

> **Not Linux-buildable.** macOS CI is the gate; device via diagnostics.

**Files:**
- Create: `App/PaneHistorySeeder.swift`

**Interfaces:**
- Consumes: `PaneSeedState` (Task 2), `TmuxRuntime.captureHistory`/`onHistoryCaptured`/`onResyncAll` (Task 4), a per-pane `TerminalView` (SwiftTerm), `TerminalSettings.scrollbackLines`.
- Produces: `final class PaneHistorySeeder` with:
  - `init(runtime: TmuxRuntime, scrollbackLines: () -> Int, viewForPane: @escaping (PaneID) -> TerminalView?)`
  - `func paneDidAppear(_ pane: PaneID)` — call on a pane's first render: if `needsSeed`, send the capture and `beginSeeding()`.
  - `func routeOutput(_ pane: PaneID, _ bytes: [UInt8]) -> [UInt8]` — run pane output through its `PaneSeedState` (buffer during seed, else passthrough); the caller feeds the returned bytes.
  - internal: on `onHistoryCaptured(pane, history)`, `completeSeed`, clear the pane's scrollback, and `feed()` the flushed bytes; on `onResyncAll`, `resync()` all panes + re-`paneDidAppear` the visible ones.

- [ ] **Step 1: Implement**

Create `App/PaneHistorySeeder.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SwiftTerm
import SemicolynKit

/// Orchestrates tmux -CC history seeding for each pane: on first render, capture the
/// pane's scrollback from tmux and feed it into SwiftTerm BEFORE live output; buffer
/// `%output` that races the capture (via `PaneSeedState`); re-seed on resync.
@MainActor
final class PaneHistorySeeder {
    private let runtime: TmuxRuntime
    private let scrollbackLines: () -> Int
    private let viewForPane: (PaneID) -> TerminalView?
    private var states: [PaneID: PaneSeedState] = [:]

    init(runtime: TmuxRuntime,
         scrollbackLines: @escaping () -> Int,
         viewForPane: @escaping (PaneID) -> TerminalView?) {
        self.runtime = runtime
        self.scrollbackLines = scrollbackLines
        self.viewForPane = viewForPane

        runtime.onHistoryCaptured = { [weak self] pane, history in
            self?.applyHistory(pane, history)
        }
        runtime.onResyncAll = { [weak self] in
            self?.resyncAll()
        }
    }

    /// Call when a pane first renders. Issues the capture if the pane still needs one.
    func paneDidAppear(_ pane: PaneID) {
        var state = states[pane] ?? PaneSeedState()
        if state.needsSeed {
            if runtime.captureHistory(pane: pane, lines: scrollbackLines()) != nil {
                state.beginSeeding()
            }
        }
        states[pane] = state
    }

    /// Route live pane output through the seed state (buffer during seed, else feed).
    func routeOutput(_ pane: PaneID, _ bytes: [UInt8]) -> [UInt8] {
        var state = states[pane] ?? PaneSeedState()
        let out = state.onOutput(bytes)
        states[pane] = state
        return out
    }

    // MARK: Private

    private func applyHistory(_ pane: PaneID, _ history: [UInt8]) {
        var state = states[pane] ?? PaneSeedState()
        let flush = state.completeSeed(history: history)
        states[pane] = state
        guard let view = viewForPane(pane) else { return }
        clearScrollback(view)
        if !flush.isEmpty { view.feed(byteArray: flush[...]) }
    }

    private func resyncAll() {
        for pane in states.keys {
            var s = states[pane] ?? PaneSeedState()
            s.resync()
            states[pane] = s
        }
        // Re-capture panes that currently have a view (visible).
        for pane in states.keys where viewForPane(pane) != nil {
            paneDidAppear(pane)
        }
    }

    /// Clear SwiftTerm's scrollback so a (re)seed doesn't duplicate history. Uses the
    /// terminal reset that clears history without tearing the live screen.
    /// (Verify the exact SwiftTerm API on macOS CI — see Open items.)
    private func clearScrollback(_ view: TerminalView) {
        view.getTerminal().resetToInitialState()
    }
}
```

**Implementer note (macOS-CI-verify):** `resetToInitialState()` is the assumed SwiftTerm clear. If it clears too much (wipes the live screen) or doesn't exist, the correct call may be a scrollback-specific clear; verify on CI and adjust. Fallback: seed only at pane *creation* (before any live output), avoiding the need to clear at all for the first seed — reseed-on-resync then recreates the view. Reconstruction of `history` bytes from the `[String]` block is done in `TmuxRuntime` (Task 4) per the Task 3 framing note.

- [ ] **Step 2: Verify (macOS CI)** — commit; Task 8 gate.

- [ ] **Step 3: Commit**

```bash
git add App/PaneHistorySeeder.swift
git commit -m "feat(app): PaneHistorySeeder — seed tmux history before live output"
```

---

## Task 6: Wire the seeder into `ConnectionViewModel.attachTmux` + confirm native scroll (App, macOS-CI-only)

> **Not Linux-buildable.** macOS CI is the gate; device via diagnostics.
>
> **Re-scoped (2026-07-11):** the original plan targeted `TmuxPaneContainer.swift`, but the
> `TmuxRuntime`, the `%output`→feed closure (`runtime.onPaneBytes`), the `paneViews` map, and
> the pane-first-appears hook (`registerPane`) ALL live in `App/ConnectionViewModel.swift` —
> `TmuxPaneContainer` never sees the runtime. So the seeder is constructed and wired there.

**Files:**
- Modify: `App/ConnectionViewModel.swift`

**Interfaces:**
- Consumes: `PaneHistorySeeder(runtime:scrollbackLines:viewForPane:)` (Task 5); the existing
  `attachTmux(conn:)` (constructs `let runtime = TmuxRuntime(...)` ~line 789), the
  `runtime.onPaneBytes = { pane, bytes in … view.feed(byteArray: bytes[...]) }` closure
  (~line 800-816), the `paneViews: [PaneID: TerminalView]` map (~line 111), and
  `registerPane(_ pane:_ view:)` (~line 252, where a pane's view first appears).
- Produces: seeded panes; native scroll owns the drag.

- [ ] **Step 1: Hold a seeder + construct it in `attachTmux`**

Add a stored property near `private var tmux: TmuxRuntime?` (~line 153):
```swift
    /// Seeds each tmux pane's scrollback history (capture-pane) before live output.
    private var historySeeder: PaneHistorySeeder?
```
In `attachTmux(conn:)`, right after `let runtime = TmuxRuntime(...)` (~line 789) and before the
`onPaneBytes` closure, construct the seeder (a `TerminalSettings` source is already used at
pane registration — reuse the same settings the VM reads; if the VM holds
`AppStores.shared.terminalSettings`, read `.settings.scrollbackLines`):
```swift
        let seeder = PaneHistorySeeder(
            runtime: runtime,
            scrollbackLines: { AppStores.shared.terminalSettings.settings.scrollbackLines },
            viewForPane: { [weak self] pane in self?.paneViews[pane] })
        self.historySeeder = seeder
```
(Verify the exact `scrollbackLines` accessor on macOS CI — mirror how `registerPane`/the pane
setup already reads `scrollbackLines` in this file; if it comes from a different store, use
that. The value must be the same setting the local buffer is sized from.)

- [ ] **Step 2: Route `%output` through the seeder in `onPaneBytes`**

In the `runtime.onPaneBytes = { [weak self] pane, bytes in … }` closure (~line 800), wrap the
feed so output racing the seed is buffered. The current body feeds `view.feed(byteArray: bytes[...])`
for a visible pane; change the visible-pane branch to route first:
```swift
            if let view = self.paneViews[pane] {
                let toFeed = self.historySeeder?.routeOutput(pane, Array(bytes)) ?? Array(bytes)
                if !toFeed.isEmpty { view.feed(byteArray: toFeed[...]) }
            } else if self.renderablePanes.contains(pane) {
                self.pendingPaneBytes[pane, default: []].append(contentsOf: bytes)
            } else {
                return
            }
```
Leave the `passwordDetector.noteOutput(bytes)` call and the other branches unchanged (the
password gate still sees the raw bytes). `bytes` is an `ArraySlice<UInt8>`; `Array(bytes)`
converts for `routeOutput(_:[UInt8])`.

- [ ] **Step 3: Seed on a pane's first render (`registerPane`)**

In `registerPane(_ pane:_ view:)` (~line 252, where `paneViews[pane] = view` and any pending
bytes are flushed), call the seeder AFTER the view is registered so `viewForPane` can find it:
```swift
        historySeeder?.paneDidAppear(pane)
```
Place it after `paneViews[pane] = view` and the existing pending-bytes flush. (The seeder's
`paneDidAppear` only issues a capture when the pane `needsSeed`, so re-registration is safe.)

- [ ] **Step 4: Confirm native scroll + add the post-seed diagnostic**

Native scroll ownership is already intact (Task 6 investigation confirmed: no `isScrollEnabled
= false`, no `contentOffset` manipulation in the tmux path; `handleScrollViewPan` only gates on
`mouseReportingActive()`). Do NOT change the gesture controller, the mouse gate, or
window-switch (Spec B). Add a diagnostic in `registerPane` (after `paneDidAppear`) so the device
trace confirms `contentSize` grows once history is fed:
```swift
        MainActor.assumeIsolated {
            DebugLog.shared.log("scroll:postseed pane=%\(pane.raw) contentSize=\(view.contentSize)")
        }
```
`registerPane` runs on the main actor already (it mutates `@MainActor` VM state); if the
compiler flags isolation, this `MainActor.assumeIsolated` wrap is harmless. (Log only
`contentSize` — the goal is to confirm it becomes non-zero after seeding.)

- [ ] **Step 5: Verify (macOS CI)** — commit; Task 8 gate.

- [ ] **Step 6: Commit**

```bash
git add App/ConnectionViewModel.swift
git commit -m "feat(app): wire PaneHistorySeeder into attachTmux (seed history before live output)"
```

---

## Task 7: Full Kit suite + branch hygiene

**Files:** none.

- [ ] **Step 1: Run the full Kit suite (pure tasks as a set)**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS — `CapturePaneCommandTests` (6) + `PaneSeedStateTests` (7) green; nothing else broken.

- [ ] **Step 2: Confirm the committed tree is clean**

Run: `git status`
Expected: clean (no uncommitted deletions/edits that would diverge committed-vs-working — the recurring CI trap).

---

## Task 8: Push, macOS CI, PR, device capture

**Files:** none.

- [ ] **Step 1: Push + PR**

```bash
git push github feat/tmux-cc-scrollback
gh pr create --repo ds7n/semicolyn --title "feat(tmux): native -CC scrollback via capture-pane seed" --body "Seeds each tmux -CC pane's history via capture-pane, then lets SwiftTerm's native buffer scroll it — matching iTerm2/WezTerm. Fixes the root cause (history lives server-side; %output is forward-only; contentSize was 0). Pure builder + ordering state machine (Linux-tested); App seeder + runtime wiring (macOS-CI + device). Spec A; gesture cleanup (mouse-gate/selection/render-storm) is Spec B.

https://claude.ai/code/session_01VxDe5tUsrrkhgX9SSADJPp"
```

- [ ] **Step 2: Wait for macOS CI (the App-tier gate)**

Run: `gh pr checks <PR#> --repo ds7n/semicolyn` until `macos` is `pass`. Fix any SwiftTerm API mismatch (esp. `resetToInitialState`/scrollback-clear, `buffer.linesCount`, `feed(byteArray:)`) and re-push.

- [ ] **Step 3: Merge + TestFlight + device capture**

After green + user approval: squash-merge, sync main, dispatch `release-testflight.yml`. On device, with diagnostics streaming on: connect to the tmux host, watch the trace for `tmux capture:` → `tmux capture REPLY:` → `scroll:postseed … contentSize=(non-zero)`, then confirm a finger drag scrolls history in a non-mouse pane.

---

## Self-Review

**Spec coverage:**
- capture-pane seed command (`-p -e -S -<N>`, no `-J`/`-a`, N from scrollbackLines, ∞→`-S -`, 0→nil) → Task 1. ✓
- history-before-live ordering + pending-output buffering + resync → Task 2 (`PaneSeedState`) + Task 5 (applies it). ✓
- lazy per-pane seed on first render → Task 5 `paneDidAppear` + Task 6 wiring. ✓
- capture send + response routing (reuse `commandResult(.ok([String]))`, mirror `primeWindowIDs`) → Task 4. ✓
- silent resync on %pause/%continue/reconnect/resize → Task 4 `onResyncAll` + Task 5 `resyncAll`. ✓
- reseed clears scrollback (no duplication) → Task 5 `clearScrollback`. ✓
- remove custom scroll fighting; native scroll owns drag → Task 6 step 3. ✓
- error/empty/malformed → fail toward live-only → Task 4 (non-`.ok` → `onHistoryCaptured(pane, [])`) + Task 5. ✓
- diagnostics on every seed/reseed → Task 4/6 `DebugLog` lines. ✓
- N from `TerminalSettings.scrollbackLines` → Task 5 `scrollbackLines()` closure. ✓
- confirm real capture framing → Task 3 (investigation). ✓
- testing: pure builder + ordering Linux-tested; App wiring + native scroll device → Tasks 1,2 (Linux) + Task 8 (CI/device). ✓

**Placeholder scan:** no "TBD"/"add error handling"/"similar to Task N". Implementer notes (SwiftTerm scrollback-clear API, `[String]`→bytes framing, resync hook point, line-count accessor) are genuine "verify the real signature on macOS CI / against a real capture" seams with stated fallbacks — not vague requirements.

**Type consistency:** `capturePaneCommand(paneID:lines:) -> String?` (Task 1) called in Task 4. `PaneSeedState` methods `needsSeed`/`beginSeeding`/`onOutput`/`completeSeed(history:)`/`resync` (Task 2) used in Task 5. `TmuxRuntime.captureHistory(pane:lines:)`/`onHistoryCaptured`/`onResyncAll` (Task 4) consumed in Task 5. `PaneHistorySeeder.paneDidAppear`/`routeOutput` (Task 5) called in Task 6. `PaneID(raw:)` (existing) used throughout. Consistent.
