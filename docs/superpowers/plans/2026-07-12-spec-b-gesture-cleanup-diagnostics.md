<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Spec B: Gesture Cleanup + Categorized Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the three remaining terminal-gesture bugs (stuck selection, render storm, window-tab switch) and add categorized, user-selectable diagnostic logging across the App tier.

**Architecture:** Two pure deciders go to SemicolynKit (Linux-tested): `tapAction(hasSelection:)` and `RenderSignature`. The App tier gains a `LogCategory` enum with per-category `@AppStorage` toggles in Diagnostics settings, a category-gated `DebugLog.log`, the three fixes wired through the deciders, and a boundary-logging audit across `App/`.

**Tech Stack:** Swift 6, XCTest, SwiftUI, SwiftTerm (`selectionActive`/`selectNone()`), tmux 3.4 control mode.

Spec: `docs/superpowers/specs/2026-07-12-spec-b-gesture-cleanup-diagnostics-design.md`.

## Global Constraints

- **Two-tier rule:** `Sources/SemicolynKit/` = pure logic, Linux-tested, `Sendable`, **no `import UIKit`/`SwiftUI`**. `App/` = Apple-only, validated ONLY by the macOS CI job. — `CLAUDE.md`.
- **SPDX header** on every new file: `// SPDX-FileCopyrightText: 2026 True Positive LLC` / `// SPDX-License-Identifier: GPL-3.0-only`.
- **Tests are real** (`docs/superpowers/specs/2026-06-18-testing-standards-design.md`): EP + boundary; assert exact observable values; a negative test asserts the specific result.
- **Conventional commits**; one feature branch `feat/spec-b-gesture-diagnostics`.
- **Linux test:** `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <Name>` (no host Swift; runs in `semicolyn-dev` Docker; disable sandbox if the Docker socket is blocked).
- **App-tier tasks are not Linux-buildable** — gate is the macOS CI job; on-device behavior via the diagnostics stream.
- **Log-line style (spec-mandated):** `"<category>:<event> key=value key=value"`; `PaneID` rendered `%N`, `WindowID` rendered `@N`; one line per boundary, no multi-line messages.
- **Category defaults:** `.lifecycle`, `.connect`, `.tmux`, `.gesture`, `.seed` = ON; `.render`, `.input`, `.predictor`, `.keybar` = OFF.
- **Layer 3 audit is logs-only** — zero behavior change. The ONLY behavior changes in this plan are Tasks 4/5/6.

## File Structure

**New (SemicolynKit, Linux-tested):**
- `Sources/SemicolynKit/Terminal/TapAction.swift` — `TapAction` + `tapAction(hasSelection:)`.
- `Sources/SemicolynKit/Tmux/RenderSignature.swift` — `RenderSignature` derived from `TmuxSessionState`.
- `Tests/SemicolynKitTests/TapActionTests.swift`, `Tests/SemicolynKitTests/RenderSignatureTests.swift`

**New (App, macOS-CI-only):**
- `App/LogCategory.swift` — the category enum + default set + `@AppStorage`-key helpers.

**Modified (App):**
- `App/DebugLog.swift` — category param on `log`, cached enabled-set, gate.
- `App/DiagnosticsSettingsView.swift` — "Log categories" toggles section.
- `App/TerminalGestureController.swift` — `clearSelection` callback + tap-decider wiring (Fix 1).
- `App/TerminalScreen.swift` + `App/TmuxPaneContainer.swift` — wire `clearSelection`; recategorize existing logs; window-tab + boundary instrumentation.
- `App/ConnectionViewModel.swift` — render-signature dedup (Fix 2) + window-tab hop logs (Fix 3) + boundary audit.
- `App/PaneHistorySeeder.swift` — recategorize `applyHistory` logs under `.seed`.
- Enumerated `App/*.swift` files — boundary logging audit (Task 7/8).

**Reused (no change):** `TmuxSessionState`/`TmuxWindow`/`PaneLayout` (already `Equatable`), `WindowID`/`PaneID` (`Hashable`), `RemoteLogConfig`, SwiftTerm `selectionActive`/`selectNone()`.

---

## Task 1: `TapAction` decider (pure, Linux)

**Files:**
- Create: `Sources/SemicolynKit/Terminal/TapAction.swift`
- Test: `Tests/SemicolynKitTests/TapActionTests.swift`

**Interfaces:**
- Produces: `public enum TapAction: Equatable, Sendable { case clearSelection, placeCursor }` and `public func tapAction(hasSelection: Bool) -> TapAction`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/SemicolynKitTests/TapActionTests.swift`:
```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// A single tap dismisses an active selection first; otherwise it places the cursor.
final class TapActionTests: XCTestCase {
    // EP: selection present → the tap clears it (does NOT place cursor).
    func testTapWithSelectionClears() {
        XCTAssertEqual(tapAction(hasSelection: true), .clearSelection)
    }

    // EP: no selection → the tap places the cursor.
    func testTapWithoutSelectionPlaces() {
        XCTAssertEqual(tapAction(hasSelection: false), .placeCursor)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TapActionTests`
Expected: FAIL — `cannot find 'tapAction' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/SemicolynKit/Terminal/TapAction.swift`:
```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// What a single tap should do, given whether a text selection is currently active.
/// A tap while a selection exists DISMISSES it (standard terminal UX: tap-to-clear,
/// tap-again-to-place); with no selection, a tap places the cursor at the tapped cell.
public enum TapAction: Equatable, Sendable {
    case clearSelection
    case placeCursor
}

/// Pure tap decider. `hasSelection` = the terminal view has an active selection range.
public func tapAction(hasSelection: Bool) -> TapAction {
    hasSelection ? .clearSelection : .placeCursor
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TapActionTests`
Expected: PASS (2).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Terminal/TapAction.swift Tests/SemicolynKitTests/TapActionTests.swift
git commit -m "feat(terminal): tapAction decider — clear selection vs place cursor (pure)"
```

---

## Task 2: `RenderSignature` decider (pure, Linux)

**Files:**
- Create: `Sources/SemicolynKit/Tmux/RenderSignature.swift`
- Test: `Tests/SemicolynKitTests/RenderSignatureTests.swift`

**Interfaces:**
- Consumes: `TmuxSessionState` (`windows: [TmuxWindow]`, `activeWindow: WindowID?`); `TmuxWindow` (`id: WindowID`, `visibleLayout: PaneLayout?`); `PaneLayout` (Equatable); `WindowID`/`PaneID` (Hashable). All existing.
- Produces: `public struct RenderSignature: Equatable, Sendable { public init(_ state: TmuxSessionState) }`. Two `TmuxSessionState`s that render identically produce equal signatures; a change to the active window, the window list, or the active window's visible layout produces a differing signature.

- [ ] **Step 1: Write the failing tests**

Create `Tests/SemicolynKitTests/RenderSignatureTests.swift`. (Use the real `TmuxSessionState` construction path the codebase uses — check `TmuxSessionStateTests.swift` for the builder/mutators; the pseudo-code below shows intent, adapt to the real API when implementing.)
```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// RenderSignature: equal iff two states render identically. Drives render-storm dedup.
final class RenderSignatureTests: XCTestCase {
    // EP: the SAME state → equal signatures (→ caller skips the redundant render).
    func testSameStateEqualSignature() {
        let s = makeState(windows: [win(1, panes: [1, 2])], active: 1)
        XCTAssertEqual(RenderSignature(s), RenderSignature(s))
    }

    // Active window changed → signatures differ (→ render, reason=active).
    func testActiveWindowChangeDiffers() {
        let a = makeState(windows: [win(1, panes: [1]), win(2, panes: [3])], active: 1)
        let b = makeState(windows: [win(1, panes: [1]), win(2, panes: [3])], active: 2)
        XCTAssertNotEqual(RenderSignature(a), RenderSignature(b))
    }

    // Window list changed (window added) → signatures differ.
    func testWindowListChangeDiffers() {
        let a = makeState(windows: [win(1, panes: [1])], active: 1)
        let b = makeState(windows: [win(1, panes: [1]), win(2, panes: [2])], active: 1)
        XCTAssertNotEqual(RenderSignature(a), RenderSignature(b))
    }

    // Active window's visible layout changed (pane set) → signatures differ.
    func testActiveLayoutChangeDiffers() {
        let a = makeState(windows: [win(1, panes: [1, 2])], active: 1)
        let b = makeState(windows: [win(1, panes: [1, 2, 3])], active: 1)
        XCTAssertNotEqual(RenderSignature(a), RenderSignature(b))
    }

    // A change ONLY to a NON-active window's layout does NOT differ (we render the
    // active window; off-screen windows don't affect the rendered output).
    func testNonActiveLayoutChangeDoesNotDiffer() {
        let a = makeState(windows: [win(1, panes: [1]), win(2, panes: [3])], active: 1)
        let b = makeState(windows: [win(1, panes: [1]), win(2, panes: [3, 4])], active: 1)
        XCTAssertEqual(RenderSignature(a), RenderSignature(b))
    }

    // --- helpers: adapt to the real TmuxSessionState/TmuxWindow/PaneLayout builders ---
    private func win(_ id: UInt32, panes: [UInt32]) -> TmuxWindow { /* build per real API */ }
    private func makeState(windows: [TmuxWindow], active: UInt32) -> TmuxSessionState { /* per real API */ }
}
```

**Implementer note:** `TmuxSessionState.windows`/`activeWindow` are `private(set)`; construct states via the same mutation entry points the existing `TmuxSessionStateTests` use (grep that file). If building a `PaneLayout` with a specific pane-set is awkward in a test, use the smallest real layout the existing tests use and vary the pane count. Keep each assertion on the EXACT equal/not-equal outcome (no weak predicates).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter RenderSignatureTests`
Expected: FAIL — `cannot find 'RenderSignature' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/SemicolynKit/Tmux/RenderSignature.swift`:
```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// A value that is equal for two `TmuxSessionState`s that render identically, and differs
/// when the rendered output would change. Used to skip redundant tmux pane re-renders (the
/// control channel fires state updates far more often than the visible layout changes).
///
/// The rendered output is: the ACTIVE window's `visibleLayout`, plus the window LIST (tab
/// strip) and which window is active. A change to a NON-active window's layout does not
/// change what is on screen, so it is intentionally excluded.
public struct RenderSignature: Equatable, Sendable {
    private let activeWindow: WindowID?
    private let windowIDs: [WindowID]
    private let activeVisibleLayout: PaneLayout?

    public init(_ state: TmuxSessionState) {
        self.activeWindow = state.activeWindow
        self.windowIDs = state.windows.map(\.id)
        self.activeVisibleLayout = state.activeWindow
            .flatMap { id in state.windows.first { $0.id == id } }?
            .visibleLayout
    }
}
```

**Implementer note:** if the real `TmuxSessionState` exposes a `window(_:)` accessor (it does — used in `ConnectionViewModel`), use it instead of the inline `first { }`. The window LIST signature is `windowIDs` (order matters for the tab strip); include window NAMES too if the tab strip renders names and a rename should re-render — check `TmuxWindow` for a `name` field and add it to the signature if present (a rename changes the tab label = a real render).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter RenderSignatureTests`
Expected: PASS (5).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Tmux/RenderSignature.swift Tests/SemicolynKitTests/RenderSignatureTests.swift
git commit -m "feat(tmux): RenderSignature — equal iff renders identically (pure, render-dedup)"
```

---

## Task 3: `LogCategory` + category-gated `DebugLog` + Diagnostics toggles (App, macOS-CI-only)

> **Not Linux-buildable.** macOS CI is the gate.

**Files:**
- Create: `App/LogCategory.swift`
- Modify: `App/DebugLog.swift`, `App/DiagnosticsSettingsView.swift`

**Interfaces:**
- Produces: `enum LogCategory: String, CaseIterable, Sendable` (cases: `lifecycle, connect, tmux, render, gesture, input, predictor, keybar, seed`); `LogCategory.defaultEnabled: Set<LogCategory>`; `LogCategory.storageKey: String` (per case); `func DebugLog.log(_ category: LogCategory = .lifecycle, _ message: @autoclosure () -> String)`; `DebugLog.refreshEnabledCategories()`.

- [ ] **Step 1: Create `LogCategory`**

Create `App/LogCategory.swift`:
```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Diagnostic log categories. Each is independently enable/disable-able in
/// Settings → Diagnostics and persisted via `@AppStorage`. Gating happens BEFORE the
/// log message autoclosure is evaluated, so a disabled category costs nothing.
enum LogCategory: String, CaseIterable, Sendable {
    case lifecycle   // connect/attach/disconnect, app fg/bg, transport switch
    case connect     // auth, hostkey, mosh fallback, reconnect
    case tmux        // control-mode send / %reply / state-apply / pane register
    case render      // pane/window render — log-on-change only
    case gesture     // tap/pan/long-press/pinch handlers + classify decisions
    case input       // keystroke structural events (length/backspace/modifier), NOT content
    case predictor   // suggestion lifecycle + secret-exclusion gates
    case keybar      // accessory sizing, macro resolution, live-edit apply
    case seed        // tmux history seeding

    /// UserDefaults key backing the per-category toggle.
    var storageKey: String { "diagnostics.logcat.\(rawValue)" }

    /// Human label for the settings row.
    var label: String { rawValue.capitalized }

    /// Categories ON by default: low-volume, high-diagnostic-value. The high-volume /
    /// niche ones (render/input/predictor/keybar) default OFF (opt-in when needed).
    static let defaultEnabled: Set<LogCategory> = [.lifecycle, .connect, .tmux, .gesture, .seed]

    var defaultOn: Bool { Self.defaultEnabled.contains(self) }
}
```

- [ ] **Step 2: Add the category gate to `DebugLog`**

In `App/DebugLog.swift`, add a cached enabled-set + a category param on `log`. Replace the existing `func log(_ message:)` (line ~43) with:
```swift
    /// Categories currently enabled (cached; refreshed by `refreshEnabledCategories`).
    /// Seeded from each category's `@AppStorage` value, falling back to its default.
    private var enabledCategories: Set<LogCategory> = {
        var set = Set<LogCategory>()
        for c in LogCategory.allCases {
            let key = c.storageKey
            let on = UserDefaults.standard.object(forKey: key) as? Bool ?? c.defaultOn
            if on { set.insert(c) }
        }
        return set
    }()

    /// Re-read every category toggle from UserDefaults. Call when the Diagnostics
    /// category settings change (e.g. `DiagnosticsSettingsView.onAppear` / onChange).
    func refreshEnabledCategories() {
        var set = Set<LogCategory>()
        for c in LogCategory.allCases {
            let on = UserDefaults.standard.object(forKey: c.storageKey) as? Bool ?? c.defaultOn
            if on { set.insert(c) }
        }
        enabledCategories = set
    }

    /// Record one diagnostic line in `category` — ONLY when diagnostics is enabled AND the
    /// category is on. The message is an autoclosure: nothing is evaluated when gated out
    /// (zero sacred-path cost). `category` defaults to `.lifecycle` for legacy call sites.
    func log(_ category: LogCategory = .lifecycle, _ message: @autoclosure () -> String) {
        guard enabled, enabledCategories.contains(category) else { return }
        let now = Date().timeIntervalSinceReferenceDate
        if start == nil { start = now }
        let t = now - (start ?? now)
        let line = String(format: "%7.2f  %@", t, message())
        lines.append(line)
        if lines.count > cap { lines.removeFirst(lines.count - cap) }
        logger.debug("\(line, privacy: .public)")
        remote?.send(line)
    }
```
(Leave `setRemote`, `refresh`, `joined`, `clear` unchanged. Existing call sites `DebugLog.shared.log("…")` keep compiling via the `.lifecycle` default.)

- [ ] **Step 3: Add the "Log categories" section to Diagnostics**

In `App/DiagnosticsSettingsView.swift`, add a `Section` after the keystroke section. Bind each category to its `@AppStorage` key and refresh the cache on change. Because `@AppStorage` needs static keys, drive the toggles from a small helper array:
```swift
            Section {
                ForEach(LogCategory.allCases, id: \.self) { cat in
                    Toggle(cat.label, isOn: categoryBinding(cat))
                }
            } header: {
                Text("Log categories")
            } footer: {
                Text("Which diagnostic categories are recorded. Low-volume categories are on "
                     + "by default; render/input/predictor/keybar are verbose and off by default.")
            }
```
Add the binding helper (reads/writes UserDefaults directly + refreshes the cache — avoids needing one `@AppStorage` property per category):
```swift
    private func categoryBinding(_ cat: LogCategory) -> Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.object(forKey: cat.storageKey) as? Bool ?? cat.defaultOn },
            set: { UserDefaults.standard.set($0, forKey: cat.storageKey)
                   DebugLog.shared.refreshEnabledCategories() }
        )
    }
```
Also call `DebugLog.shared.refreshEnabledCategories()` in the existing `.onAppear` (next to `rebuildSink()`), so a fresh launch honors persisted toggles.

- [ ] **Step 4: Verify (macOS CI)** — commit; gate is Task 9.

- [ ] **Step 5: Commit**

```bash
git add App/LogCategory.swift App/DebugLog.swift App/DiagnosticsSettingsView.swift
git commit -m "feat(diagnostics): LogCategory + category-gated DebugLog + selectable toggles"
```

---

## Task 4: Fix 1 — clearSelection on single-tap (App, macOS-CI-only)

> **Not Linux-buildable.** macOS CI is the gate; device via `.gesture` trace.

**Files:**
- Modify: `App/TerminalGestureController.swift`, `App/TerminalScreen.swift`, `App/TmuxPaneContainer.swift`

**Interfaces:**
- Consumes: `tapAction(hasSelection:)` (Task 1); SwiftTerm `TerminalView.selectionActive: Bool` + `TerminalView.selectNone()` (public); `LogCategory.gesture` (Task 3).
- Produces: `TerminalGestureController.Callbacks` gains `let clearSelection: () -> Void` and `let hasSelection: () -> Bool`.

- [ ] **Step 1: Extend the callbacks struct**

In `App/TerminalGestureController.swift`, add to `struct Callbacks` (after `mouseReportingActive`):
```swift
        let hasSelection: () -> Bool
        let clearSelection: () -> Void
```

- [ ] **Step 2: Use the decider in `handleSingleTap`**

Replace `handleSingleTap` body (currently ~line 174-181) with:
```swift
    @objc private func handleSingleTap(_ g: UITapGestureRecognizer) {
        guard let view = terminalView else { return }
        if callbacks.mouseReportingActive() { return }
        let action = tapAction(hasSelection: callbacks.hasSelection())
        switch action {
        case .clearSelection:
            callbacks.clearSelection()
            DebugLog.shared.log(.gesture, "gesture:singleTap action=clear")
        case .placeCursor:
            let p = g.location(in: view)
            let target = cell(at: p, in: view)
            callbacks.onPlaceCursor(target.col, target.row)
            DebugLog.shared.log(.gesture, "gesture:singleTap action=place at=(\(target.col),\(target.row))")
        }
    }
```
(`import SemicolynKit` is already present in this file for other Kit types; if not, add it.)

- [ ] **Step 3: Wire the callbacks at the raw mount**

In `App/TerminalScreen.swift`, in the `TerminalGestureController(... callbacks: .init(...))` (makeUIView, ~line 114-123), add the two closures:
```swift
                hasSelection: { [weak terminal] in terminal?.selectionActive ?? false },
                clearSelection: { [weak terminal] in terminal?.selectNone() },
```

- [ ] **Step 4: Wire the callbacks at the tmux mount**

In `App/TmuxPaneContainer.swift`, find where each pane's `TerminalGestureController` is constructed (grep `TerminalGestureController(` in the Coordinator) and add the same two closures to that `.init(...)`, capturing that pane's `view`:
```swift
                hasSelection: { [weak view] in view?.selectionActive ?? false },
                clearSelection: { [weak view] in view?.selectNone() },
```

- [ ] **Step 5: Verify (macOS CI)** — commit; Task 9 gate. On device (later): with a selection active, a single tap clears it (`.gesture` trace shows `action=clear`); with none, it places the cursor.

- [ ] **Step 6: Commit**

```bash
git add App/TerminalGestureController.swift App/TerminalScreen.swift App/TmuxPaneContainer.swift
git commit -m "fix(gesture): single-tap clears an active selection before placing cursor"
```

---

## Task 5: Fix 2 — render-storm dedup via `RenderSignature` (App, macOS-CI-only)

> **Not Linux-buildable.** macOS CI is the gate; device via `.render` trace.

**Files:**
- Modify: `App/ConnectionViewModel.swift` (the `onStateChanged` closure ~line 834), `App/TmuxPaneContainer.swift` (the `tmux:render` log ~line 507)

**Interfaces:**
- Consumes: `RenderSignature(_:)` (Task 2); `LogCategory.render` (Task 3).
- Produces: a stored `private var lastRenderSignature: RenderSignature?` on the VM; renders/logs only on a real change.

- [ ] **Step 1: Add the signature field + gate in `onStateChanged`**

In `App/ConnectionViewModel.swift`, add near the other tmux state props:
```swift
    /// Last-applied render signature; a state update with an equal signature is a no-op
    /// for rendering (the control channel fires far more often than the layout changes).
    private var lastRenderSignature: RenderSignature?
```
In the `runtime.onStateChanged = { [weak self] state in … }` closure, right after `guard let self else { return }`, compute the signature and early-out when unchanged — BUT keep the bookkeeping that must always run (renderablePanes/pendingPaneBytes) OUTSIDE the skip if they're needed for byte routing. Concretely: compute the signature, and gate only the RENDER + its log, not the pane-bookkeeping. Replace the existing `DebugLog.shared.log("onStateChanged: …")` line and wrap the publish:
```swift
            let sig = RenderSignature(state)
            let changed = (sig != self.lastRenderSignature)
            self.lastRenderSignature = sig
            if changed {
                let reason = self.renderChangeReason(old: self.tmuxState, new: state)
                DebugLog.shared.log(.render, "render:apply reason=\(reason) wins=\(state.windows.count) active=\(state.activeWindow.map { "@\($0.raw)" } ?? "nil")")
            }
            // (pane bookkeeping below runs every time — byte routing must stay correct)
```
And gate the actual `tmuxState = state` publish / render trigger on `changed` if that publish is what drives the SwiftUI re-render. **Implementer note:** inspect how `tmuxState` assignment drives rendering. If assigning `tmuxState` is what re-renders `TmuxPaneContainer`, only assign when `changed` (skip the redundant publish). If byte-routing state (`renderablePanes`, `pendingPaneBytes`) is derived here too, keep THAT unconditional and gate only the `tmuxState` publish + the `.render` log. Do NOT skip anything that affects which panes receive output.

- [ ] **Step 2: Add the reason helper**

Add to `ConnectionViewModel`:
```swift
    /// Why a render fired — for the `.render` diagnostic. Cheap best-effort classification.
    private func renderChangeReason(old: TmuxSessionState?, new: TmuxSessionState) -> String {
        guard let old else { return "initial" }
        if old.activeWindow != new.activeWindow { return "active" }
        if old.windows.map(\.id) != new.windows.map(\.id) { return "windows" }
        return "layout"
    }
```

- [ ] **Step 3: Recategorize the container render log**

In `App/TmuxPaneContainer.swift` line ~507, change the existing `tmux:render` log to `.render` category (it now fires only on real renders because the publish is gated upstream):
```swift
            DebugLog.shared.log(.render, "render:panes active=\(String(describing: state.activeWindow)) windows=\(state.windows.count) panes=\(state.windows.first { $0.id == state.activeWindow }?.visibleLayout?.panes.count ?? -1)")
```

- [ ] **Step 4: Verify (macOS CI)** — commit; Task 9 gate. On device: with `.render` enabled, renders drop from dozens-identical to one-per-real-change with a `reason=`.

- [ ] **Step 5: Commit**

```bash
git add App/ConnectionViewModel.swift App/TmuxPaneContainer.swift
git commit -m "fix(tmux): dedup pane renders by RenderSignature (kills the render storm)"
```

---

## Task 6: Fix 3 — window-tab switch instrumentation + fix (App, macOS-CI-only)

> **Not Linux-buildable.** macOS CI is the gate; device via `.gesture`/`.tmux` trace.

**Files:**
- Modify: `App/SessionView.swift` (the `WindowTabStrip(... onSelect:)` ~line 59-60), `App/ConnectionViewModel.swift` (`selectWindow` ~line 283), `App/TmuxRuntime.swift` (`selectWindow` ~line 178 + the `%window-changed` handling)

**Interfaces:**
- Consumes: `LogCategory.gesture`/`.tmux`; existing `vm.selectWindow(_:)`, `TmuxRuntime.selectWindow(_:)`, `TmuxCommand.selectWindow(target:)`.
- Produces: full-hop instrumentation; and the fix (whichever hop the trace shows broken).

- [ ] **Step 1: Instrument the tap hop (UI → VM)**

In `App/SessionView.swift`, change the `WindowTabStrip` `onSelect` to log before delegating:
```swift
                        WindowTabStrip(windows: tmuxState.windows, active: tmuxState.activeWindow,
                                       onSelect: { id in
                                           DebugLog.shared.log(.gesture, "gesture:windowTab tap=@\(id.raw)")
                                           vm.selectWindow(id)
                                       })
```

- [ ] **Step 2: Recategorize + enrich the VM hop**

In `App/ConnectionViewModel.swift` `selectWindow` (~283), recategorize under `.tmux` and log the send:
```swift
    func selectWindow(_ id: WindowID) {
        DebugLog.shared.log(.tmux, "tmux:selectWindow id=@\(id.raw) activeBefore=\(tmuxState?.activeWindow.map { "@\($0.raw)" } ?? "nil")")
        tmux?.selectWindow(id)
    }
```

- [ ] **Step 3: Instrument the command-sent + %reply hops**

In `App/TmuxRuntime.swift` `selectWindow` (~178), log the actual write:
```swift
    func selectWindow(_ id: WindowID) {
        DebugLog.shared.log(.tmux, "tmux:send select-window target=@\(id.raw)")
        write(TmuxCommand.selectWindow(target: id))
    }
```
Then find where the control-mode parser surfaces the active-window change (grep `window-changed` / `activeWindow =` / `%window-changed` in `TmuxRuntime.swift`/`ControlModeParser`/`TmuxSessionController`) and add a `.tmux` log at the point the new active window is applied to state:
```swift
        DebugLog.shared.log(.tmux, "tmux:%window-changed active=@\(newActive.raw)")
```
**Implementer note:** the exact symbol depends on how the parser reports it. If `%window-changed` is NOT currently parsed at all, THAT is the bug (the tap sends `select-window`, tmux switches, but we never learn) — in that case the fix is to parse `%window-changed <window-id>` in the control-mode event handling and apply it to `TmuxSessionState.activeWindow`, which then flows through `onStateChanged` → `RenderSignature` (reason=active) → render. Add a `WindowListing`-style pure parse + Kit test if you add parsing. If it IS parsed and applied, the bug is elsewhere (e.g. the tab tap not reaching `onSelect`) — the Step 1 log now proves which.

- [ ] **Step 4: Verify (macOS CI + device trace)** — commit; the fix is confirmed on-device: tapping a tab logs `gesture:windowTab tap=@N` → `tmux:selectWindow` → `tmux:send select-window` → `tmux:%window-changed active=@N` → `render:apply reason=active`, and the active window visibly changes. If a hop is missing in the trace, apply the fix at that hop.

- [ ] **Step 5: Commit**

```bash
git add App/SessionView.swift App/ConnectionViewModel.swift App/TmuxRuntime.swift
git commit -m "fix(tmux): instrument + fix window-tab switch (full-hop .tmux/.gesture trace)"
```

---

## Task 7: Coverage audit — connection/tmux/gesture/render/seed paths (App, macOS-CI-only)

> **Not Linux-buildable.** macOS CI is the gate. **Logs-only: NO behavior change.**

**Files:** Modify (audit each): `App/ConnectionViewModel.swift`, `App/TmuxRuntime.swift`, `App/TmuxPaneContainer.swift`, `App/TerminalScreen.swift`, `App/TerminalGestureController.swift`, `App/PaneHistorySeeder.swift`, `App/RemoteLogSink.swift`.

**Interfaces:** Consumes `LogCategory` (Task 3). Produces categorized logs at each boundary; recategorizes existing uncategorized logs.

- [ ] **Step 1: Recategorize existing logs in these files**

For each file above, change every existing `DebugLog.shared.log("…")` to the correct category:
- connect/auth/hostkey/mosh-fallback/reconnect lines → `.connect`
- attach/disconnect/transport-switch/app-fg-bg lines → `.lifecycle`
- tmux send/`%`-event/state-apply/pane register/unregister → `.tmux`
- `scroll:init` / `scroll:postseed` / `seed applyHistory` → `.seed`
- gesture handler / classify lines → `.gesture`

**Implementer note:** grep each file for `DebugLog.shared.log(` and set the first-arg category by the line's subject. Preserve the message text (only add the category arg + adjust the prefix to the `<category>:<event>` convention where trivially cheap).

- [ ] **Step 2: Add missing boundary logs (connect + tmux round-trip)**

In `ConnectionViewModel`, ensure each is logged (add where missing), one line each: connect start (host/user), auth attempt + outcome, attach decision (tmux/raw/mosh), disconnect, reconnect trigger + result. In `TmuxRuntime`, ensure every command send and every parsed `%`-event has a `.tmux` line, and pane register/unregister (`registerPane`) has one.

- [ ] **Step 3: Add missing gesture boundary logs**

In `TerminalGestureController`, ensure every recognizer handler (`handlePan`/scroll, double/triple tap, long-press zoom, two-finger tap, pinch) logs a `.gesture` line with its decision (the singleTap already done in Task 4; the `gr:scrollPan` already logs — recategorize to `.gesture`).

- [ ] **Step 4: Verify (macOS CI)** — commit; Task 9 gate. Confirm the app still compiles and NO behavior changed (logs-only).

- [ ] **Step 5: Commit**

```bash
git add App/ConnectionViewModel.swift App/TmuxRuntime.swift App/TmuxPaneContainer.swift App/TerminalScreen.swift App/TerminalGestureController.swift App/PaneHistorySeeder.swift App/RemoteLogSink.swift
git commit -m "chore(diagnostics): categorize + fill boundary logs (connect/tmux/gesture/seed)"
```

---

## Task 8: Coverage audit — input/predictor/keybar paths (App, macOS-CI-only)

> **Not Linux-buildable.** macOS CI is the gate. **Logs-only: NO behavior change.**

**Files:** Modify (audit each): the App-tier input/predictor/keybar files. Enumerate at task start:
```bash
git ls-files 'App/*.swift' | xargs grep -l 'DebugLog.shared.log\|predictor\|Keybar\|keystroke' | sort -u
```

**Interfaces:** Consumes `LogCategory`. Produces `.input`/`.predictor`/`.keybar` logs at boundaries.

- [ ] **Step 1: Recategorize + fill `.input`**

In the input path (keystroke routing in `ConnectionViewModel.terminalKeyboardInput` / `TerminalScreen.send` / `TmuxPaneContainer.send`), ensure structural keystroke events (length, backspace, modifier-applied) log under `.input`. **Do NOT log key CONTENT** — content stays behind the existing separate `keystrokeContent` toggle + its redaction path (unchanged).

- [ ] **Step 2: Recategorize + fill `.predictor`**

In the predictor path, log under `.predictor`: suggestion surfaced/accepted/rejected, and each secret-exclusion gate that fires (echo/paste/pattern/graduation) — one line per gate decision. (Grep `PasswordEntryDetector`/`predictor`/`EchoOracle` call sites in `App/`.)

- [ ] **Step 3: Recategorize + fill `.keybar`**

In the keybar/accessory path (`KeybarInputAccessory`, keybar view host), log under `.keybar`: accessory height recompute (with the measured height), macro resolution, live-edit apply.

- [ ] **Step 4: Verify (macOS CI)** — commit; Task 9 gate. Logs-only, no behavior change.

- [ ] **Step 5: Commit**

```bash
git add App/
git commit -m "chore(diagnostics): categorize + fill boundary logs (input/predictor/keybar)"
```

---

## Task 9: Full Kit suite, push, macOS CI, PR, device verify

**Files:** none.

- [ ] **Step 1: Full Kit suite**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS — `TapActionTests` (2) + `RenderSignatureTests` (5) green; nothing else broken.

- [ ] **Step 2: Committed tree clean**

Run: `git status`
Expected: clean (no committed-vs-working divergence — the recurring CI trap).

- [ ] **Step 3: Push + PR**

```bash
git push github feat/spec-b-gesture-diagnostics
gh pr create --repo ds7n/semicolyn --title "feat: Spec B — gesture cleanup + categorized diagnostics" --body "Fixes stuck-selection (tap clears selection), render storm (RenderSignature dedup), and window-tab switch (instrument-then-fix). Adds a LogCategory system with user-selectable Diagnostics toggles + an app-tier boundary-logging audit (logs-only). Two pure deciders (tapAction, RenderSignature) Linux-tested. Follows Spec A (#81) + the mouse-gate fix (#83).

https://claude.ai/code/session_01VxDe5tUsrrkhgX9SSADJPp"
```

- [ ] **Step 4: macOS CI (App-tier gate)**

Run: `gh pr checks <PR#> --repo ds7n/semicolyn` until `macos` is `pass`. Fix any SwiftTerm API mismatch (esp. `selectionActive`/`selectNone`) and re-push.

- [ ] **Step 5: Merge + TestFlight + device verify**

After green + user approval: squash-merge, sync main, dispatch `release-testflight.yml`. On device with `.gesture`+`.tmux`+`.render` enabled: (a) a tap dismisses a selection; (b) renders fire only on real changes with a `reason=`; (c) tapping a window tab switches the active window (full hop trace). Confirm the category toggles filter the stream.

---

## Self-Review

**Spec coverage:**
- Layer 1 `LogCategory` + gate + defaults + Diagnostics toggles → Task 3. ✓
- Layer 2 Fix 1 clearSelection-on-tap (pure decider + wiring) → Task 1 + Task 4. ✓
- Layer 2 Fix 2 render-storm dedup (RenderSignature + gate) → Task 2 + Task 5. ✓
- Layer 2 Fix 3 window-tab instrument-then-fix → Task 6. ✓
- Layer 3 coverage audit (connect/tmux/gesture/render/seed) → Task 7; (input/predictor/keybar) → Task 8. ✓
- `.seed` recategorization → Task 7 Step 1. ✓
- Log-line style convention + `%N`/`@N` → applied in every log Task (4/5/6/7/8). ✓
- Category defaults ON/OFF split → Task 3 Step 1 (`defaultEnabled`). ✓
- Pure deciders in Kit, Linux-tested; App wiring device-gated → Tasks 1/2 (Kit) + Task 9. ✓
- Two-tier: Kit stays log-free (only App logs) → Layer 3 scope note honored (Tasks 7/8 are App-only). ✓

**Placeholder scan:** The `RenderSignature` test helpers (`win`/`makeState`) are marked "adapt to the real builder" with a concrete implementer note pointing at `TmuxSessionStateTests` — a genuine "use the existing construction API" seam, not a vague TODO. Fix 3's parse-vs-wiring fork and Fix 2's publish-gating are evidence/inspection-gated seams with the exact grep + stated fix per branch. No "add error handling"/"similar to Task N"/bare-TODO.

**Type consistency:** `tapAction(hasSelection:)->TapAction` (T1) used in T4. `RenderSignature(_:)` (T2) used in T5. `LogCategory` cases + `defaultOn`/`storageKey` + `DebugLog.log(_:_ :)`/`refreshEnabledCategories()` (T3) used in T3–T8. `selectionActive`/`selectNone()` (SwiftTerm public) in T4. `WindowID.raw`/`PaneID.raw` rendered `@N`/`%N` consistently. `selectWindow(_:)` (VM + runtime) in T6. Consistent.
