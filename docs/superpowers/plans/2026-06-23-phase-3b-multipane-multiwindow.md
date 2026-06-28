# Phase 3 Plan B — Multi-Pane + Multi-Window Render

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render a tmux window's **native pane layout** — one SwiftTerm view per leaf pane, positioned from `visibleLayout` geometry, with a bronze border on the active pane — and let the user **switch between tmux windows**, with the terminal size propagated back to tmux so it re-lays-out.

**Architecture:** Plan A attached `tmux -CC` and rendered only the active pane in the single `TerminalScreen`. Plan B generalizes: `TmuxRuntime` routes **every** pane's `%output` (keyed by `PaneID`) and publishes the `TmuxSessionState` so the UI reacts to layout/window changes. A pure `paneRects(in:cellWidth:cellHeight:)` function (SemicolynKit, Linux-tested) turns a `PaneLayout` into positioned rects; a new `TmuxPaneContainer` (UIKit-backed) hosts an N-`TerminalView` grid from those rects and feeds each pane its bytes; a window-tab strip drives `select-window`; container size changes send `refresh-client -C` so tmux re-tiles.

**Tech Stack:** Swift 6 `SemicolynKit` (pure geometry + command encoder, XCTest/Linux), the SwiftUI/UIKit app target + SwiftTerm + `SemicolynSSHCoreFFI` bridge (macOS-CI compile gate).

## Scope

**This plan (Phase 3 Plan B):**
- Pure `paneRects` geometry (cells → positioned rects) + `TmuxCommand.refreshClientSize` encoder — SemicolynKit, Linux-tested.
- `TmuxRuntime`: per-pane output routing + observable session state + `selectWindow` + `setClientSize`.
- `TmuxPaneContainer`: N SwiftTerm views laid out from `paneRects`, per-pane byte feed, **bronze border on the active pane**, input from the active pane.
- **Multi-window** navigation: a window-tab strip (per the user's "multi-window now" decision), tap → `select-window`.
- Resize-through-tmux: container/keyboard size changes → `refresh-client -C <cols>x<rows>` → tmux emits `%layout-change` → re-tile.

**Deferred (NOT this plan):**
- **Terminal feedback/UX polish → Plan C:** visual bell halo, haptic bell, mouse-mode passthrough + bronze-dot indicator, DECSCUSR cursor shape, per-pane pinch-to-zoom font, URL tap-to-open, OSC 52 clipboard, OSC 0/1/2 titles, port-forward status, Terminal settings sub-screen.
- **Manual pane switching** — per the user's decision, the active pane follows only tmux's own changes (no Semicolyn-side pane-switch gesture); the keybar "pane pill" is Phase 4. (Window switching IS in scope.)
- **Context-detection state machine + mid-session tmux-crash red banner → Plan D.**
- **Pane split/new-window/kill UI** (the encoders exist; the gestures/buttons are Phase 4 keybar / later).
- Zoomed-pane handling beyond honoring `visibleLayout` (tmux already collapses a zoomed window's `visibleLayout` to the single zoomed pane — the renderer just renders whatever `visibleLayout` contains, so zoom "works" for free; no zoom toggle UI here).

## File Structure

| File | Responsibility | Test surface |
|---|---|---|
| `Sources/SemicolynKit/Tmux/PaneRects.swift` *(create)* | pure `PaneRect` + `paneRects(in:cellWidth:cellHeight:)` (cells → rects) | Linux `swift test` |
| `Sources/SemicolynKit/Tmux/TmuxCommand.swift` *(modify)* | add `refreshClientSize(width:height:) -> String?` | Linux `swift test` |
| `App/TmuxRuntime.swift` *(modify)* | per-pane output routing, observable state, `selectWindow`, `setClientSize` | macOS compile |
| `App/TmuxPaneContainer.swift` *(create)* | `UIViewRepresentable` hosting N `TerminalView`s from `paneRects`, active border, per-pane feed + input | macOS compile |
| `App/WindowTabStrip.swift` *(create)* | SwiftUI strip of window tabs → `select-window` | macOS compile |
| `App/ConnectionViewModel.swift` *(modify)* | publish tmux state; route per-pane bytes; client-size on resize; expose `selectWindow` | macOS compile |
| `App/SessionView.swift` *(modify)* | in tmux mode show `WindowTabStrip` + `TmuxPaneContainer` instead of single `TerminalScreen` | macOS compile |

## Global Constraints

- Every source/test file begins with `// SPDX-FileCopyrightText: 2026 True Positive LLC` then `// SPDX-License-Identifier: GPL-3.0-only`.
- **No Apple-only APIs in `SemicolynKit`** — `PaneRects.swift` and the `TmuxCommand` addition are pure value-type Swift, Linux-tested (use plain `Double` rects, NOT `CGRect` — CoreGraphics is unavailable on Linux). UIKit/SwiftTerm/FFI code lives only in `App/`.
- **No inline hex in UI — colors only via theme tokens** (`Color(theme.…)`). The active-pane border uses the bronze accent token (`theme.accent.primary` — confirm the exact path in `Sources/SemicolynKit/Theme`).
- **Tmux owns geometry.** Semicolyn never guesses layout; it renders `TmuxWindow.visibleLayout` exactly and tells tmux its client size via `refresh-client -C` so tmux recomputes. Pane geometry is in **cells** (`Geometry.w/h/x/y: UInt16`); the renderer multiplies by the cell metrics.
- Input goes to tmux's **active pane** only (`send-keys -t <activePane>`); the active pane is whatever tmux reports (`TmuxWindow.activePane`), never chosen Semicolyn-side in this plan.
- Reuse the existing `TmuxSessionController`/`TmuxCommand`/`TmuxSessionState` — do not re-implement parsing or state.
- Testing tier: **Core** for `paneRects` (EP + BVA, exact rects for single/h-split/v-split/2×2) and `refreshClientSize` (good + bad, exact string). App views are macOS-compile-gated (no unit tests).
- Conventional commits; commit after every green step. Branch `feat/phase-3b-multipane`; squash-merge at the end. `cargo fmt` is irrelevant here (no Rust changes) but run the full `swift test` before pushing.

---

### Task 0: Branch + plan doc

- [ ] **Step 1: Create the feature branch**

```bash
git checkout -b feat/phase-3b-multipane
```

- [ ] **Step 2: Commit the plan doc**

```bash
git add docs/superpowers/plans/2026-06-23-phase-3b-multipane-multiwindow.md
git commit -m "docs: Phase 3 Plan B — multi-pane + multi-window render plan"
```

---

### Task 1: Pure pane-geometry mapping (`paneRects`)

Turn a `PaneLayout` into positioned rectangles in pixels, given cell metrics. Pure SemicolynKit, Linux-tested — the heart of multi-pane layout.

**Files:**
- Create: `Sources/SemicolynKit/Tmux/PaneRects.swift`
- Test: `Tests/SemicolynKitTests/PaneRectsTests.swift`

**Interfaces:**
- Consumes (exist): `PaneLayout` + its `.panes: [(pane: PaneID, geometry: Geometry)]`, `Geometry(w/h/x/y: UInt16)`, `PaneID(raw: UInt32)`.
- Produces (consumed by Task 4):
  - `public struct PaneRect: Equatable, Sendable { public let pane: PaneID; public let x: Double; public let y: Double; public let width: Double; public let height: Double }`
  - `public func paneRects(in layout: PaneLayout, cellWidth: Double, cellHeight: Double) -> [PaneRect]` — for each leaf pane, `x = geo.x*cellWidth`, `y = geo.y*cellHeight`, `width = geo.w*cellWidth`, `height = geo.h*cellHeight`, preserving `.panes` order.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SemicolynKitTests/PaneRectsTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class PaneRectsTests: XCTestCase {
    private let cw = 8.0, ch = 16.0

    func testSinglePaneFillsWindow() {
        let layout = PaneLayout.leaf(PaneID(raw: 0), Geometry(w: 80, h: 24, x: 0, y: 0))
        XCTAssertEqual(paneRects(in: layout, cellWidth: cw, cellHeight: ch),
                       [PaneRect(pane: PaneID(raw: 0), x: 0, y: 0, width: 640, height: 384)])
    }

    func testSideBySideSplitColumns() {
        // 80x24 window split into two 40-wide columns (divider ignored; panes abut).
        let left  = PaneLayout.leaf(PaneID(raw: 1), Geometry(w: 40, h: 24, x: 0,  y: 0))
        let right = PaneLayout.leaf(PaneID(raw: 2), Geometry(w: 40, h: 24, x: 41, y: 0))
        let layout = PaneLayout.columns([left, right], Geometry(w: 80, h: 24, x: 0, y: 0))
        XCTAssertEqual(paneRects(in: layout, cellWidth: cw, cellHeight: ch), [
            PaneRect(pane: PaneID(raw: 1), x: 0,   y: 0, width: 320, height: 384),
            PaneRect(pane: PaneID(raw: 2), x: 328, y: 0, width: 320, height: 384),
        ])
    }

    func testStackedSplitRows() {
        let top    = PaneLayout.leaf(PaneID(raw: 1), Geometry(w: 80, h: 12, x: 0, y: 0))
        let bottom = PaneLayout.leaf(PaneID(raw: 2), Geometry(w: 80, h: 11, x: 0, y: 13))
        let layout = PaneLayout.rows([top, bottom], Geometry(w: 80, h: 24, x: 0, y: 0))
        XCTAssertEqual(paneRects(in: layout, cellWidth: cw, cellHeight: ch), [
            PaneRect(pane: PaneID(raw: 1), x: 0, y: 0,   width: 640, height: 192),
            PaneRect(pane: PaneID(raw: 2), x: 0, y: 208, width: 640, height: 176),
        ])
    }

    func testNestedGridPreservesOrderAndGeometry() {
        // Left column is itself a 2-row stack → 3 leaves total.
        let lt = PaneLayout.leaf(PaneID(raw: 1), Geometry(w: 40, h: 12, x: 0, y: 0))
        let lb = PaneLayout.leaf(PaneID(raw: 2), Geometry(w: 40, h: 11, x: 0, y: 13))
        let leftCol = PaneLayout.rows([lt, lb], Geometry(w: 40, h: 24, x: 0, y: 0))
        let right = PaneLayout.leaf(PaneID(raw: 3), Geometry(w: 39, h: 24, x: 41, y: 0))
        let layout = PaneLayout.columns([leftCol, right], Geometry(w: 80, h: 24, x: 0, y: 0))
        let rects = paneRects(in: layout, cellWidth: cw, cellHeight: ch)
        XCTAssertEqual(rects.map(\.pane), [PaneID(raw: 1), PaneID(raw: 2), PaneID(raw: 3)])
        XCTAssertEqual(rects[2], PaneRect(pane: PaneID(raw: 3), x: 328, y: 0, width: 312, height: 384))
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
docker compose run --rm dev swift test --filter PaneRectsTests
```

Expected: FAIL — `PaneRect`/`paneRects` undefined.

- [ ] **Step 3: Implement `PaneRects.swift`**

```swift
// Sources/SemicolynKit/Tmux/PaneRects.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// A leaf pane positioned in pixels (no CoreGraphics dependency — the App layer
/// converts to `CGRect`). Cell coordinates × cell metrics, top-left origin.
public struct PaneRect: Equatable, Sendable {
    public let pane: PaneID
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public init(pane: PaneID, x: Double, y: Double, width: Double, height: Double) {
        self.pane = pane; self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// Map each leaf pane of `layout` to a pixel rect, given the terminal cell size.
/// tmux reports absolute cell geometry per leaf, so this is a direct scale; the
/// 1-cell divider tmux reserves between panes is left as a visual gap (the App
/// draws a 1pt border, so abutting rects read as separate panes). Order matches
/// `PaneLayout.panes` (depth-first, the order tmux lists panes).
public func paneRects(in layout: PaneLayout, cellWidth: Double, cellHeight: Double) -> [PaneRect] {
    layout.panes.map { entry in
        PaneRect(
            pane: entry.pane,
            x: Double(entry.geometry.x) * cellWidth,
            y: Double(entry.geometry.y) * cellHeight,
            width: Double(entry.geometry.w) * cellWidth,
            height: Double(entry.geometry.h) * cellHeight
        )
    }
}
```

- [ ] **Step 4: Run to verify pass**

```bash
docker compose run --rm dev swift test --filter PaneRectsTests
```

Expected: PASS (4/4).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Tmux/PaneRects.swift Tests/SemicolynKitTests/PaneRectsTests.swift
git commit -m "feat: pure pane-layout → positioned-rects geometry"
```

---

### Task 2: `refresh-client -C` resize encoder

The control-mode way to tell tmux the client's size so it re-tiles. tmux replies with `%layout-change`.

**Files:**
- Modify: `Sources/SemicolynKit/Tmux/TmuxCommand.swift`
- Test: `Tests/SemicolynKitTests/TmuxCommandTests.swift` (create if absent; otherwise add a method to the existing class)

**Interfaces:**
- Produces (consumed by Task 3): `public static func refreshClientSize(width: Int, height: Int) -> String?` — `"refresh-client -C \(width)x\(height)"`; nil unless both ≥ 1.

- [ ] **Step 1: Write the failing test**

If `Tests/SemicolynKitTests/TmuxCommandTests.swift` does not exist, create it; if it exists, add this method to the existing `TmuxCommandTests` class instead.

```swift
// Tests/SemicolynKitTests/TmuxCommandTests.swift  (create OR add the method)
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class TmuxCommandTests: XCTestCase {
    func testRefreshClientSizeEncodesAndGuards() {
        XCTAssertEqual(TmuxCommand.refreshClientSize(width: 80, height: 24), "refresh-client -C 80x24")
        XCTAssertEqual(TmuxCommand.refreshClientSize(width: 1, height: 1), "refresh-client -C 1x1")  // min
        XCTAssertNil(TmuxCommand.refreshClientSize(width: 0, height: 24))                              // min-1
        XCTAssertNil(TmuxCommand.refreshClientSize(width: 80, height: 0))
        XCTAssertNil(TmuxCommand.refreshClientSize(width: -5, height: 24))
    }
}
```

> If a `TmuxCommandTests` class already exists with this exact name, do NOT create a duplicate type — add `testRefreshClientSizeEncodesAndGuards` to it.

- [ ] **Step 2: Run to verify failure**

```bash
docker compose run --rm dev swift test --filter TmuxCommandTests
```

Expected: FAIL — `refreshClientSize` undefined.

- [ ] **Step 3: Add the encoder**

In `Sources/SemicolynKit/Tmux/TmuxCommand.swift`, add inside the `TmuxCommand` enum (next to `resizePane`):

```swift
    /// Tell tmux the control-client's size in cells so it re-tiles all windows.
    /// tmux responds with `%layout-change`. Returns nil unless both are ≥ 1.
    public static func refreshClientSize(width: Int, height: Int) -> String? {
        guard width >= 1, height >= 1 else { return nil }
        return "refresh-client -C \(width)x\(height)"
    }
```

- [ ] **Step 4: Run to verify pass**

```bash
docker compose run --rm dev swift test --filter TmuxCommandTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Tmux/TmuxCommand.swift Tests/SemicolynKitTests/TmuxCommandTests.swift
git commit -m "feat: refresh-client -C resize encoder for control-mode reflow"
```

---

### Task 3: Generalize `TmuxRuntime` to all panes + observable state

Plan A's `TmuxRuntime` routes only the active pane and exposes no structural state. Generalize it: route **every** pane's bytes (keyed by `PaneID`), publish the `TmuxSessionState` on change, and add `selectWindow` + `setClientSize`.

**Files:**
- Modify: `App/TmuxRuntime.swift`

**Interfaces:**
- Consumes: `TmuxControllerOutput.paneOutput: [PaneOutputChunk]` (`.pane`/`.data`), `controller.state: TmuxSessionState`, `TmuxControllerOutput.stateChanged`, `TmuxCommand.selectWindow(target:)`, `TmuxCommand.refreshClientSize(width:height:)` (Task 2), `TmuxCommand.sendKeys`, `WindowID`, `PaneID`.
- Produces (consumed by Tasks 4/5):
  - replace `var onActivePaneBytes` with `var onPaneBytes: ((PaneID, [UInt8]) -> Void)?` (fires for EVERY chunk).
  - `var onStateChanged: ((TmuxSessionState) -> Void)?` (fires after a `feed` whose `stateChanged` is true).
  - `var state: TmuxSessionState { controller.state }` (read-only accessor).
  - `func selectWindow(_ id: WindowID)` — submit `select-window` + write.
  - `func setClientSize(cols: Int, rows: Int)` — submit `refresh-client -C` (guarded) + write.
  - keep `session`, `onExit`, `makeStartCommand()`, `ingest(_:)`, `sendInput(_:)` (input still targets `activePane`).

- [ ] **Step 1: Rewrite the routing + add the new surface**

Replace the body of `App/TmuxRuntime.swift` with:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SemicolynKit
import SemicolynSSHCoreFFI

/// Drives a tmux control-mode session in the app: feeds inbound channel bytes to
/// the pure `TmuxSessionController`, fans every pane's output out by `PaneID`,
/// publishes structural state for the renderer, and encodes input/commands.
@MainActor
final class TmuxRuntime {
    private let controller = TmuxSessionController()
    private let sessionName: String

    /// The live control-mode channel; assigned after `open_exec`.
    var session: ShellSession?

    /// Output bytes for a specific pane, keyed by `PaneID`. Fires for every chunk.
    var onPaneBytes: ((PaneID, [UInt8]) -> Void)?
    /// Fired after any `feed` that changed structural state (windows/layout/active).
    var onStateChanged: ((TmuxSessionState) -> Void)?
    /// Fired when control mode ends; carries the exit reason if any.
    var onExit: ((String?) -> Void)?

    init(sessionName: String) { self.sessionName = sessionName }

    /// The current structural state (windows, layouts, active window/pane).
    var state: TmuxSessionState { controller.state }

    /// The `tmux -CC new-session -A -s <name>` command to run via `open_exec`.
    func makeStartCommand() -> String? { controller.start(sessionName: sessionName) }

    /// Feed raw channel bytes: fan pane output out by id, then publish state.
    func ingest(_ bytes: [UInt8]) {
        let out = controller.feed(bytes)
        for chunk in out.paneOutput { onPaneBytes?(chunk.pane, chunk.data) }
        if out.stateChanged { onStateChanged?(controller.state) }
        if out.lifecycleChanged, case .exited(let reason) = controller.lifecycle { onExit?(reason) }
    }

    /// Encode keystrokes as `send-keys` to the active pane and write to the channel.
    func sendInput(_ bytes: [UInt8]) {
        guard let pane = activePane,
              let line = TmuxCommand.sendKeys(target: pane, bytes: bytes) else { return }
        write(line)
    }

    /// Make `id` the active window (tmux will emit the layout/active events).
    func selectWindow(_ id: WindowID) {
        write(TmuxCommand.selectWindow(target: id))
    }

    /// Tell tmux the client size in cells so it re-tiles; ignored if degenerate.
    func setClientSize(cols: Int, rows: Int) {
        guard let line = TmuxCommand.refreshClientSize(width: cols, height: rows) else { return }
        write(line)
    }

    /// Submit a command line and write its framed bytes to the channel.
    private func write(_ line: String) {
        guard let sub = controller.submit(line), let session else { return }
        Task { try? await session.write(data: Data(sub.wire)) }
    }

    /// The active pane of the active window (nil until the first layout/window event).
    private var activePane: PaneID? {
        guard let win = controller.state.activeWindow else { return nil }
        return controller.state.window(win)?.activePane
    }
}
```

> Note the shared private `write(_:)` removes the prior duplication between `sendInput` and the new commands. Confirm `ShellSession.write(data:)` is `async throws` (it is — Plan A uses it).

- [ ] **Step 2: Compile-gate (macOS CI) + commit**

This breaks the Plan-A call-site in `ConnectionViewModel` that set `onActivePaneBytes` — Task 5 updates it. Commit now as the runtime layer:

```bash
git add App/TmuxRuntime.swift
git commit -m "feat: TmuxRuntime fans all panes + publishes state + window/resize commands"
```

> The app target will NOT fully compile until Task 5 rewires `ConnectionViewModel`. That's expected — the macOS CI gate runs after Task 5 (the cluster of app changes compiles together). Note this in the report so the reviewer knows the intermediate state.

---

### Task 4: `TmuxPaneContainer` — N SwiftTerm views from the layout

A `UIViewRepresentable` that renders the active window's panes: one `TerminalView` per leaf pane, positioned by `paneRects`, fed its own bytes, with a bronze border on the active pane. Input from the active pane routes to the view model.

**Files:**
- Create: `App/TmuxPaneContainer.swift`

**Interfaces:**
- Consumes: `paneRects(in:cellWidth:cellHeight:)` + `PaneRect` (Task 1), `TmuxSessionState` (`.activeWindow`, `.window(_:)`, `TmuxWindow.visibleLayout`, `.activePane`), `PaneID`, SwiftTerm `TerminalView`, a theme bronze token, and two closures from the view model: `send: ([UInt8]) -> Void` (active-pane input) and a pane-registration hook so the VM can deliver bytes.
- Produces (consumed by Task 5): `struct TmuxPaneContainer: UIViewRepresentable` taking `state: TmuxSessionState`, `register: (PaneID, TerminalView) -> Void`, `unregister: (PaneID) -> Void`, `send: ([UInt8]) -> Void`, `theme: Theme`.

- [ ] **Step 1: Implement the container**

The container owns a `[PaneID: TerminalView]` and reconciles it against the active window's `visibleLayout` on each SwiftUI update. The VM (Task 5) holds the authoritative pane→view registry so it can feed bytes; this view registers/unregisters views as panes appear/disappear.

```swift
// App/TmuxPaneContainer.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SwiftTerm
import SemicolynKit

/// Renders the active tmux window's panes as a grid of SwiftTerm `TerminalView`s,
/// positioned from `paneRects(in:visibleLayout)`. The active pane gets a bronze
/// border and owns keyboard input; the rest are display-only. Pane output is
/// delivered by the view model via the registered `TerminalView` handles.
struct TmuxPaneContainer: UIViewRepresentable {
    let state: TmuxSessionState
    /// Called when a pane's `TerminalView` is created, so the VM can feed it bytes.
    let register: (PaneID, TerminalView) -> Void
    /// Called when a pane disappears, so the VM drops its handle.
    let unregister: (PaneID) -> Void
    /// Active-pane keystrokes/paste bytes → remote.
    let send: ([UInt8]) -> Void
    let theme: Theme

    func makeCoordinator() -> Coordinator { Coordinator(send: send) }

    func makeUIView(context: Context) -> ContainerView {
        let v = ContainerView()
        v.coordinator = context.coordinator
        return v
    }

    func updateUIView(_ uiView: ContainerView, context: Context) {
        uiView.apply(state: state, register: register, unregister: unregister,
                     borderColor: UIColor(Color(theme.accent.primary)))
    }

    /// Bridges SwiftTerm input from whichever pane is active to the VM.
    final class Coordinator: NSObject, TerminalViewDelegate {
        private let send: ([UInt8]) -> Void
        init(send: @escaping ([UInt8]) -> Void) { self.send = send }
        func send(source: TerminalView, data: ArraySlice<UInt8>) { send(Array(data)) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}  // tmux owns geometry
        func scrolled(source: TerminalView, position: Double) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    /// UIKit container that lays out one `TerminalView` per pane and tracks the set.
    final class ContainerView: UIView {
        weak var coordinator: Coordinator?
        private var panes: [PaneID: TerminalView] = [:]

        /// Cell metrics from a sample terminal's font (monospace → uniform cell).
        private func cellSize(_ sample: TerminalView) -> (w: Double, h: Double) {
            let f = sample.font
            let w = "W".size(withAttributes: [.font: f]).width
            let h = sample.frame.height > 0 && sample.getTerminal().rows > 0
                ? sample.frame.height / Double(sample.getTerminal().rows)
                : f.lineHeight
            return (Double(w), Double(h))
        }

        func apply(state: TmuxSessionState,
                   register: (PaneID, TerminalView) -> Void,
                   unregister: (PaneID) -> Void,
                   borderColor: UIColor) {
            guard let win = state.activeWindow, let window = state.window(win),
                  let layout = window.visibleLayout else { return }

            // Derive cell metrics from any existing pane (or a throwaway sample).
            let sample = panes.values.first ?? TerminalView(frame: bounds)
            let cell = cellSize(sample)
            let rects = paneRects(in: layout, cellWidth: cell.w, cellHeight: cell.h)
            let live = Set(rects.map(\.pane))

            // Remove panes tmux no longer reports.
            for (id, view) in panes where !live.contains(id) {
                view.removeFromSuperview(); unregister(id); panes[id] = nil
            }

            // Create/position each pane; border the active one.
            for rect in rects {
                let view = panes[rect.pane] ?? {
                    let t = TerminalView(frame: .zero)
                    t.terminalDelegate = coordinator
                    addSubview(t); panes[rect.pane] = t; register(rect.pane, t)
                    return t
                }()
                view.frame = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
                let isActive = (rect.pane == window.activePane)
                view.layer.borderColor = borderColor.cgColor
                view.layer.borderWidth = isActive ? 1.5 : 0
                if isActive { view.becomeFirstResponder() }
            }
        }
    }
}
```

> macOS-only / CI-gated. Verify SwiftTerm's `TerminalView` API names against the Plan-A `TerminalScreen.swift` usage (`.font`, `.getTerminal()`, `.feed(byteArray:)`, `.terminalDelegate`). If `getTerminal().rows` isn't available, fall back to `f.lineHeight` for cell height (the comment shows the fallback). The cell-size derivation is approximate for v1; per-pane pinch-zoom font is Plan C. Confirm `UIColor(Color(theme.accent.primary))` is the right token path from `Sources/SemicolynKit/Theme`.

- [ ] **Step 2: Compile-gate (macOS CI) + commit**

```bash
git add App/TmuxPaneContainer.swift
git commit -m "feat: TmuxPaneContainer — native multi-pane grid from tmux layout"
```

---

### Task 5: Window-tab strip + wire tmux mode into the session UI

Show a window-tab strip and the `TmuxPaneContainer` in tmux mode, route per-pane bytes from the runtime to the registered views, send the client size on layout/size changes, and drive `select-window` on tab tap. Raw-PTY mode keeps the single `TerminalScreen`.

**Files:**
- Create: `App/WindowTabStrip.swift`
- Modify: `App/ConnectionViewModel.swift`
- Modify: `App/SessionView.swift`

**Interfaces:**
- Consumes: `TmuxRuntime` (Task 3: `onPaneBytes`, `onStateChanged`, `state`, `selectWindow`, `setClientSize`), `TmuxPaneContainer` (Task 4), `TmuxSessionState`/`TmuxWindow`/`WindowID`/`PaneID`, SwiftTerm `TerminalView.feed(byteArray:)`.
- Produces:
  - `struct WindowTabStrip: View` taking `windows: [TmuxWindow]`, `active: WindowID?`, `onSelect: (WindowID) -> Void`.
  - on `ConnectionViewModel`: `@Published var tmuxState: TmuxSessionState?` (nil in raw mode), `func selectWindow(_:)`, `func setTmuxClientSize(cols:rows:)`, and a pane registry `registerPane(_:_:)` / `unregisterPane(_:)` that feeds `onPaneBytes` into the right `TerminalView`.

- [ ] **Step 1: Wire the runtime's per-pane output to a pane registry in `attachTmux`**

In `App/ConnectionViewModel.swift`, add a pane-view registry and publish state. Add stored state:

```swift
    @Published var tmuxState: TmuxSessionState?
    /// PaneID → live SwiftTerm view, populated by TmuxPaneContainer as panes appear.
    private var paneViews: [PaneID: TerminalView] = [:]
    private var pendingPaneBytes: [PaneID: [UInt8]] = [:]   // bytes that arrived before the view registered
```

In `attachTmux(conn:)` (from Plan A), replace the `runtime.onActivePaneBytes = …` line with per-pane routing + state publishing:

```swift
        runtime.onPaneBytes = { [weak self] pane, bytes in
            guard let self else { return }
            if let view = self.paneViews[pane] {
                view.feed(byteArray: bytes[...])
            } else {
                self.pendingPaneBytes[pane, default: []].append(contentsOf: bytes)  // buffer until registered
            }
        }
        runtime.onStateChanged = { [weak self] state in self?.tmuxState = state }
        runtime.onExit = { [weak self] reason in self?.state = .failed(reason ?? "tmux session ended") }
```

Add the registry + command methods to `ConnectionViewModel`:

```swift
    /// Called by TmuxPaneContainer when a pane's view is created. Flushes any
    /// bytes that arrived before the view existed.
    func registerPane(_ pane: PaneID, _ view: TerminalView) {
        paneViews[pane] = view
        if let buffered = pendingPaneBytes[pane] {
            view.feed(byteArray: buffered[...]); pendingPaneBytes[pane] = nil
        }
    }
    func unregisterPane(_ pane: PaneID) { paneViews[pane] = nil; pendingPaneBytes[pane] = nil }

    func selectWindow(_ id: WindowID) { tmux?.selectWindow(id) }
    func setTmuxClientSize(cols: Int, rows: Int) { tmux?.setClientSize(cols: cols, rows: rows) }
```

> `tmux` is the `private var tmux: TmuxRuntime?` from Plan A. Keep the input path: `sendTerminalInput` already routes to `tmux?.sendInput` when attached (Plan A). Set `tmuxState = nil` in `openRawShell` so raw mode shows the single terminal.

- [ ] **Step 2: Implement `WindowTabStrip`**

```swift
// App/WindowTabStrip.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// A horizontal strip of tmux window tabs (temporary, until the Phase-4 keybar
/// window pill). Tap a tab to `select-window`; the active window is bronze-tinted.
struct WindowTabStrip: View {
    let windows: [TmuxWindow]
    let active: WindowID?
    let onSelect: (WindowID) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(windows, id: \.id) { win in
                    let isActive = win.id == active
                    Button { onSelect(win.id) } label: {
                        Text(win.name.isEmpty ? "@\(win.id.raw)" : win.name)
                            .font(.caption.monospaced())
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(isActive ? Color(theme.accent.primary).opacity(0.18) : Color.clear)
                            .foregroundStyle(isActive ? Color(theme.accent.primary) : Color(theme.text.secondary))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
        }
    }
}
```

> Confirm `WindowID.raw` is accessible (it's `public let raw: UInt32`) and the theme token paths (`theme.accent.primary`, `theme.text.secondary`) against `Sources/SemicolynKit/Theme`.

- [ ] **Step 3: Show the strip + pane container in tmux mode in `SessionView`**

In `App/SessionView.swift`, where the `.shell` state currently shows `TerminalScreen`, branch on `vm.tmuxState`:

```swift
            if case .shell = vm.state {
                if let tmuxState = vm.tmuxState {
                    VStack(spacing: 0) {
                        WindowTabStrip(windows: tmuxState.windows, active: tmuxState.activeWindow,
                                       onSelect: { vm.selectWindow($0) })
                        TmuxPaneContainer(
                            state: tmuxState,
                            register: { vm.registerPane($0, $1) },
                            unregister: { vm.unregisterPane($0) },
                            send: { vm.sendTerminalInput($0) },
                            theme: theme)
                        .background(GeometryReader { geo in
                            Color.clear.onAppear { vm.sendApproxClientSize(width: geo.size.width, height: geo.size.height) }
                                .onChange(of: geo.size) { _, new in vm.sendApproxClientSize(width: new.width, height: new.height) }
                        })
                    }
                } else {
                    TerminalScreen(send: { vm.sendTerminalInput($0) }, output: vm.output, session: vm.session)
                }
            }
```

Add a helper on `ConnectionViewModel` that converts a pixel size to an approximate cell count and sends it (cell size ~ 8×16pt for the default font; this is a coarse v1 estimate — the exact metric lives in the container, but tmux just needs a close size to tile):

```swift
    /// Convert the container's pixel size to an approximate cell grid and push it
    /// to tmux so it re-tiles. ~8×16pt per cell for the default monospace font.
    func sendApproxClientSize(width: Double, height: Double) {
        let cols = max(1, Int(width / 8.0)); let rows = max(1, Int(height / 16.0))
        setTmuxClientSize(cols: cols, rows: rows)
    }
```

> Match the exact existing `SessionView` structure (Plan A’s overlay/banner stay). Keep the degraded banner overlay from Plan A. Confirm `theme` is in scope in `SessionView` (`@Environment(\.theme)`).

- [ ] **Step 4: Compile-gate (macOS CI) + commit**

```bash
git add App/WindowTabStrip.swift App/ConnectionViewModel.swift App/SessionView.swift
git commit -m "feat: window-tab strip + multi-pane container wired into tmux session UI"
```

---

### Task 6: CI gate, docs, and final review

- [ ] **Step 1: Push, open PR, confirm CI green**

```bash
git push -u github feat/phase-3b-multipane
gh pr create --draft --base main --title "feat: Phase 3 Plan B — multi-pane + multi-window render" \
  --body "Render a tmux window's native pane layout (N SwiftTerm views, active-pane bronze border), switch windows via a tab strip, resize via refresh-client -C. Pure paneRects geometry + refresh-client encoder Linux-tested; app wiring macOS-gated. Bell/mouse/font/URL polish → Plan C. See plan doc."
```

Confirm `linux-swift` (incl. `PaneRectsTests` + `TmuxCommandTests`), `linux-rust`, `lint`, and `macos` (app build with all new App files) are green. Re-run `linux-rust` once if it hits the known sshd-readiness flake. **Watch for macOS-only errors** (missing `import SemicolynSSHCoreFFI` / SwiftTerm API name mismatches) — fix and re-push.

- [ ] **Step 2: Update docs**

Update `README.md` Phase 3 row: Plan B (multi-pane + multi-window render) done; UX polish (Plan C) + context/crash (Plan D) pending.

```bash
git add README.md
git commit -m "docs: Phase 3 Plan B status — multi-pane + multi-window render"
```

- [ ] **Step 3: Run `superpowers:requesting-code-review`** on the full branch; resolve Critical/Important; commit fixes.

- [ ] **Step 4: Squash-merge** once CI green and review clean; delete the branch.

## Self-Review (author checklist — completed)

- **Spec coverage:** pane layout → native grid (terminal-emulator-scope: one TerminalView per pane) → Tasks 1/4; active-pane bronze border (terminal-feedback references the active border) → Task 4; multi-window navigation (user decision "multi-window now") → Tasks 3/5; resize-through-tmux (terminal-ux-additions resize policy) → Tasks 2/3/5. Bell halo, mouse dot, DECSCUSR, font pinch, URL, OSC, titles, settings explicitly **deferred to Plan C**; manual pane switching deferred (user decision); context-SM + crash banner → Plan D — all noted in Scope, not gaps.
- **Placeholder scan:** the cell-size derivation (Task 4) and approx client-size (Task 5 `sendApproxClientSize`) are documented v1 approximations with the exact formula given, not TODOs. SwiftTerm/theme API names are flagged "confirm against the real file" with the Plan-A usage as the reference — verification directives, not placeholders. No "TBD"/"handle edge cases".
- **Type consistency:** `PaneRect`/`paneRects` (Task 1) consumed in Task 4; `refreshClientSize` (Task 2) consumed in Task 3 (`setClientSize`); `TmuxRuntime.onPaneBytes`/`onStateChanged`/`selectWindow`/`setClientSize`/`state` (Task 3) consumed in Tasks 4/5; `TmuxPaneContainer(state:register:unregister:send:theme:)` (Task 4) consumed in Task 5; `ConnectionViewModel.registerPane/unregisterPane/selectWindow/setTmuxClientSize/sendApproxClientSize/tmuxState` (Task 5) consumed in `SessionView`.
- **Cross-task compile note:** Task 3 intentionally breaks the Plan-A `onActivePaneBytes` call-site; the app target only fully compiles after Task 5. The macOS CI gate therefore runs after Task 5 (Task 6), not per-app-task — flagged in Task 3.
- **Open verification points flagged inline:** SwiftTerm `TerminalView` API (`.font`/`.getTerminal().rows`/`.feed(byteArray:)`/`.becomeFirstResponder()`), theme token paths (`accent.primary`/`text.secondary`), `WindowID.raw`/`PaneID.raw` access, and the `SessionView` insertion point.
