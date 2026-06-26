<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Phase 4b — Context Promotions + Fn Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the keybar's scroll region context-aware: render the engaged process's promotion set as bronze slots, and add an Fn slot that toggles an F1–F12 layer (manually, and auto-engaged in `htop`/`top`/`mc`).

**Architecture:** Continue the 4a pattern — push logic into pure, Linux-tested NeotildeKit, keep the App tier a thin render/wire layer. New pure cores: F-key encoding (`KeyInput.function`), an `FnState` machine (caps-lock semantics + context auto-engage + per-episode user-override), an `AutoFnCatalog` (bundled `htop`/`top`/`mc`), and a `keybarScrollItems(...)` content model that resolves promotions-vs-F-keys-vs-defaults. The App consumes Plan-D's `paneContexts` observable + `PromotionRegistry` to drive promotions, wires context transitions to Fn auto-engage, and reads per-pane DECCKM to replace 4a's hard-coded `applicationCursorKeys: { false }`.

**Tech Stack:** Swift 6 strict concurrency, XCTest on the Linux fast loop (pure cores); SwiftUI + SwiftTerm + the existing `KeybarInputRouter`/`paneContexts` for the App tier (macOS-CI-build-validated only).

## Verification reality (unchanged from 4a)

Pure cores (Tasks 1–3) are fully Linux-tested. App tasks (4–5) compile only on the macOS CI job, which **builds but does not run a Simulator** — promotion-slot appearance/disappearance, the Fn-mode cross-fade, and bronze styling are **not** verifiable by this toolchain; they need a Simulator/device pass (owed since 4a). App tasks deliver compile-correct, logic-tested wiring.

## Global Constraints

- **Two tiers:** pure logic in `Sources/NeotildeKit/` (no `import UIKit`/`SwiftUI`/`CryptoKit`, `Sendable`); App in `App/` (macOS-CI build only).
- **Specs locked:** `docs/superpowers/specs/2026-06-14-function-keys-design.md` (Fn) and `docs/superpowers/specs/2026-06-14-context-detection-design.md` §"Keybar integration" (promotions).
- **Fn state machine (verbatim, caps-lock semantics):** Off → (single tap) Armed → (any F-key fires) Off; Off → (double-tap) Locked; Armed → (second tap) Locked; Locked → (single tap) Off; firing F-keys while Locked does NOT exit.
- **Auto-engage (verbatim):** in `htop`/`top`/`mc`, the context machine auto-enters **Locked** on the 250 ms engage; returns to **Off** on the 1500 ms disengage. Per-pane, per-episode `fnUserOverride`: if the user single-taps Fn off while context has it locked, set the flag → stays Off for the rest of that episode (auto-engage will not re-lock). Resets when the context disengages-then-re-engages, the pane is switched away and back, or the user manually re-locks.
- **Promotions ↔ Fn are mutually exclusive on the scroll surface; F-key mode wins** if both ever apply (no such overlap in the v1 bundled lists — `htop`/`top`/`mc` have no promotion sets).
- **Bundled auto-Fn list (verbatim):** `htop`, `top`, `mc` — and NOT `vim`/`nvim`/`nano`/`pico`/`lazygit`.
- **F-key range:** F1–F12 only.
- **Theme tokens:** promoted slots use `theme.keybar.slotBgPromoted`; Fn Armed = `slotBgArmed`, Fn Locked = `slotBgLocked`; F-keys use plain `slotBg`. Never inline hex.
- **SPDX header on every new file.** Conventional commits; branch `feat/phase-4b-promotions-fn`; squash-merge.
- **Test commands:** `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <Suite>`.

---

## File Structure

**Created (NeotildeKit, Linux-tested):**
- `Sources/NeotildeKit/Keybar/FnState.swift` — `FnMode`, `FnState` machine.
- `Sources/NeotildeKit/Keybar/AutoFnCatalog.swift` — bundled auto-Fn process set + override merge.
- `Sources/NeotildeKit/Keybar/KeybarScrollContent.swift` — `KeybarScrollItem`, `keybarScrollItems(...)`.

**Modified (NeotildeKit):**
- `Sources/NeotildeKit/Keybar/KeyEncoding.swift` — add `KeyInput.function(Int)` + F1–F12 encoding.
- `Sources/NeotildeKit/Keybar/KeybarInputRouter.swift` — add `tapFKey(_:)`.

**Created (App, macOS-CI-only):**
- `App/Keybar/PromotionSlotView.swift` — bronze promotion slot + Fn slot + F-key slot views.

**Modified (App):**
- `App/Keybar/KeybarView.swift` — compute the scroll region from `keybarScrollItems` (promotions / F-keys / defaults + Fn).
- `App/ConnectionViewModel.swift` — `promotionRegistry`/`activePromotions`, `fnState` + gestures, context→auto-engage wiring, per-pane DECCKM closure.

**Tests created:** `FnStateTests`, `AutoFnCatalogTests`, `KeybarScrollContentTests`; `KeyEncodingTests`/`KeybarInputRouterTests` extended.

---

## Setup

- [ ] **Step 0: Branch**

```bash
cd /home/user/proj/truepositive/neotilde
git checkout -b feat/phase-4b-promotions-fn
```

---

### Task 1: F-key support (encoding + router)

**Files:**
- Modify: `Sources/NeotildeKit/Keybar/KeyEncoding.swift`
- Modify: `Sources/NeotildeKit/Keybar/KeybarInputRouter.swift`
- Test: `Tests/NeotildeKitTests/KeyEncodingTests.swift` (extend), `Tests/NeotildeKitTests/KeybarInputRouterTests.swift` (extend)

**Interfaces:**
- Produces: `KeyInput.function(Int)` case; `encodeKey` returns F1–F4 as SS3 (`ESC O P/Q/R/S`), F5–F12 as CSI (`ESC [ 15~/17~/18~/19~/20~/21~/23~/24~`), out-of-range → `[]`; `KeybarInputRouter.tapFKey(_ n: Int)` fires `.function(n)`. (MVP: modifiers do not alter F-keys.)

- [ ] **Step 1: Write the failing tests**

Append to `Tests/NeotildeKitTests/KeyEncodingTests.swift`:

```swift
    func testFunctionKeysSS3AndCSI() {
        XCTAssertEqual(enc(.function(1)),  Array("\u{1b}OP".utf8))
        XCTAssertEqual(enc(.function(4)),  Array("\u{1b}OS".utf8))
        XCTAssertEqual(enc(.function(5)),  Array("\u{1b}[15~".utf8))
        XCTAssertEqual(enc(.function(10)), Array("\u{1b}[21~".utf8))
        XCTAssertEqual(enc(.function(11)), Array("\u{1b}[23~".utf8))  // note: skips 22
        XCTAssertEqual(enc(.function(12)), Array("\u{1b}[24~".utf8))
    }

    func testFunctionKeyOutOfRangeIsEmpty() {
        XCTAssertEqual(enc(.function(0)), [])
        XCTAssertEqual(enc(.function(13)), [])
    }
```

Append to `Tests/NeotildeKitTests/KeybarInputRouterTests.swift`:

```swift
    func testTapFKeyEmitsSequence() {
        let (r, spy) = make()
        r.tapFKey(5)
        XCTAssertEqual(spy.sent, [Array("\u{1b}[15~".utf8)])
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter KeyEncodingTests --filter KeybarInputRouterTests`
Expected: FAIL — `type 'KeyInput' has no member 'function'` / `value of type 'KeybarInputRouter' has no member 'tapFKey'`.

- [ ] **Step 3: Add the `.function` case + encoding** — in `Sources/NeotildeKit/Keybar/KeyEncoding.swift`, add to the `KeyInput` enum (after `.arrow`):

```swift
    case function(Int)   // F1–F12
```

and add a `case` to the `switch key` in `encodeKey` (before `.char`):

```swift
    case .function(let n):
        switch n {
        case 1:  return Array("\u{1b}OP".utf8)
        case 2:  return Array("\u{1b}OQ".utf8)
        case 3:  return Array("\u{1b}OR".utf8)
        case 4:  return Array("\u{1b}OS".utf8)
        case 5:  return Array("\u{1b}[15~".utf8)
        case 6:  return Array("\u{1b}[17~".utf8)
        case 7:  return Array("\u{1b}[18~".utf8)
        case 8:  return Array("\u{1b}[19~".utf8)
        case 9:  return Array("\u{1b}[20~".utf8)
        case 10: return Array("\u{1b}[21~".utf8)
        case 11: return Array("\u{1b}[23~".utf8)
        case 12: return Array("\u{1b}[24~".utf8)
        default: return []   // outside F1–F12
        }
```

- [ ] **Step 4: Add `tapFKey` to the router** — in `Sources/NeotildeKit/Keybar/KeybarInputRouter.swift`, add a key method (next to `arrow`):

```swift
    /// Emit a function key F1–F12. Modifiers are not applied to F-keys in v1.
    public func tapFKey(_ n: Int) { fire(.function(n)) }
```

- [ ] **Step 5: Run to verify passing**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter KeyEncodingTests --filter KeybarInputRouterTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/NeotildeKit/Keybar/KeyEncoding.swift Sources/NeotildeKit/Keybar/KeybarInputRouter.swift Tests/NeotildeKitTests/KeyEncodingTests.swift Tests/NeotildeKitTests/KeybarInputRouterTests.swift
git commit -m "feat(keybar): F1–F12 key encoding + router tapFKey"
```

---

### Task 2: FnState machine + AutoFn catalog

**Files:**
- Create: `Sources/NeotildeKit/Keybar/FnState.swift`
- Create: `Sources/NeotildeKit/Keybar/AutoFnCatalog.swift`
- Test: `Tests/NeotildeKitTests/FnStateTests.swift`, `Tests/NeotildeKitTests/AutoFnCatalogTests.swift`

**Interfaces:**
- Produces:
  - `enum FnMode: Equatable, Sendable { case off, armed, locked }`
  - `struct FnState: Equatable, Sendable` with `private(set) var mode: FnMode`, and `mutating` methods `tap()`, `doubleTap()`, `fireFKey()`, `autoEngage()`, `autoDisengage()`, `reset()`. `var engaged: Bool { mode != .off }`.
  - `enum AutoFnCatalog { static let bundled: Set<String> /* htop, top, mc */; static func load(userOverrideJSON: Data?) -> (processes: Set<String>, warning: String?) }`
- FnState semantics: `tap()` off→armed, armed→locked, locked→off (and if `locked→off` happens while `autoActive`, set the per-episode override); `doubleTap()` → locked + clears override; `fireFKey()` armed→off else unchanged; `autoEngage()` sets autoActive and locks unless override; `autoDisengage()` clears autoActive + override and returns to off; `reset()` clears everything (pane switch).

- [ ] **Step 1: Write the failing tests** (`Tests/NeotildeKitTests/FnStateTests.swift`)

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class FnStateTests: XCTestCase {
    func testTapCyclesOffArmedLockedOff() {
        var f = FnState()
        XCTAssertEqual(f.mode, .off)
        f.tap(); XCTAssertEqual(f.mode, .armed)
        f.tap(); XCTAssertEqual(f.mode, .locked)
        f.tap(); XCTAssertEqual(f.mode, .off)
    }

    func testDoubleTapLocks() {
        var f = FnState()
        f.doubleTap(); XCTAssertEqual(f.mode, .locked)
    }

    func testFireFKeyClearsArmedButNotLocked() {
        var f = FnState()
        f.tap()                      // armed
        f.fireFKey(); XCTAssertEqual(f.mode, .off)
        f.doubleTap()                // locked
        f.fireFKey(); XCTAssertEqual(f.mode, .locked)  // firing does not exit lock
    }

    func testAutoEngageLocksAndDisengageReturnsOff() {
        var f = FnState()
        f.autoEngage(); XCTAssertEqual(f.mode, .locked)
        XCTAssertTrue(f.engaged)
        f.autoDisengage(); XCTAssertEqual(f.mode, .off)
    }

    func testUserOverrideBlocksReengageUntilEpisodeEnds() {
        var f = FnState()
        f.autoEngage()                 // auto-locked
        f.tap()                        // user turns it off during the auto episode
        XCTAssertEqual(f.mode, .off)
        f.autoEngage()                 // same episode: must NOT re-lock
        XCTAssertEqual(f.mode, .off)
        f.autoDisengage()              // episode ends → override resets
        f.autoEngage()                 // new episode: locks again
        XCTAssertEqual(f.mode, .locked)
    }

    func testManualRelockClearsOverride() {
        var f = FnState()
        f.autoEngage(); f.tap()        // override set
        f.doubleTap()                  // manual re-lock clears override
        XCTAssertEqual(f.mode, .locked)
        f.tap()                        // off again — but override was cleared by the relock...
        f.autoEngage()                 // ...so a fresh autoEngage re-locks
        XCTAssertEqual(f.mode, .locked)
    }

    func testResetClearsEverything() {
        var f = FnState()
        f.autoEngage(); f.tap()        // off + override
        f.reset()
        f.autoEngage(); XCTAssertEqual(f.mode, .locked)  // override cleared by reset
    }
}
```

`Tests/NeotildeKitTests/AutoFnCatalogTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class AutoFnCatalogTests: XCTestCase {
    func testBundledIsExactlyHtopTopMc() {
        XCTAssertEqual(AutoFnCatalog.bundled, ["htop", "top", "mc"])
        // Deliberately excluded editors:
        XCTAssertFalse(AutoFnCatalog.bundled.contains("vim"))
        XCTAssertFalse(AutoFnCatalog.bundled.contains("nano"))
    }

    func testNilOverrideReturnsBundledNoWarning() {
        let (procs, warning) = AutoFnCatalog.load(userOverrideJSON: nil)
        XCTAssertEqual(procs, AutoFnCatalog.bundled)
        XCTAssertNil(warning)
    }

    func testValidOverrideUnionsBundled() {
        let json = Data("""
        { "btop": { "autoFn": true }, "top": { "autoFn": false } }
        """.utf8)
        let (procs, warning) = AutoFnCatalog.load(userOverrideJSON: json)
        XCTAssertNil(warning)
        XCTAssertTrue(procs.contains("btop"))   // user-added
        XCTAssertTrue(procs.contains("htop"))   // bundled retained
        XCTAssertFalse(procs.contains("top"))   // user disabled
    }

    func testMalformedOverrideFallsBackWithWarning() {
        let (procs, warning) = AutoFnCatalog.load(userOverrideJSON: Data("{ bad".utf8))
        XCTAssertEqual(procs, AutoFnCatalog.bundled)
        XCTAssertNotNil(warning)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter FnStateTests --filter AutoFnCatalogTests`
Expected: FAIL — `cannot find 'FnState'` / `'AutoFnCatalog'`.

- [ ] **Step 3: Implement `FnState.swift`**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Fn-layer state (function-keys spec). Caps-lock semantics plus context
/// auto-engage with a per-episode user override.
public enum FnMode: Equatable, Sendable { case off, armed, locked }

public struct FnState: Equatable, Sendable {
    public private(set) var mode: FnMode = .off
    /// The active pane is currently in an auto-Fn context (htop/top/mc).
    private var autoActive = false
    /// The user dismissed Fn during the current auto episode → don't re-lock.
    private var userOverride = false

    public init() {}

    /// True when F-keys should be shown (Armed or Locked).
    public var engaged: Bool { mode != .off }

    /// Single tap: off→armed, armed→locked, locked→off. Turning a locked Fn off
    /// while a context has it auto-engaged sets the per-episode override.
    public mutating func tap() {
        switch mode {
        case .off:    mode = .armed
        case .armed:  mode = .locked
        case .locked:
            mode = .off
            if autoActive { userOverride = true }
        }
    }

    /// Double tap: lock. A manual lock clears any standing override.
    public mutating func doubleTap() { mode = .locked; userOverride = false }

    /// An F-key fired: clears a one-shot arm; a lock persists.
    public mutating func fireFKey() { if mode == .armed { mode = .off } }

    /// Context entered an auto-Fn process: lock unless the user overrode this episode.
    public mutating func autoEngage() {
        autoActive = true
        if !userOverride { mode = .locked }
    }

    /// Context left the auto-Fn process: end the episode and return to off.
    public mutating func autoDisengage() {
        autoActive = false
        userOverride = false
        mode = .off
    }

    /// Full reset (e.g. the focused pane changed): clears mode + episode state.
    public mutating func reset() { mode = .off; autoActive = false; userOverride = false }
}
```

- [ ] **Step 4: Implement `AutoFnCatalog.swift`**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The processes whose foreground presence auto-engages Fn (function-keys spec
/// §"Bundled v1 auto-Fn contexts"). Mirrors the promotion-set JSON shape:
/// `{ "<process>": { "autoFn": true|false } }`.
public enum AutoFnCatalog {
    /// `htop`/`top`/`mc` — editors are deliberately excluded.
    public static let bundled: Set<String> = ["htop", "top", "mc"]

    private struct Entry: Decodable { let autoFn: Bool }

    /// Bundled set unioned with a user override (entries with `autoFn:false`
    /// remove a process). Malformed JSON → bundled + a one-time warning.
    public static func load(userOverrideJSON: Data?) -> (processes: Set<String>, warning: String?) {
        guard let data = userOverrideJSON else { return (bundled, nil) }
        do {
            let user = try JSONDecoder().decode([String: Entry].self, from: data)
            var procs = bundled
            for (name, entry) in user {
                if entry.autoFn { procs.insert(name) } else { procs.remove(name) }
            }
            return (procs, nil)
        } catch {
            return (bundled, "Auto-Fn override file is invalid — using defaults.")
        }
    }
}
```

- [ ] **Step 5: Run to verify passing**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter FnStateTests --filter AutoFnCatalogTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/NeotildeKit/Keybar/FnState.swift Sources/NeotildeKit/Keybar/AutoFnCatalog.swift Tests/NeotildeKitTests/FnStateTests.swift Tests/NeotildeKitTests/AutoFnCatalogTests.swift
git commit -m "feat(keybar): Fn state machine + bundled auto-Fn catalog"
```

---

### Task 3: Keybar scroll-content model

**Files:**
- Create: `Sources/NeotildeKit/Keybar/KeybarScrollContent.swift`
- Test: `Tests/NeotildeKitTests/KeybarScrollContentTests.swift`

**Interfaces:**
- Consumes: `PromotionSlot` (NeotildeKit/Context).
- Produces:
  - `enum KeybarScrollItem: Equatable, Sendable { case promotion(PromotionSlot); case symbol(String); case fn; case fkey(Int) }`
  - `func keybarScrollItems(promotions: [PromotionSlot], defaultSymbols: [String], fnEngaged: Bool) -> [KeybarScrollItem]`
  - Fn engaged → `[.fkey(1)…fkey(12), .fn]` (F-keys replace promotions+defaults; the Fn slot stays last so the user can toggle off). Not engaged → `promotions.map(.promotion) + defaultSymbols.map(.symbol) + [.fn]`.

- [ ] **Step 1: Write the failing tests** (`Tests/NeotildeKitTests/KeybarScrollContentTests.swift`)

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class KeybarScrollContentTests: XCTestCase {
    private let p = PromotionSlot(tap: ":", up: ";", down: nil)
    private let syms = ["/", "|", "~"]

    func testNotEngagedShowsPromotionsThenSymbolsThenFn() {
        let items = keybarScrollItems(promotions: [p], defaultSymbols: syms, fnEngaged: false)
        XCTAssertEqual(items, [.promotion(p), .symbol("/"), .symbol("|"), .symbol("~"), .fn])
    }

    func testNoPromotionsShowsSymbolsThenFn() {
        let items = keybarScrollItems(promotions: [], defaultSymbols: syms, fnEngaged: false)
        XCTAssertEqual(items, [.symbol("/"), .symbol("|"), .symbol("~"), .fn])
    }

    func testEngagedShowsF1ThroughF12ThenFnAndHidesPromotionsAndSymbols() {
        let items = keybarScrollItems(promotions: [p], defaultSymbols: syms, fnEngaged: true)
        XCTAssertEqual(items, (1...12).map { KeybarScrollItem.fkey($0) } + [.fn])
        XCTAssertFalse(items.contains(.promotion(p)))
        XCTAssertFalse(items.contains(.symbol("/")))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter KeybarScrollContentTests`
Expected: FAIL — `cannot find 'keybarScrollItems' in scope`.

- [ ] **Step 3: Implement `KeybarScrollContent.swift`**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// One rendered item in the keybar's scrollable region.
public enum KeybarScrollItem: Equatable, Sendable {
    case promotion(PromotionSlot)
    case symbol(String)
    case fn
    case fkey(Int)
}

/// Resolve the scroll region's contents. F-key mode is mutually exclusive with
/// promotions+defaults and wins (function-keys spec §"Interaction with symbol
/// promotions"); the Fn slot stays last in both modes so it can be toggled.
public func keybarScrollItems(promotions: [PromotionSlot],
                              defaultSymbols: [String],
                              fnEngaged: Bool) -> [KeybarScrollItem] {
    if fnEngaged {
        return (1...12).map { KeybarScrollItem.fkey($0) } + [.fn]
    }
    return promotions.map { KeybarScrollItem.promotion($0) }
        + defaultSymbols.map { KeybarScrollItem.symbol($0) }
        + [.fn]
}
```

- [ ] **Step 4: Run to verify passing**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter KeybarScrollContentTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/NeotildeKit/Keybar/KeybarScrollContent.swift Tests/NeotildeKitTests/KeybarScrollContentTests.swift
git commit -m "feat(keybar): scroll-content model (promotions / F-keys / defaults + Fn)"
```

---

### Task 4: App — promotions rendering + scroll rebuild + per-pane DECCKM

**Files:**
- Create: `App/Keybar/PromotionSlotView.swift`
- Modify: `App/Keybar/KeybarView.swift`
- Modify: `App/ConnectionViewModel.swift`

**Validation:** App tier — macOS CI build only.

**Interfaces:**
- Consumes: `keybarScrollItems`, `KeybarScrollItem`, `PromotionRegistry`, `PromotionSlot`, `paneContexts`, `KeybarLayout.default.scroll` symbols, `vm.keybar.tapSymbol`.
- Produces on `ConnectionViewModel`: `var activePromotions: [PromotionSlot]` (active pane's context → registry), and a per-pane `applicationCursorKeys` closure replacing 4a's `{ false }`. On `KeybarView`: scroll region rebuilt from `keybarScrollItems`. New `PromotionSlotView` (bronze) + `FkeySlotView` + `FnSlotView` (FnSlotView gestures land in Task 5; render-only here is fine).

- [ ] **Step 1: Add promotion + DECCKM to `ConnectionViewModel`**

Add the registry + active promotions (place near `paneContexts`):

```swift
    /// Bundled promotion sets (user override is a 4d concern).
    private let promotionRegistry = PromotionRegistry.bundledDefault

    /// The active pane's promotion set (empty when its context is unknown or
    /// there is no active pane). Drives the keybar's bronze promotion slots.
    var activePromotions: [PromotionSlot] {
        guard let win = tmuxState?.activeWindow,
              let pane = tmuxState?.window(win)?.activePane,
              let process = paneContexts[pane],
              let set = promotionRegistry.set(for: process) else { return [] }
        return set.promote
    }
```

Replace 4a's hard-coded `applicationCursorKeys: { false }` in the `keybar` lazy var with a per-pane read (best-effort; SwiftTerm `Terminal.applicationCursor` like the existing `mouseMode` poll):

```swift
        let r = KeybarInputRouter(
            applicationCursorKeys: { [weak self] in self?.activePaneApplicationCursor() ?? false },
            send: { [weak self] bytes in self?.sendTerminalInput(bytes) })
```

and add the helper:

```swift
    /// DECCKM (application-cursor-keys) state of the active pane's terminal, or
    /// false if unavailable. Best-effort SwiftTerm read (cf. the mouse-mode poll).
    private func activePaneApplicationCursor() -> Bool {
        guard let win = tmuxState?.activeWindow,
              let pane = tmuxState?.window(win)?.activePane,
              let tv = paneViews[pane] else { return false }
        return tv.getTerminal().applicationCursor
    }
```

- [ ] **Step 2: Implement `App/Keybar/PromotionSlotView.swift`** — bronze promotion slot (tap=primary, swipe-up/down=secondaries), plus F-key and Fn render views.

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import NeotildeKit

/// A context-promoted slot: bronze fill, primary char on tap, optional swipe
/// secondaries (context-detection spec "Promoted slot visual").
struct PromotionSlotView: View {
    let slot: PromotionSlot
    let vm: ConnectionViewModel
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(spacing: 0) {
            if let up = slot.up { Text(up).font(.system(size: 9)).foregroundStyle(Color(theme.text.secondary)) }
            Text(slot.tap).font(.system(.body, design: .monospaced)).foregroundStyle(Color(theme.text.primary))
            if let down = slot.down { Text(down).font(.system(size: 9)).foregroundStyle(Color(theme.text.secondary)) }
        }
        .frame(minWidth: 34, minHeight: 34).padding(.horizontal, 6)
        .background(Color(theme.keybar.slotBgPromoted))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture { if let c = slot.tap.first { vm.keybar.tapSymbol(c) } }
        .gesture(DragGesture(minimumDistance: 12).onEnded { g in
            if g.translation.height < -12, let u = slot.up?.first { vm.keybar.tapSymbol(u) }
            else if g.translation.height > 12, let d = slot.down?.first { vm.keybar.tapSymbol(d) }
        })
    }
}

/// A function-key slot (F1–F12) shown while Fn mode is engaged.
struct FkeySlotView: View {
    let n: Int
    let vm: ConnectionViewModel
    @Environment(\.theme) private var theme
    var body: some View {
        Text("F\(n)").font(.caption).foregroundStyle(Color(theme.text.primary))
            .frame(minWidth: 34, minHeight: 34).padding(.horizontal, 6)
            .background(Color(theme.keybar.slotBg))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onTapGesture { vm.fnTapFKey(n) }   // sends F-key + consumes one-shot Fn (Task 5)
    }
}

/// The Fn toggle slot. Background reflects Fn mode (armed/locked). Gestures land
/// in Task 5 via `vm.fnTap()` / `vm.fnDoubleTap()`.
struct FnSlotView: View {
    let mode: FnMode
    let vm: ConnectionViewModel
    @Environment(\.theme) private var theme
    private var bg: Color {
        switch mode {
        case .locked: return Color(theme.keybar.slotBgLocked)
        case .armed:  return Color(theme.keybar.slotBgArmed)
        case .off:    return Color(theme.keybar.slotBg)
        }
    }
    var body: some View {
        Text("Fn").font(.caption).foregroundStyle(Color(theme.text.primary))
            .frame(minWidth: 34, minHeight: 34).padding(.horizontal, 6)
            .background(bg).clipShape(RoundedRectangle(cornerRadius: 6))
            .onTapGesture(count: 2) { vm.fnDoubleTap() }
            .onTapGesture(count: 1) { vm.fnTap() }
    }
}
```

(Note: `vm.fnTap()`/`vm.fnDoubleTap()`/`vm.fnTapFKey(_:)` are added in Task 5; this task compiles them as call sites only after Task 5 lands. If you implement Task 4 before Task 5, add temporary no-op stubs — but the plan executes 4 then 5, and the macOS build is batched after Task 5, so the call sites resolve.)

- [ ] **Step 3: Rebuild the scroll region in `KeybarView`** — replace the static `layout.scroll` ForEach with the computed content. In `App/Keybar/KeybarView.swift`, change the `ScrollView` block to:

```swift
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(scrollItems.enumerated()), id: \.offset) { _, item in
                        scrollItemView(item)
                    }
                }
            }
```

and add the computed items + a builder (the `defaultSymbols` come from `layout.scroll`'s `.symbol` cases):

```swift
    private var scrollItems: [KeybarScrollItem] {
        let symbols = layout.scroll.compactMap { slot -> String? in
            if case .symbol(let s) = slot { return s } else { return nil }
        }
        return keybarScrollItems(promotions: vm.activePromotions,
                                 defaultSymbols: symbols,
                                 fnEngaged: vm.fnState.engaged)
    }

    @ViewBuilder private func scrollItemView(_ item: KeybarScrollItem) -> some View {
        switch item {
        case .promotion(let s): PromotionSlotView(slot: s, vm: vm)
        case .symbol(let s):    SymbolSlotView(symbol: s, vm: vm)
        case .fn:               FnSlotView(mode: vm.fnState.mode, vm: vm)
        case .fkey(let n):      FkeySlotView(n: n, vm: vm)
        }
    }
```

(`vm.fnState` is added in Task 5; same batched-build note as above.)

- [ ] **Step 4: Commit (CI-gated, batched with Task 5)**

```bash
git add App/Keybar/PromotionSlotView.swift App/Keybar/KeybarView.swift App/ConnectionViewModel.swift
git commit -m "feat(keybar): render context promotions + scroll rebuild + per-pane DECCKM"
```

(No push yet — App compiles only after Task 5 adds the Fn vm members.)

---

### Task 5: App — Fn state on the view model + auto-engage wiring

**Files:**
- Modify: `App/ConnectionViewModel.swift`

**Validation:** App tier — macOS CI build only (batched after this task).

**Interfaces:**
- Consumes: `FnState`, `AutoFnCatalog`, `vm.keybar.tapFKey`, the existing `paneContexts` update path.
- Produces on `ConnectionViewModel`: `@Published private(set) var fnState = FnState()`; `func fnTap()`, `func fnDoubleTap()`, `func fnTapFKey(_ n: Int)`; auto-engage driven from context changes; Fn reset on active-pane change.

- [ ] **Step 1: Add Fn state + gestures** — in `App/ConnectionViewModel.swift`:

```swift
    /// Fn-layer state for the active pane. Published so the keybar re-renders the
    /// Fn slot and the F-key layer.
    @Published private(set) var fnState = FnState()
    private let autoFnProcesses = AutoFnCatalog.bundled

    func fnTap()       { fnState.tap() }
    func fnDoubleTap() { fnState.doubleTap() }
    /// Send an F-key and clear a one-shot Fn arm.
    func fnTapFKey(_ n: Int) { keybar.tapFKey(n); fnState.fireFKey() }
```

- [ ] **Step 2: Drive auto-engage from context changes** — the active pane's context already updates `paneContexts` via the Plan-D poll (`onContextsChanged` → `self.paneContexts = map`). Add a helper and call it wherever `paneContexts` is assigned in `attachTmux`'s `onContextsChanged` closure (after `self.paneContexts = map`):

```swift
        self.refreshFnAutoEngage()
```

and implement:

```swift
    /// Reconcile Fn auto-engage with the active pane's foreground process.
    private func refreshFnAutoEngage() {
        let process: String? = {
            guard let win = tmuxState?.activeWindow,
                  let pane = tmuxState?.window(win)?.activePane else { return nil }
            return paneContexts[pane]
        }()
        if let process, autoFnProcesses.contains(process) {
            fnState.autoEngage()
        } else {
            fnState.autoDisengage()
        }
    }
```

Also call `refreshFnAutoEngage()` at the end of the `onStateChanged` closure in `attachTmux` (so an active-pane/window switch re-reconciles), and call `fnState.reset()` in `teardown()`.

(Optional polish noted, not required for v1: `fnState.reset()` on a focused-pane change to honor the spec's "pane switched away and back resets override" — `refreshFnAutoEngage` already re-evaluates engage/disengage on state change, which covers the common case.)

- [ ] **Step 3: Commit + validate on macOS CI**

```bash
git add App/ConnectionViewModel.swift
git commit -m "feat(keybar): Fn state on the session VM + context auto-engage wiring"
git push -u github feat/phase-4b-promotions-fn
```
(The controller opens the PR + watches CI; `macos` green proves Tasks 4–5 compile. Interaction/visual still needs a Simulator.)

---

## Wrap-up

- [ ] **Full NeotildeKit suite green:** `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test` — all existing + the 3 new keybar suites pass.
- [ ] **Update `TODO.md`** — Phase 4 row: 4a + 4b done; 4c–4e pending. Commit `docs: mark Phase 4b (promotions + Fn) done`.
- [ ] **Open PR** to `github` `main` (squash-merge). State that promotion/Fn *interaction* is pending a Simulator pass.

---

## Self-Review notes

- **Spec coverage (Fn):** state machine off/armed/locked + double-tap-lock + fire-clears-armed → Task 2; auto-engage htop/top/mc + fnUserOverride episode reset → Task 2 + Task 5 wiring; F1–F12 encoding → Task 1; Fn slot at end of scroll + F-key-mode-replaces-scroll mutual exclusion → Task 3 + Task 4. **Spec coverage (promotions):** engaged context's set rendered bronze after the locked region → Tasks 3/4 (consume `paneContexts` + `PromotionRegistry` from Plan D); per-slot tap/swipe → `PromotionSlotView`.
- **Deferred (documented):** Shift+F-key modified sequences (spec defers the affordance polish; MVP sends unmodified F-keys); the engage/disengage slide+pulse animation and cross-fade (visual polish, Simulator-gated); in-app auto-Fn/promotion JSON editor (v1.5); per-pane Fn state object (v1 uses one active-pane Fn state reconciled on context/state change). None are gaps.
- **Known App-tier ⚠️ (macOS-CI / Simulator):** `Terminal.applicationCursor` SwiftTerm API (best-effort, like `mouseMode`); reactivity of `activePromotions`/`fnState` through `@ObservedObject vm` (fnState is `@Published`; `activePromotions` derives from `@Published paneContexts`/`tmuxState`, so KeybarView re-renders on change); Tasks 4–5 build batched on macOS CI.
