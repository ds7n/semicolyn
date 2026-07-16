<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Decision-point Logging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make each gesture/alt-scroll decision emit ONE self-contained log line (inputs + output + reason) at the moment it decides, plus session/user-action markers, so a device trace reconstructs a session without narration.

**Architecture:** A pure `SemicolynKit` decider returns an `AltScrollDecision` value carrying its inputs + chosen keys + a derived reason; the App logs `decision.logLine` verbatim (truth-at-source, closes the caller-drift bug class). The gesture controller replaces its scattered `gr:*` lines with three self-contained drag lines (`drag-begin`/`drag-move`/`drag-end`). A reusable `decisionLine(...)` string helper ships in Kit (built + tested) for the later non-gesture sweep. Session + user-action markers land at the `.lifecycle` tier. `gesture` flips to default-OFF.

**Tech Stack:** Swift 6 (strict concurrency), XCTest, `SemicolynKit` (Linux-tested pure tier) + App tier (macOS-CI-only). Build/test via Docker `semicolyn-dev`.

## Global Constraints

- **Two tiers:** `Sources/SemicolynKit/` = pure, Linux-tested, Swift 6 `Sendable`, NO `import UIKit`/`SwiftUI`/`CryptoKit`/`DebugLog`. App tier compiles only on macOS CI.
- **SPDX header on every source file:** `// SPDX-FileCopyrightText: 2026 True Positive LLC` + `// SPDX-License-Identifier: GPL-3.0-only`.
- **Tests must be real:** assert exact observable values; a negative test asserts the *specific* wrong result, not merely "not X".
- **No em-dash** in any generated output (code, comments, commit messages). Use a colon/parens/semicolon/two sentences.
- **Conventional commits**; this work is on branch `fix/altscroll-b-context-and-logging`.
- **Run Kit tests:** `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <Suite>`. App-tier code is NOT locally buildable; validated on macOS CI + device.
- **`→` (U+2192) is used literally** in log-line format strings (matches existing lines like `attachTmux ... →`).

## File Structure

- `Sources/SemicolynKit/Terminal/AltScrollMode.swift` (MODIFY) — add `AltScrollDecision` + `altScrollDecision(...)`; make `altScrollKeys(...)` a wrapper.
- `Sources/SemicolynKit/Diagnostics/DecisionLine.swift` (CREATE) — pure `decisionLine(...)` string helper.
- `Tests/SemicolynKitTests/AltScrollDeciderTests.swift` (MODIFY) — add decision + reason + wrapper-round-trip tests.
- `Tests/SemicolynKitTests/DecisionLineTests.swift` (CREATE) — format assertions.
- `App/TerminalGestureController.swift` (MODIFY) — callback keys→decision; three drag lines.
- `App/TmuxPaneContainer.swift` (MODIFY) — callback builds a decision; zoom + window-switch markers.
- `App/TerminalScreen.swift` (MODIFY) — raw-shell callback builds a decision; raw-pinch zoom marker.
- `App/ExperimentalSettingsView.swift` (MODIFY) — mode-switch marker.
- `App/ConnectionViewModel.swift` (MODIFY) — session-start marker.
- `App/LogCategory.swift` (MODIFY) — `.gesture` out of `defaultEnabled`.

---

## Task 1: `AltScrollDecision` value + returning decider (Kit)

**Files:**
- Modify: `Sources/SemicolynKit/Terminal/AltScrollMode.swift`
- Test: `Tests/SemicolynKitTests/AltScrollDeciderTests.swift`

**Interfaces:**
- Consumes: existing `AltScrollMode`, `AltScrollKeys`, `AltScrollRegistry` (`wantsPageKeys(command:)`, `wantsPageKeys(title:)`).
- Produces:
  - `struct AltScrollDecision: Sendable, Equatable { let keys: AltScrollKeys; let mode: AltScrollMode; let paneCommand: String?; let reason: String; var logLine: String }`
  - `func altScrollDecision(mode: AltScrollMode, paneCommand: String?, windowTitle: String?, registry: AltScrollRegistry) -> AltScrollDecision`
  - `func altScrollKeys(mode:paneCommand:windowTitle:registry:) -> AltScrollKeys` (unchanged signature, now a wrapper).
  - `reason` values (exact strings): `"off"`, `"auto:registered"`, `"auto:unregistered"`, `"alwaysPageKeys"`, `"autoPlusTitle:cmd"`, `"autoPlusTitle:title"`.

- [ ] **Step 1: Write the failing tests** — append to `AltScrollDeciderTests.swift` (inside the class):

```swift
    private func decide(_ mode: AltScrollMode, cmd: String?, title: String? = nil) -> AltScrollDecision {
        altScrollDecision(mode: mode, paneCommand: cmd, windowTitle: title, registry: reg)
    }

    // Decision carries the chosen keys AND a reason that cannot disagree with keys.
    func testDecisionOffArrowsWithReason() {
        let d = decide(.off, cmd: "claude")
        XCTAssertEqual(d.keys, .arrows)
        XCTAssertEqual(d.reason, "off")
        XCTAssertEqual(d.paneCommand, "claude")
        XCTAssertEqual(d.mode, .off)
    }

    func testDecisionAutoRegistered() {
        let d = decide(.auto, cmd: "claude")
        XCTAssertEqual(d.keys, .pageKeys)
        XCTAssertEqual(d.reason, "auto:registered")
    }

    func testDecisionAutoUnregistered() {
        let d = decide(.auto, cmd: "bash")
        XCTAssertEqual(d.keys, .arrows)
        XCTAssertEqual(d.reason, "auto:unregistered")
    }

    // Boundary: nil command in .auto vs .autoPlusTitle takes different branches.
    func testDecisionAutoNilCommandIsUnregistered() {
        let d = decide(.auto, cmd: nil, title: "claude")   // title ignored in .auto
        XCTAssertEqual(d.keys, .arrows)
        XCTAssertEqual(d.reason, "auto:unregistered")
    }

    func testDecisionAlwaysPageKeys() {
        let d = decide(.alwaysPageKeys, cmd: nil)
        XCTAssertEqual(d.keys, .pageKeys)
        XCTAssertEqual(d.reason, "alwaysPageKeys")
    }

    func testDecisionAutoPlusTitleUsesCmdBranch() {
        let d = decide(.autoPlusTitle, cmd: "claude", title: nil)
        XCTAssertEqual(d.keys, .pageKeys)
        XCTAssertEqual(d.reason, "autoPlusTitle:cmd")
    }

    func testDecisionAutoPlusTitleUsesTitleBranchWhenCmdNil() {
        let d = decide(.autoPlusTitle, cmd: nil, title: "myrepo - claude: x")
        XCTAssertEqual(d.keys, .pageKeys)
        XCTAssertEqual(d.reason, "autoPlusTitle:title")
    }

    // Negative: an unregistered command in .autoPlusTitle (cmd branch) does NOT become pageKeys.
    func testDecisionAutoPlusTitleCmdBranchNegative() {
        let d = decide(.autoPlusTitle, cmd: "bash", title: "claude")
        XCTAssertEqual(d.keys, .arrows)                 // cmd branch: bash unregistered
        XCTAssertEqual(d.reason, "autoPlusTitle:cmd")   // title NOT consulted (cmd present)
    }

    // logLine is self-contained: carries inputs + output + reason.
    func testDecisionLogLineSelfContained() {
        XCTAssertEqual(decide(.auto, cmd: "claude").logLine,
                       "mode=auto app=claude → keys=pageKeys reason=auto:registered")
    }

    func testDecisionLogLineNilCommand() {
        XCTAssertEqual(decide(.auto, cmd: nil).logLine,
                       "mode=auto app=nil → keys=arrows reason=auto:unregistered")
    }

    // Wrapper round-trip: altScrollKeys == altScrollDecision(...).keys for every mode.
    func testWrapperMatchesDecisionKeys() {
        for mode in AltScrollMode.allCases {
            for cmd in ["claude", "bash", nil] {
                XCTAssertEqual(
                    altScrollKeys(mode: mode, paneCommand: cmd, windowTitle: "claude", registry: reg),
                    altScrollDecision(mode: mode, paneCommand: cmd, windowTitle: "claude", registry: reg).keys,
                    "wrapper drifted for mode=\(mode) cmd=\(cmd ?? "nil")")
            }
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter AltScrollDeciderTests`
Expected: FAIL (compile error: `altScrollDecision` / `AltScrollDecision` / `.logLine` not defined).

- [ ] **Step 3: Implement `AltScrollDecision` + `altScrollDecision(...)` + wrapper** — replace the `altScrollKeys(...)` function block in `AltScrollMode.swift` (lines 16-36) with:

```swift
/// A resolved alt-screen scroll decision: the chosen key family PLUS the inputs and the
/// branch reason that produced it. Returned by `altScrollDecision(...)` so the App can log a
/// self-contained line (`decision.logLine`) reflecting exactly what the pure decider saw:
/// the reason is derived from the branch taken, so it can never disagree with `keys`.
/// - paneCommand: tmux `pane_current_command` for this pane; nil on raw/mosh.
public struct AltScrollDecision: Sendable, Equatable {
    public let keys: AltScrollKeys
    public let mode: AltScrollMode
    public let paneCommand: String?
    public let reason: String

    /// Self-contained one-liner (no pane id: the App prepends `pane=%N`, since the pure
    /// decider does not know the pane id). Format: `mode=X app=Y → keys=Z reason=R`.
    public var logLine: String {
        "mode=\(mode.rawValue) app=\(paneCommand ?? "nil") → keys=\(keys) reason=\(reason)"
    }
}

/// The pure alt-scroll decision the App snapshots once at drag `.began`.
/// - windowTitle: OSC 0/2 title; consulted only in `.autoPlusTitle` when `paneCommand` is nil.
public func altScrollDecision(mode: AltScrollMode,
                              paneCommand: String?,
                              windowTitle: String?,
                              registry: AltScrollRegistry) -> AltScrollDecision {
    let (keys, reason): (AltScrollKeys, String)
    switch mode {
    case .off:
        (keys, reason) = (.arrows, "off")
    case .auto:
        let page = registry.wantsPageKeys(command: paneCommand)
        (keys, reason) = (page ? .pageKeys : .arrows,
                          page ? "auto:registered" : "auto:unregistered")
    case .alwaysPageKeys:
        (keys, reason) = (.pageKeys, "alwaysPageKeys")
    case .autoPlusTitle:
        if let cmd = paneCommand {
            (keys, reason) = (registry.wantsPageKeys(command: cmd) ? .pageKeys : .arrows,
                              "autoPlusTitle:cmd")
        } else {
            (keys, reason) = (registry.wantsPageKeys(title: windowTitle) ? .pageKeys : .arrows,
                              "autoPlusTitle:title")
        }
    }
    return AltScrollDecision(keys: keys, mode: mode, paneCommand: paneCommand, reason: reason)
}

/// Behavior-preserving wrapper: existing callers and tests keep the `-> AltScrollKeys`
/// signature. Delegates to `altScrollDecision(...)` so the two can never drift.
public func altScrollKeys(mode: AltScrollMode,
                          paneCommand: String?,
                          windowTitle: String?,
                          registry: AltScrollRegistry) -> AltScrollKeys {
    altScrollDecision(mode: mode, paneCommand: paneCommand,
                      windowTitle: windowTitle, registry: registry).keys
}
```

Note: `AltScrollMode` must be `CaseIterable` for the wrapper round-trip test — it already is (line 6: `CaseIterable`). No change needed.

- [ ] **Step 4: Run tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter AltScrollDeciderTests`
Expected: PASS (all decider + reason + logLine + wrapper-round-trip tests green).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Terminal/AltScrollMode.swift Tests/SemicolynKitTests/AltScrollDeciderTests.swift
git commit -m "feat(kit): AltScrollDecision returns inputs+reason; altScrollKeys becomes a wrapper"
```

---

## Task 2: `decisionLine(...)` uniformity helper (Kit)

**Files:**
- Create: `Sources/SemicolynKit/Diagnostics/DecisionLine.swift`
- Test: `Tests/SemicolynKitTests/DecisionLineTests.swift`

**Interfaces:**
- Produces: `func decisionLine(_ event: String, inputs: [(String, String)], outputs: [(String, String)], reason: String? = nil) -> String`
- Format: `event a=1 b=2 → x=9 reason=R` (inputs space-joined, ` → `, outputs space-joined, optional ` reason=R`). If `inputs` is empty, no leading space before `→`. If `reason` is nil, omit ` reason=`.
- Not consumed by the gesture path (it logs `decision.logLine`); built + tested now, ready for the non-gesture sweep.

- [ ] **Step 1: Write the failing test** — create `Tests/SemicolynKitTests/DecisionLineTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class DecisionLineTests: XCTestCase {
    func testInputsOutputsAndReason() {
        let line = decisionLine("grid",
                                inputs: [("bounds", "402"), ("cell", "4.8")],
                                outputs: [("cols", "83")],
                                reason: "fractional-cell")
        XCTAssertEqual(line, "grid bounds=402 cell=4.8 → cols=83 reason=fractional-cell")
    }

    func testNoReasonOmitsReasonField() {
        let line = decisionLine("grid",
                                inputs: [("bounds", "402")],
                                outputs: [("cols", "83")])
        XCTAssertEqual(line, "grid bounds=402 → cols=83")
    }

    func testEmptyInputsHasNoLeadingSpace() {
        let line = decisionLine("poll", inputs: [], outputs: [("panes", "9")])
        XCTAssertEqual(line, "poll → panes=9")
    }

    func testMultipleOutputs() {
        let line = decisionLine("size", inputs: [("w", "402")], outputs: [("cols", "80"), ("rows", "40")])
        XCTAssertEqual(line, "size w=402 → cols=80 rows=40")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter DecisionLineTests`
Expected: FAIL (`decisionLine` not defined).

- [ ] **Step 3: Implement the helper** — create `Sources/SemicolynKit/Diagnostics/DecisionLine.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Renders a self-contained decision line in the project's standard format:
/// `event a=1 b=2 → x=9 reason=R`. Returns the string only; the App-tier caller passes it
/// to `DebugLog.shared.log(.<category>, …)` so category gating stays autoclosure-cheap. The
/// uniform format lets a device trace be read decision-by-decision without correlation.
public func decisionLine(_ event: String,
                         inputs: [(String, String)],
                         outputs: [(String, String)],
                         reason: String? = nil) -> String {
    func join(_ pairs: [(String, String)]) -> String {
        pairs.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
    }
    var line = event
    let ins = join(inputs)
    if !ins.isEmpty { line += " \(ins)" }
    line += " → \(join(outputs))"
    if let reason { line += " reason=\(reason)" }
    return line
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter DecisionLineTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Diagnostics/DecisionLine.swift Tests/SemicolynKitTests/DecisionLineTests.swift
git commit -m "feat(kit): decisionLine helper for uniform self-contained decision logging"
```

---

## Task 3: Callback returns a decision + gesture-controller drag lines (App)

**Files:**
- Modify: `App/TerminalGestureController.swift` (callback type + `beginDrag` + `handleAltScreenPan` + remove `gr:winner` line at ~268)
- Modify: `App/TmuxPaneContainer.swift:280-300` (build a decision, not just keys)
- Modify: `App/TerminalScreen.swift:152-160` (raw shell: build a decision)

**Interfaces:**
- Consumes: `altScrollDecision(...)` + `AltScrollDecision.logLine` (Task 1).
- Produces: `Callbacks.altScrollDecision: () -> AltScrollDecision` (renamed from `altScrollKeys`); the controller reads `dragDecision.keys` where it used `dragScrollKeys`.
- Note: App tier is NOT locally buildable. No `swift test` here; verified on macOS CI + device.

- [ ] **Step 1: Change the callback type** — in `TerminalGestureController.swift`, replace the `altScrollKeys` callback field (lines 45-48) with:

```swift
        /// The resolved alt-screen scroll DECISION for THIS pane (inputs + keys + reason),
        /// snapshotted once at drag `.began` via the pure `altScrollDecision(...)` decider.
        /// The controller logs `decision.logLine` verbatim so the line reflects what the
        /// decider actually saw (not the caller's belief). `.keys` drives arrow-vs-page.
        let altScrollDecision: () -> AltScrollDecision
```

- [ ] **Step 2: Replace the drag snapshot field** — replace `private var dragScrollKeys: AltScrollKeys = .arrows` (line 64, keep the doc comment above it) with:

```swift
    private var dragDecision: AltScrollDecision =
        AltScrollDecision(keys: .arrows, mode: .off, paneCommand: nil, reason: "off")
```

- [ ] **Step 3: Update `beginDrag` to snapshot the decision + log a self-contained `drag-begin`** — in `beginDrag(...)`, replace line 291 (`dragScrollKeys = callbacks.altScrollKeys()`) with:

```swift
        dragDecision = callbacks.altScrollDecision()
```

  and replace the `.began` log line (line 307) with:

```swift
        DebugLog.shared.log(.gesture,
            "drag-begin winner=\(owner) mode=\(dragMode) appCursor=\(dragAppCursor) \(dragDecision.logLine)")
```

- [ ] **Step 4: Update `handleAltScreenPan` `.changed` to a self-contained `drag-move`, and `.ended` to `drag-end`** — in `handleAltScreenPan`:

  Replace the run-encoding loop + log (lines 366-374) with:

```swift
            var sent = 0
            for run in runs {
                let bytes = dragDecision.keys == .pageKeys
                    ? encodePageKeyRun(run)
                    : encodeArrowRun(run, applicationCursorKeys: dragAppCursor)
                if !bytes.isEmpty { callbacks.sendBytes(bytes); sent += run.count }
            }
            if !runs.isEmpty {
                DebugLog.shared.log(.gesture,
                    "drag-move keys=\(dragDecision.keys) runs=\(runs.count) sent=\(sent) total=\(emittedCells)")
            }
```

  Replace the `.ended, .cancelled` case (lines 375-376) with:

```swift
        case .ended, .cancelled:
            let outcome: String
            if emittedCells > 0 {
                outcome = dragDecision.keys == .pageKeys ? "pageKeys" : "arrows"
            } else {
                outcome = "none"
            }
            DebugLog.shared.log(.gesture,
                "drag-end owner=altPan mode=\(dragMode) emitted=\(emittedCells) outcome=\(outcome)")
            resolveWindowSwitch(g, in: view)
```

- [ ] **Step 5: Add a `drag-end` to the native scroll pan (localScroll) too** — in `handleScrollViewPan`, replace the `.ended, .cancelled` case (lines 336-339) with:

```swift
        case .ended, .cancelled:
            DebugLog.shared.log(.gesture,
                "drag-end owner=scrollPan mode=\(dragMode) outcome=\(dragMode == .localScroll ? "scroll" : "none")")
            // Native pan is only live in `.localScroll`; guard defensively anyway.
            guard dragMode != .mouseReporting else { return }
            resolveWindowSwitch(g, in: view)
```

- [ ] **Step 6: Remove the now-redundant `gr:winner` line** — `beginDrag`'s `drag-begin` now carries `winner=`. Delete the standalone `gr:winner` log in `observeRecognizerState(_:)` (line ~268):

  Delete: `DebugLog.shared.log(.gesture, "gr:winner \(cls) delegate=\(del) state=\(g.state.rawValue)")`
  Replace the method body's log with nothing if the method becomes empty; if the method has other logic, leave it and just remove that one line. (If removing the line leaves an unused `cls`/`del`, remove those locals too.)

- [ ] **Step 7: Update the tmux callback to build a decision** — in `TmuxPaneContainer.swift`, replace the `altScrollKeys:` closure (lines 280-300) with an `altScrollDecision:` closure:

```swift
                        altScrollDecision: { [weak self] in
                            MainActor.assumeIsolated {
                                guard let self else {
                                    return AltScrollDecision(keys: .arrows, mode: .off,
                                                             paneCommand: nil, reason: "off")
                                }
                                let mode = AppStores.shared.terminalSettings.settings.altScrollMode
                                // Read the runtime's COMPLETE context (not the
                                // renderablePanes-filtered `paneContexts`, which dropped the
                                // dragged pane and forced arrows: device trace 2026-07-16).
                                let cmd = self.vm.tmuxPaneCommand(pane)
                                let title = self.vm.terminalTitle
                                let decision = altScrollDecision(mode: mode, paneCommand: cmd,
                                                                 windowTitle: title, registry: .bundledDefault)
                                // The App prepends the pane id; the decider does not know it.
                                // This single line supersedes the old "altScroll decide" line;
                                // drag-begin logs decision.logLine, so this confirms the pane
                                // -> command resolution at snapshot time.
                                DebugLog.shared.log(.gesture,
                                    "alt-scroll pane=%\(pane.raw) \(decision.logLine)")
                                return decision
                            }
                        },
```

- [ ] **Step 8: Update the raw-shell callback to build a decision** — in `TerminalScreen.swift`, replace the `altScrollKeys:` closure (lines 152-160) with:

```swift
                altScrollDecision: { [weak coordinator = context.coordinator] in
                    MainActor.assumeIsolated {
                        let mode = AppStores.shared.terminalSettings.settings.altScrollMode
                        // Raw/mosh single pane: no tmux pane_current_command.
                        let title = coordinator?.vm?.terminalTitle
                        return altScrollDecision(mode: mode, paneCommand: nil,
                                                 windowTitle: title, registry: .bundledDefault)
                    }
                },
```

- [ ] **Step 9: Commit**

```bash
git add App/TerminalGestureController.swift App/TmuxPaneContainer.swift App/TerminalScreen.swift
git commit -m "feat(terminal): self-contained drag-begin/move/end lines; callback returns AltScrollDecision"
```

---

## Task 4: Session-start + user-action markers (App, `.lifecycle`)

**Files:**
- Modify: `App/ConnectionViewModel.swift` (session-start marker at `attachTmux: ENTER`, line ~833)
- Modify: `App/ExperimentalSettingsView.swift:20` (mode-switch marker)
- Modify: `App/TmuxPaneContainer.swift` (pinch zoom marker at line ~370; window-switch marker via `onSwitchWindow` at line ~272)
- Modify: `App/TerminalScreen.swift` (raw pinch zoom marker at line ~307 handler)

**Interfaces:**
- Consumes: existing `DebugLog.shared.log(.lifecycle, …)`; existing `RemoteLogSink.deviceIdentifier`-style build string (`CFBundleVersion`).
- Produces: `.lifecycle` marker lines prefixed `user-action:` / `=== session-start … ===`.

- [ ] **Step 1: Add the session-start marker** — in `ConnectionViewModel.swift` at `attachTmux: ENTER` (line 833), add immediately after that existing log:

```swift
        // Self-narrating anchor for a device trace: build + transport + window so a pasted
        // log fragment is self-locating (paired with the per-drag decision lines).
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        DebugLog.shared.log(.lifecycle,
            "=== session-start build=\(build) transport=\(transportKind) session=\(tmuxSessionNameForConnection) ===")
```

  If `transportKind` is not a symbol in scope here, use the existing transport indicator (search the file for how transport is named, e.g. `mosh`/`ssh` flag) and substitute; if none exists, drop the `transport=` field rather than inventing one. Keep the line otherwise.

- [ ] **Step 2: Add the mode-switch marker** — in `ExperimentalSettingsView.swift`, attach an `.onChange` to the alt-scroll `Picker` (line 20). Replace the `Picker(...)` line's closing with an `.onChange` modifier on the Picker:

```swift
                Picker("Alt-screen scroll", selection: $store.settings.altScrollMode) {
                    // ... existing ForEach/cases unchanged ...
                }
                .onChange(of: store.settings.altScrollMode) { _, newValue in
                    DebugLog.shared.log(.lifecycle, "user-action: mode-switch \(newValue.rawValue)")
                }
```

  (If the file targets an OS where the two-parameter `onChange` is unavailable, use the single-parameter form `.onChange(of:) { newValue in … }`. Match the form already used elsewhere in the App: search for `.onChange(of:` to see which signature the codebase uses.)

- [ ] **Step 3: Convert the tmux pinch log to a zoom user-action marker** — in `TmuxPaneContainer.swift` `handlePinch` `.ended` (line 370), replace:

```swift
                    DebugLog.shared.log(.gesture, "gesture:pinch fontSize=\(baseFontSize)")
```

  with:

```swift
                    DebugLog.shared.log(.lifecycle, "user-action: zoom pinch → font=\(baseFontSize)")
```

- [ ] **Step 4: Add a window-switch marker** — in `TmuxPaneContainer.swift`, the `onSwitchWindow` closure (line 272) forwards a delta. Wrap the forward with a marker:

```swift
                        onSwitchWindow:    { [weak self] delta in
                            MainActor.assumeIsolated {
                                DebugLog.shared.log(.lifecycle, "user-action: window-switch delta=\(delta)")
                            }
                            self?.onSwitchWindow(delta)
                        },
```

  (If `onSwitchWindow` here is already on the main actor, drop the `MainActor.assumeIsolated` wrapper and log directly. Check the enclosing context; this closure builds `Callbacks`, whose closures are called from `@MainActor` gesture handlers, so a direct call is likely fine. Prefer the simplest form that compiles.)

- [ ] **Step 5: Convert the raw-shell pinch log to a zoom marker** — in `TerminalScreen.swift` `handlePinch` (the Coordinator handler around line 307), find its `.ended` `DebugLog` line (if present, e.g. `gesture:pinch`) and change it to `.lifecycle` `user-action: zoom pinch → font=…` mirroring Step 3. If the raw handler has no such log, add one in `.ended`:

```swift
            case .ended:
                // ... existing clamp/persist ...
                DebugLog.shared.log(.lifecycle, "user-action: zoom pinch → font=\(baseFontSize)")
```

  Match the actual variable name for the persisted size in that handler (it may differ from `baseFontSize`); use whatever the handler already assigns.

- [ ] **Step 6: Commit**

```bash
git add App/ConnectionViewModel.swift App/ExperimentalSettingsView.swift App/TmuxPaneContainer.swift App/TerminalScreen.swift
git commit -m "feat(terminal): session-start + user-action markers (mode-switch, zoom, window-switch)"
```

---

## Task 5: `gesture` category default-OFF (App)

**Files:**
- Modify: `App/LogCategory.swift:43`

**Interfaces:**
- Consumes: nothing new.
- Produces: `defaultEnabled` without `.gesture`.

- [ ] **Step 1: Flip the default** — in `LogCategory.swift`, change line 43:

```swift
    static let defaultEnabled: Set<LogCategory> = [.lifecycle, .connect, .tmux, .seed]
```

  (Removed `.gesture`. The new drag lines are dense-but-self-contained: opt-in when debugging gestures, same tier as render/input/predictor. Markers stay visible because they are `.lifecycle`.)

- [ ] **Step 2: Update the doc comment** — the comment above `defaultEnabled` (lines 41-42) says the high-volume ones default OFF; add `.gesture` to that list. Replace lines 41-42:

```swift
    /// Categories ON by default: low-volume, high-diagnostic-value. The high-volume /
    /// niche ones (gesture/render/input/predictor/keybar) default OFF (opt-in when needed).
```

- [ ] **Step 3: Commit**

```bash
git add App/LogCategory.swift
git commit -m "chore(logging): gesture category default-OFF (dense self-contained drag lines are opt-in)"
```

---

## Task 6: Retest note + TODO update

**Files:**
- Modify: `TODO.md`

- [ ] **Step 1: Record the retest procedure** — add to `TODO.md` under the alt-scroll section:

```markdown
### Logging rework retest (build TBD)
Before the scripted drag test, enable in Settings → Diagnostics: **Gesture** (+ Tmux, Lifecycle
already on). Then run the scripted actions. The trace should read top-to-bottom as:
  === session-start build=N … ===
  user-action: mode-switch <mode>
  alt-scroll pane=%N mode=… app=… → keys=… reason=…
  drag-begin winner=… mode=… <decision.logLine>
  drag-move keys=… sent=… total=…
  drag-end owner=… mode=… emitted=… outcome=<scroll|pageKeys|arrows|none>
No narration required. Confirms B mode-classification (mouseReporting vs appOwnsInput) from
`drag-begin mode=` + `alt-scroll … reason=`. THEN fix B-remainder / C-momentum / D-width.
```

- [ ] **Step 2: Commit**

```bash
git add TODO.md
git commit -m "docs(todo): logging-rework retest procedure"
```

---

## Self-Review

**Spec coverage** (each spec section → task):
- §1a format → Tasks 1 (`logLine`) + 2 (`decisionLine`). ✓
- §1b truth-at-source (Kit returns decision) → Task 1 + Task 3 (App logs verbatim). ✓
- §1c `decisionLine` helper (built + tested now) → Task 2. ✓
- §2a Kit decision struct + wrapper → Task 1. ✓
- §2b three drag lines + `gr:winner` folded + callback keys→decision → Task 3. ✓
- §3a session-start marker → Task 4 Step 1. ✓
- §3b user-action markers (mode-switch/zoom/settings-change/window-switch) → Task 4. **GAP: `settings-change` marker not implemented.** See resolution below.
- §4a gesture default-OFF → Task 5. ✓
- §4b tests (decision EP+BVA+negative, wrapper round-trip, decisionLine format) → Tasks 1-2. ✓
- §4c scope boundary (sweep deferred) → not implemented by design. ✓
- Deliverable 6 retest note → Task 6. ✓

**Gap resolution — `settings-change` marker:** the spec lists a generic `user-action: settings-change <key>=<value>` marker. The only settings change that affects the alt-scroll retest is the alt-scroll-mode change, which Task 4 Step 2 already logs specifically as `mode-switch`. A generic settings-change marker across ALL settings is out of scope for the gesture retest and risks touching many views. **Resolution:** the `mode-switch` marker covers the retest-relevant case; a general settings-change marker is folded into the deferred §4c sweep (it is an App-tier decision-boundary adoption, same category as grid/context). No separate task here. (Recorded so it is a tracked deferral, not a silent drop.)

**Placeholder scan:** No placeholders remain. Every test method has a real exact-value assertion; no `TBD`/`add error handling`/`similar to`/fake-symbol stubs. (An earlier draft of Task 1 had a placeholder `logLine` test; removed in favor of inline real assertions `testDecisionLogLineSelfContained` + `testDecisionLogLineNilCommand`.)

**Type consistency:**
- `AltScrollDecision(keys:mode:paneCommand:reason:)` initializer — used identically in Task 1 (definition), Task 3 Steps 2/7 (default value), consistent field order. ✓
- Callback renamed `altScrollKeys` → `altScrollDecision` — changed in the type (Task 3 Step 1) AND both call sites (Task 3 Steps 7-8). No caller left referencing the old name (grep confirmed only these 3 files reference the callback). ✓
- `dragScrollKeys` → `dragDecision` — field renamed (Step 2) and every use updated (Steps 3-4: `dragDecision.keys`). ✓
- `decisionLine(event:inputs:outputs:reason:)` — signature identical in Task 2 definition + test. ✓

Issues found and resolved inline above. Plan is complete.
