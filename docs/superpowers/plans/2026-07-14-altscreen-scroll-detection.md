# Alt-screen scroll: detection reconcile + drag-swallow diagnosis, Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix alt-screen mode detection for tmux-CC panes attached into a pre-existing session (query `#{alternate_on}` at attach), and instrument the drag path so the next trace names the recognizer that swallows the drag.

**Architecture:** Two independent slices. (A) A pure tmux command encoder + reply parser (Kit, Linux-tested) feeds a one-time per-pane alt-screen override into `PaneModeTracker`, submitted via the existing attach-prime command channel and correlated via the existing reply FIFO. (B) App-tier drag-time recognizer-state logging that names the winning recognizer, changing no routing.

**Tech Stack:** Swift 6 (strict concurrency), SemicolynKit (Linux-tested via Docker `swift test`), App tier (macOS-CI-compiled only), XCTest.

## Global Constraints

- **Two tiers:** `Sources/SemicolynKit/` is pure, Linux-tested, no `import UIKit`/`SwiftUI`. `App/` is Apple-only, validated by macOS CI (NOT buildable locally).
- **SPDX header on every new source file:** `// SPDX-FileCopyrightText: 2026 True Positive LLC` + `// SPDX-License-Identifier: GPL-3.0-only`.
- **No em-dashes** in any generated output (code, comments, commits): use a colon, parentheses, or two sentences.
- **Conventional commits** (`feat:`/`fix:`/`docs:`/`test:`).
- **Tests must be real:** assert observable values, no tautologies; negative tests assert the specific failure.
- **Kit test command:** `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <Name>` (disable sandbox if the docker socket is blocked).
- **Command encoders return one line, no trailing newline, no `\n`/`\r` in the string** (framing safety, per `TmuxCommand` doc).
- **Branch:** `feat/altscreen-scroll-detection` off `main`.

---

### Task 1: `TmuxCommand.queryAlternateOn()` encoder

**Files:**
- Modify: `Sources/SemicolynKit/Tmux/TmuxCommand.swift` (add one static func near `listPaneCommands()` at line ~97)
- Test: `Tests/SemicolynKitTests/TmuxCommandTests.swift` (add a test; create the file only if it does not exist)

**Interfaces:**
- Produces: `TmuxCommand.queryAlternateOn() -> String` returning exactly `list-panes -a -F "#{pane_id} #{alternate_on}"`.

- [ ] **Step 1: Write the failing test**

Add to `Tests/SemicolynKitTests/TmuxCommandTests.swift` (if the file is new, prepend the SPDX header + `import XCTest` + `@testable import SemicolynKit` + `final class TmuxCommandTests: XCTestCase {}` wrapper):

```swift
func testQueryAlternateOnEncodesListPanesWithAltFormat() {
    // Exact wire form: all panes, format = "<pane_id> <alternate_on>".
    XCTAssertEqual(
        TmuxCommand.queryAlternateOn(),
        "list-panes -a -F \"#{pane_id} #{alternate_on}\"")
}

func testQueryAlternateOnHasNoNewlineFraming() {
    // Framing safety: the encoder output must never contain CR/LF.
    let cmd = TmuxCommand.queryAlternateOn()
    XCTAssertFalse(cmd.contains("\n"))
    XCTAssertFalse(cmd.contains("\r"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TmuxCommandTests`
Expected: FAIL, `queryAlternateOn` not a member of `TmuxCommand`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/SemicolynKit/Tmux/TmuxCommand.swift`, after `listPaneCommands()` (line ~99):

```swift
    /// List every pane across all windows as `<pane_id> <alternate_on>`, one per
    /// line, so the runtime can reconcile each pane's alternate-screen state at
    /// attach. tmux's `#{alternate_on}` is `1` on the alternate screen, else `0`.
    /// Needed because a `-CC` client attaching into a session whose app is already
    /// on the alternate screen never receives that app's `?1049h` (device trace
    /// 2026-07-14). Constant format string (no interpolated input) with no `\n`/`\r`,
    /// so framing can never be forged.
    public static func queryAlternateOn() -> String {
        "list-panes -a -F \"#{pane_id} #{alternate_on}\""
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TmuxCommandTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Tmux/TmuxCommand.swift Tests/SemicolynKitTests/TmuxCommandTests.swift
git commit -m "feat(tmux): queryAlternateOn encoder for per-pane alternate_on"
```

---

### Task 2: `parseAlternateOnListing` reply parser

**Files:**
- Create: `Sources/SemicolynKit/Tmux/AlternateOnListing.swift`
- Test: `Tests/SemicolynKitTests/AlternateOnListingTests.swift`

**Interfaces:**
- Consumes: `PaneID` (from `TmuxIDs.swift`: `public struct PaneID: Hashable, Sendable` with `public let raw: UInt32` and `init(raw:)`).
- Produces: `parseAlternateOnListing(_ lines: [String]) -> [(pane: PaneID, isAlt: Bool)]`. Each input line is `%<id> <0|1>`. Malformed lines are skipped (not fatal). `1` maps to `true`, `0` to `false`, any other flag value skips the line.

- [ ] **Step 1: Write the failing test**

Create `Tests/SemicolynKitTests/AlternateOnListingTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class AlternateOnListingTests: XCTestCase {
    // Alt-screen pane (flag 1) → true.
    func testParsesAltOnPane() {
        let r = parseAlternateOnListing(["%0 1"])
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].pane, PaneID(raw: 0))
        XCTAssertTrue(r[0].isAlt)
    }

    // Normal-screen pane (flag 0) → false. NOTE: the result tuple array is not
    // Equatable, so always assert on `.count` + individual fields, never `==` on the
    // whole array.
    func testParsesAltOffPane() {
        let r = parseAlternateOnListing(["%10 0"])
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].pane, PaneID(raw: 10))
        XCTAssertFalse(r[0].isAlt)
    }

    // Multiple panes, mixed states, preserved in order.
    func testParsesMultiplePanes() {
        let r = parseAlternateOnListing(["%0 1", "%4 0", "%6 1"])
        XCTAssertEqual(r.map { $0.pane }, [PaneID(raw: 0), PaneID(raw: 4), PaneID(raw: 6)])
        XCTAssertEqual(r.map { $0.isAlt }, [true, false, true])
    }

    // Malformed line (no flag) is skipped, valid lines still parsed.
    func testSkipsMalformedLine() {
        let r = parseAlternateOnListing(["%0 1", "garbage", "%4 0"])
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r.map { $0.pane }, [PaneID(raw: 0), PaneID(raw: 4)])
    }

    // Non-boolean flag value (e.g. 2) is skipped, not coerced.
    func testSkipsNonBooleanFlag() {
        XCTAssertEqual(parseAlternateOnListing(["%0 2"]).count, 0)
    }

    // Missing `%` prefix on the id is malformed → skipped.
    func testSkipsIdWithoutPercentPrefix() {
        XCTAssertEqual(parseAlternateOnListing(["0 1"]).count, 0)
    }

    // Empty reply → empty result (not a crash).
    func testEmptyReply() {
        XCTAssertEqual(parseAlternateOnListing([]).count, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter AlternateOnListingTests`
Expected: FAIL, `parseAlternateOnListing` not defined.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SemicolynKit/Tmux/AlternateOnListing.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Parses the reply to ``TmuxCommand/queryAlternateOn()``: each line is
/// `%<id> <0|1>` (pane id + `#{alternate_on}`). Returns one entry per WELL-FORMED
/// line, preserving order; malformed lines (missing `%`, non-numeric id, flag that
/// is neither `0` nor `1`) are skipped rather than fatal, because a control-mode
/// reply is untrusted external input. `1` = alternate screen (`true`), `0` = normal.
public func parseAlternateOnListing(_ lines: [String]) -> [(pane: PaneID, isAlt: Bool)] {
    var result: [(pane: PaneID, isAlt: Bool)] = []
    for line in lines {
        let parts = line.split(separator: " ")
        guard parts.count == 2 else { continue }
        guard parts[0].first == "%",
              let raw = UInt32(parts[0].dropFirst()) else { continue }
        let isAlt: Bool
        switch parts[1] {
        case "1": isAlt = true
        case "0": isAlt = false
        default: continue
        }
        result.append((pane: PaneID(raw: raw), isAlt: isAlt))
    }
    return result
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter AlternateOnListingTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Tmux/AlternateOnListing.swift Tests/SemicolynKitTests/AlternateOnListingTests.swift
git commit -m "feat(tmux): parseAlternateOnListing reply parser"
```

---

### Task 3: Submit `queryAlternateOn` at attach (controller prime)

**Files:**
- Modify: `Sources/SemicolynKit/Tmux/TmuxSessionController.swift:130-133` (the `justAttached` prime list)
- Test: `Tests/SemicolynKitTests/TmuxSessionControllerTests.swift` (add a test; the file exists)

**Interfaces:**
- Consumes: `TmuxCommand.queryAlternateOn()` (Task 1).
- Produces: `attachedPrimeCommands` on the just-attached `feed` output now includes `TmuxCommand.queryAlternateOn()` as a third entry.

- [ ] **Step 1: Write the failing test**

Add to `Tests/SemicolynKitTests/TmuxSessionControllerTests.swift`. First locate an existing test that drives the controller to `.attached` (search the file for `attachedPrimeCommands` or `listWindowsForLayout` to copy the attach-driving setup). Model the new test on it:

```swift
func testAttachPrimeIncludesAlternateOnQuery() {
    let c = TmuxSessionController()
    _ = c.start(sessionName: "semicolyn-test")
    // Drive to attached: feed the spontaneous attach block a real tmux emits.
    // (Reuse the exact bytes/pattern the neighboring attach test uses.)
    let out = c.feed(Array("\u{1B}P1000p%session-changed $0 test\n\u{1B}\\".utf8))
    XCTAssertTrue(out.attachedPrimeCommands.contains(TmuxCommand.queryAlternateOn()),
                  "attach prime must query alternate_on to reconcile pre-attach alt-screen")
}
```

If the exact attach-driving bytes differ in this codebase, copy them verbatim from the sibling `list-windows`/`refresh-client` prime test in the same file rather than inventing them.

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TmuxSessionControllerTests`
Expected: FAIL, `attachedPrimeCommands` lacks `queryAlternateOn()`.

- [ ] **Step 3: Write minimal implementation**

In `TmuxSessionController.swift`, change the prime list (currently at line 131-133):

```swift
        let prime = justAttached
            ? ["refresh-client -C 80x24",
               TmuxCommand.listWindowsForLayout(),
               TmuxCommand.queryAlternateOn()]
            : []
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TmuxSessionControllerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Tmux/TmuxSessionController.swift Tests/SemicolynKitTests/TmuxSessionControllerTests.swift
git commit -m "feat(tmux): query alternate_on among attach-prime commands"
```

---

### Task 4: `PaneModeTracker` alt-screen override

**Files:**
- Modify: `App/PaneModeTracker.swift`

> This is App-tier: it imports SwiftTerm (`Terminal`) and is validated by macOS CI, NOT `swift test`. No local test run. Keep the logic trivial so the compile-only gate is sufficient. The pure decision (`resolveMode`) is already Kit-tested; this only adds a dictionary override in front of one argument.

**Interfaces:**
- Consumes: `PaneID`, `resolveMode(isAltScreen:mouseReporting:)`.
- Produces:
  - `func setAltScreenOverride(for pane: PaneID?, isAlt: Bool, terminal: Terminal)`: records a one-time reconcile override, then recomputes.
  - `recompute(for:terminal:)` now uses `altOverride[pane] ?? terminal.isCurrentBufferAlternate`.
  - Override auto-clears the first time the live emulator flag for that pane disagrees with a prior live read (so a stale override cannot pin the pane).

- [ ] **Step 1: Add the override storage and setter**

In `App/PaneModeTracker.swift`, add a stored property beside `modes` (line ~20):

```swift
    // One-time attach reconcile: tmux's #{alternate_on} for a pane, used as the
    // `isAltScreen` input UNTIL the live emulator flag becomes trustworthy (see
    // `recompute`). Needed because a -CC client attaching into a pre-existing
    // alt-screen pane never sees its `?1049h` (device trace 2026-07-14).
    private var altOverride: [PaneID?: Bool] = [:]
    // Panes whose live `isCurrentBufferAlternate` we have observed at least once;
    // once observed, the override is retired for that pane.
    private var liveObserved: Set<PaneID?> = []
```

Add the setter near `forget(_:)` (line ~55):

```swift
    /// Record the attach-time alternate-screen truth for `pane` (from tmux's
    /// `#{alternate_on}`), to be used by `recompute` until the live emulator flag
    /// is observed. Then recompute so the override takes effect immediately.
    func setAltScreenOverride(for pane: PaneID?, isAlt: Bool, terminal: Terminal) {
        altOverride[pane] = isAlt
        liveObserved.remove(pane)
        recompute(for: pane, terminal: terminal)
    }
```

- [ ] **Step 2: Use the override in `recompute`**

Replace the body of `recompute(for:terminal:)` (lines 33-46) with:

```swift
    func recompute(for pane: PaneID?, terminal: Terminal) {
        let liveAlt = terminal.isCurrentBufferAlternate
        // Once we have seen the live flag turn true at least once, it is
        // trustworthy for this pane (we witnessed a `?1049` transition), so the
        // attach override retires. Until then, prefer the override if present.
        if liveAlt { liveObserved.insert(pane) }
        let isAlt = liveObserved.contains(pane) ? liveAlt : (altOverride[pane] ?? liveAlt)
        let next = resolveMode(isAltScreen: isAlt,
                               mouseReporting: terminal.mouseMode != .off)
        if modes[pane] != next {
            modes[pane] = next
            MainActor.assumeIsolated {
                DebugLog.shared.log(.gesture, "mode[\(pane.map { "%\($0.raw)" } ?? "raw")] -> \(next) (altSrc=\(liveObserved.contains(pane) ? "live" : (altOverride[pane] != nil ? "override" : "live")))")
                onChange(pane, next)
            }
        }
    }
```

Also clear the override in `forget(_:)` so a reused PaneID starts clean, add these two lines to the existing `forget`:

```swift
        altOverride[pane] = nil
        liveObserved.remove(pane)
```

- [ ] **Step 3: Compile-check reasoning (no local build)**

Confirm by reading: `Terminal` is already imported (SwiftTerm) at the top of the file; `PaneID` is `Hashable` so `PaneID?` is a valid dictionary key and `Set` member (already used by `modes`). No new imports. macOS CI is the compile gate.

- [ ] **Step 4: Commit**

```bash
git add App/PaneModeTracker.swift
git commit -m "feat(terminal): PaneModeTracker attach-time alternate-screen override"
```

---

### Task 5: Wire the query reply → override in the runtime

**Files:**
- Modify: `App/TmuxRuntime.swift` (prime-submit block ~100-108 and resolved-reply block ~109-139)
- Modify: `App/TmuxPaneContainer.swift` (add an `onAltScreenReconcile` callback that calls `PaneModeTracker.setAltScreenOverride`)

> App-tier: macOS-CI-compiled only. Mirror the EXISTING `primeWindowIDs` idiom exactly (insert id on submit, remove + parse on reply).

**Interfaces:**
- Consumes: `TmuxCommand.queryAlternateOn()`, `parseAlternateOnListing(_:)`, `PaneModeTracker.setAltScreenOverride(for:isAlt:terminal:)`.
- Produces: on the query reply, each `(pane, isAlt)` is delivered to a new `onAltScreenReconcile: ((PaneID, Bool) -> Void)?` callback the container wires to its `modeTracker` + that pane's live `Terminal`.

- [ ] **Step 1: Track the query submission id (submit block)**

In `TmuxRuntime.swift`, add a tracking set beside `primeWindowIDs` (search for its declaration, add alongside):

```swift
    /// In-flight `queryAlternateOn` submission ids awaiting their reply.
    private var altScreenQueryIDs: Set<Int> = []
```

In the `for cmd in out.attachedPrimeCommands` loop (line ~100), add a branch BEFORE the `else`:

```swift
            } else if cmd == TmuxCommand.queryAlternateOn() {
                if let id = writeTracked(cmd) { altScreenQueryIDs.insert(id); DebugLog.shared.log(.tmux, "tmux prime: sent alternate_on query (req \(id))") }
                else { DebugLog.shared.log(.tmux, "tmux prime: alternate_on writeTracked returned NIL") }
```

(Insert it so the chain reads `if cmd == listWindowsForLayout() { … } else if cmd == queryAlternateOn() { … } else { write(cmd) }`.)

- [ ] **Step 2: Handle the query reply (resolved block)**

In the `for resolved in out.resolved` loop (line ~109), add a branch in the `else if` chain (after the `primeWindowIDs` branch):

```swift
            } else if altScreenQueryIDs.remove(resolved.id) != nil {
                if case .ok(let lines) = resolved.outcome {
                    let entries = parseAlternateOnListing(lines)
                    DebugLog.shared.log(.tmux, "tmux alternate_on REPLY: panes=\(entries.count) alt=\(entries.filter { $0.isAlt }.map { "%\($0.pane.raw)" }.joined(separator: ","))")
                    for e in entries { onAltScreenReconcile?(e.pane, e.isAlt) }
                } else {
                    DebugLog.shared.log(.tmux, "tmux alternate_on REPLY: NOT .ok")
                }
```

- [ ] **Step 3: Declare the callback**

Near the other `on…` callbacks in `TmuxRuntime` (e.g. `onHistoryCaptured`), add:

```swift
    /// Called once per pane at attach with tmux's `#{alternate_on}` truth, so the
    /// mode tracker can reconcile a pane that was already on the alternate screen
    /// before this -CC client attached (device trace 2026-07-14).
    var onAltScreenReconcile: ((PaneID, Bool) -> Void)?
```

- [ ] **Step 4: Wire it in `TmuxPaneContainer`**

In `App/TmuxPaneContainer.swift`, where the runtime's other callbacks are assigned (search for `onHistoryCaptured =` or `onStateChanged =`), add:

```swift
                runtime.onAltScreenReconcile = { [weak coordinator] pane, isAlt in
                    guard let coordinator,
                          let view = coordinator.panes[pane] else { return }
                    coordinator.modeTracker.setAltScreenOverride(
                        for: pane, isAlt: isAlt, terminal: view.getTerminal())
                }
```

Match the exact `coordinator`/`panes`/`view` names used by the sibling callbacks in that file (they were confirmed present: `coordinator.panes[pane]` and `view.getTerminal()` are used elsewhere in this file).

- [ ] **Step 5: Commit**

```bash
git add App/TmuxRuntime.swift App/TmuxPaneContainer.swift
git commit -m "feat(terminal): reconcile pane alternate-screen from tmux query at attach"
```

---

### Task 6: Drag-time recognizer-state instrumentation (Bug B diagnosis)

**Files:**
- Modify: `App/TerminalGestureController.swift`

> App-tier: macOS-CI-compiled only. Pure observation, changes NO routing, disables nothing. Gated on `.gesture` logging (zero cost when off).

**Interfaces:**
- Produces: a `gr:winner <class> delegate=<class> state=<n>` log line naming whichever recognizer reaches `.began`/`.changed` during a drag on an `appOwnsInput` pane.

- [ ] **Step 1: Add a shared observation action**

In `App/TerminalGestureController.swift`, add a method that logs a recognizer's identity + state, and a helper to attach it to every non-ours recognizer when a drag is possible. Add near `handleScrollViewPan` (line ~230):

```swift
    /// Diagnostic (Bug B, device trace 2026-07-14): in `.appOwnsInput` our
    /// `handleScrollViewPan` never fires because a `delegate=nil` UIKit pan
    /// (`_UIDragAutoScrollGestureRecognizer` / SwiftTerm's lazy pan) appears to win
    /// the drag. This logs which recognizer actually transitions, so a device trace
    /// NAMES the winner before we disable it. Pure observation: no routing change.
    @objc private func observeRecognizerState(_ g: UIGestureRecognizer) {
        guard g.state == .began || g.state == .changed else { return }
        let cls = String(describing: type(of: g))
        let del = g.delegate.map { String(describing: type(of: $0)) } ?? "nil"
        DebugLog.shared.log(.gesture, "gr:winner \(cls) delegate=\(del) state=\(g.state.rawValue)")
    }

    /// Attach `observeRecognizerState` as an extra target on every recognizer on the
    /// view that is not one of ours, so any of them firing is logged. Idempotent per
    /// recognizer (UIKit ignores a duplicate identical target/action). Called when a
    /// pane enters `.appOwnsInput` (the only mode where the drag goes missing).
    private func observeStrayRecognizers(on view: TerminalView) {
        for gr in view.gestureRecognizers ?? [] where !ours.contains(gr) && gr !== view.panGestureRecognizer {
            gr.addTarget(self, action: #selector(observeRecognizerState(_:)))
        }
        // Also observe the inherited scroll pan itself, to confirm whether it (our
        // intended owner) begins or is pre-empted.
        view.panGestureRecognizer.addTarget(self, action: #selector(observeRecognizerState(_:)))
    }
```

- [ ] **Step 2: Trigger observation on entering `.appOwnsInput`**

Find where the controller learns the pane mode changed. The mount's `modeTracker.onChange` already flips `allowMouseReporting`/`isScrollEnabled`; the gesture controller reads mode via `callbacks.currentMode()`. The lightest hook: call `observeStrayRecognizers` from `handleScrollViewPan`'s `.began` (it already runs `disableStraySwiftTermPans`). Add one line in the `.began` case, right after `disableStraySwiftTermPans(on: view)`:

```swift
            if dragMode == .appOwnsInput { observeStrayRecognizers(on: view) }
```

Note: if `handleScrollViewPan.began` never fires (the exact symptom), this line will not run, and that ABSENCE is itself the confirming signal (the scroll pan is being pre-empted). To catch the pre-empting recognizer regardless, ALSO attach the observers once at install time. In `installOurRecognizers` (after `view.panGestureRecognizer.addTarget(self, action: #selector(handleScrollViewPan(_:)))`, line ~166), add:

```swift
        // Bug B diagnosis: observe every non-ours recognizer's state so a drag that
        // never reaches `handleScrollViewPan` still logs which recognizer won.
        observeStrayRecognizers(on: view)
```

- [ ] **Step 3: Compile-check reasoning (no local build)**

Confirm by reading: `ours`, `terminalView`, `view.panGestureRecognizer`, `view.gestureRecognizers` are all already referenced in this file; `UIGestureRecognizer.addTarget(_:action:)` and `.state.rawValue` are UIKit API. No new imports. macOS CI is the compile gate.

- [ ] **Step 4: Commit**

```bash
git add App/TerminalGestureController.swift
git commit -m "feat(terminal): drag-time recognizer-state trace to name the drag-swallower"
```

---

### Task 7: Full Kit suite + finalize

**Files:** none (verification + PR)

- [ ] **Step 1: Run the full Kit suite**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: all pass (prior 1190 + new TmuxCommand/AlternateOnListing/controller tests). If any pre-existing test broke, STOP and investigate before proceeding.

- [ ] **Step 2: Push and open the PR**

```bash
git push github feat/altscreen-scroll-detection
gh pr create --base main --head feat/altscreen-scroll-detection \
  --title "feat(terminal): alt-screen scroll detection reconcile + drag-swallow diagnosis" \
  --body "Implements docs/superpowers/specs/2026-07-14-altscreen-scroll-detection-design.md. Bug A (fix): query #{alternate_on} at attach to reconcile pre-attach alt-screen panes into appOwnsInput. Bug B (diagnose): drag-time recognizer-state trace names the delegate=nil pan swallowing the drag. Kit tested; App-tier via macOS CI; device re-trace is the acceptance gate."
```

- [ ] **Step 3: Wait for CI (all 4 jobs, macOS is the App-tier gate)**

The macOS job is the ONLY validation for the App-tier changes (Tasks 4-6). Do not merge until it is green.

---

## Acceptance (device, build after merge)

1. **Bug A fixed:** reconnect into a pre-existing session with an app already on the alternate screen (e.g. Claude) → syslog shows `tmux alternate_on REPLY: … alt=%0` and `mode[%0] -> appOwnsInput` (was `mouseReporting`).
2. **Bug B named:** drag on htop/vim (mode `appOwnsInput`) → syslog shows a `gr:winner <class> …` line identifying the recognizer that owns the drag. That class is the target of the follow-up disable fix.
