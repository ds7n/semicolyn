<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Phase 4a — MVP Keybar (mount + core input slots) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the keyboard accessory bar with its core input slots — Esc · Pad · Modifier · Tab + default symbol slots — so a user can send Esc, arrows, Ctrl/Alt/Shift chords, Tab, and the convenience symbols from the bar.

**Architecture:** Push **all input logic into pure, Linux-tested SemicolynKit**: a keystroke→bytes codec (`KeyEncoding`), a modifier arming state machine (`ModifierState`, Ctrl double-tap-lock per the function-keys spec), a default-layout model (`KeybarLayout`), and a **`KeybarInputRouter`** that ties them together and emits bytes through an injected `send` closure. The App tier (`App/`) then renders slots from the layout, recognizes gestures, and forwards them to the router — a thin, compile-only-on-macOS wiring layer.

**Tech Stack:** Swift 6 strict concurrency, XCTest on the Linux fast loop (the four pure cores); SwiftUI + SwiftTerm + the existing `vm.sendTerminalInput` byte path for the App tier (macOS-CI-build-validated only).

## Verification reality (read before scoping expectations)

- **The four pure cores (Tasks 1–4) are fully Linux-tested** — high confidence, this is the bulk of 4a's *behavior*.
- **The App tier (Tasks 5–6) compiles only on the macOS CI job, which builds but does not run a Simulator.** So "the bar appears above the keyboard and a tap sends the right byte" is **not** verifiable by this toolchain — it needs a Simulator run (not currently automated) or a device (Apple-enrollment-gated, in flight). Tasks 5–6 deliver compile-correct, logic-tested wiring; final mount/interaction tuning is expected to need a Simulator/device iteration later.
- **Open integration risk (Task 6):** SwiftTerm's `TerminalView` is the first responder that raises the iOS keyboard, and there is **one TerminalView per pane**. Mounting a single global bar *above the keyboard* via `inputAccessoryView` is per-responder and fights multi-pane focus. Task 6 picks the **SwiftUI `safeAreaInset(.bottom)` global bar** as the v1 mount (simple, pane-agnostic, always-visible) and documents the `inputAccessoryView` alternative as a follow-up once a Simulator confirms keyboard-overlap behavior. This is a deliberate v1 simplification, not a gap.

## Global Constraints

- **Two tiers, two test surfaces.** Pure logic in `Sources/SemicolynKit/` (XCTest, no `import UIKit`/`SwiftUI`/`CryptoKit`, `Sendable` where it crosses actors). App code in `App/` validated only by macOS CI.
- **Specs are locked:** `docs/superpowers/specs/2026-06-15-keybar-customization-design.md` (layout), `docs/superpowers/specs/2026-06-14-function-keys-design.md` (Ctrl double-tap-lock companion change).
- **Default locked-left composition (verbatim):** `Esc pill · Pad · Modifier · Tab`. **Default scroll convenience symbols (verbatim):** `/` `|` `~` `-` `(` `)`.
- **Modifier semantics (function-keys spec):** Tap = arm Ctrl (one-shot); **Double-tap = lock Ctrl**; tap while Ctrl locked = unlock; Swipe-up = arm Alt (one-shot, no lock); Swipe-down = arm Shift (one-shot, no lock). Armed one-shots clear after the next keystroke; a lock persists.
- **Theme tokens already exist** (`Theme.Keybar`: `slotBg`, `slotBgPromoted`, `slotBgArmed`, `slotBgLocked`) — use them; never inline hex.
- **In scope for 4a:** mount; Esc pill (tap=Esc, swipe-left/right = prev/next window); Pad (drag = arrows, tap = zoom active pane); Modifier; Tab; default symbol slots; horizontal scroll region. **Deferred to later 4x slices (do NOT build here):** promotions rendering + Fn (4b), predictor strip (4c), Settings→Keybar editor / custom slots / macros / reverse-bar (4d), external keyboard (4e), Esc-pill quick/unified pickers + swipe-up/down, Pad long-press pane-mode + splits.
- **SPDX header on every new file.** Conventional commits; feature branch `feat/phase-4a-keybar-mvp`; squash-merge.
- **Test commands:** `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <Suite>`.

---

## File Structure

**Created (SemicolynKit, Linux-tested):**
- `Sources/SemicolynKit/Keybar/KeyEncoding.swift` — `KeyInput`, `ArrowDirection`, `KeyModifiers`, `encodeKey(_:modifiers:applicationCursorKeys:)`.
- `Sources/SemicolynKit/Keybar/ModifierState.swift` — `CtrlState`, `ModifierState` arming SM.
- `Sources/SemicolynKit/Keybar/KeybarLayout.swift` — `KeybarSlot`, `KeybarLayout` (+ `.default`).
- `Sources/SemicolynKit/Keybar/KeybarInputRouter.swift` — ties the above to gesture events, emits bytes.

**Created (App, macOS-CI-only):**
- `App/Keybar/KeybarView.swift` — renders locked + scroll regions from `KeybarLayout`.
- `App/Keybar/KeybarSlotViews.swift` — `EscPillView`, `PadView`, `ModifierSlotView`, `SymbolSlotView`, `TabSlotView`.

**Modified (App):**
- `App/TmuxRuntime.swift` — add `zoomActivePane()` + `applicationCursorKeys` not needed here.
- `App/ConnectionViewModel.swift` — add `zoomActivePane()`, `selectNextWindow()`/`selectPrevWindow()`, expose a `KeybarInputRouter`.
- `App/SessionView.swift` — mount `KeybarView` via `.safeAreaInset(.bottom)`.

**Tests created:** `KeyEncodingTests`, `ModifierStateTests`, `KeybarLayoutTests`, `KeybarInputRouterTests`.

---

## Setup

- [ ] **Step 0: Branch**

```bash
cd /home/djmyers/proj/truepositive/semicolyn
git checkout -b feat/phase-4a-keybar-mvp
```

---

### Task 1: KeyEncoding — keystroke → bytes codec

**Files:**
- Create: `Sources/SemicolynKit/Keybar/KeyEncoding.swift`
- Test: `Tests/SemicolynKitTests/KeyEncodingTests.swift`

**Interfaces:**
- Produces:
  - `enum ArrowDirection: Equatable, Sendable { case up, down, left, right }`
  - `enum KeyInput: Equatable, Sendable { case char(Character); case escape; case tab; case enter; case backspace; case arrow(ArrowDirection) }`
  - `struct KeyModifiers: Equatable, Sendable { var control, option, shift: Bool; init(control: Bool = false, option: Bool = false, shift: Bool = false) }`
  - `func encodeKey(_ key: KeyInput, modifiers: KeyModifiers, applicationCursorKeys: Bool) -> [UInt8]`
- Encoding rules (xterm conventions): Esc→`1b`; Tab→`09` (Shift+Tab→`ESC [ Z`); Enter→`0d`; Backspace→`7f`; arrows→`ESC [ {A,B,C,D}` normal / `ESC O {A,B,C,D}` application (up=A, down=B, right=C, left=D); `.char` with Control→the control byte (`a`–`z`→1–26, `@A–Z[\]^_`→`&0x1f`, space/`@`→0, `?`→`7f`, else the plain char); Shift uppercases a letter; Option(meta) prepends `ESC` to a `.char` result. (MVP: Option/Shift/Control do not modify arrows; Option does not prefix Esc/arrows — documented.)

- [ ] **Step 1: Write the failing tests** (`Tests/SemicolynKitTests/KeyEncodingTests.swift`)

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class KeyEncodingTests: XCTestCase {
    private func enc(_ k: KeyInput, _ m: KeyModifiers = .init(), app: Bool = false) -> [UInt8] {
        encodeKey(k, modifiers: m, applicationCursorKeys: app)
    }

    func testPlainKeys() {
        XCTAssertEqual(enc(.escape), [0x1b])
        XCTAssertEqual(enc(.tab), [0x09])
        XCTAssertEqual(enc(.enter), [0x0d])
        XCTAssertEqual(enc(.backspace), [0x7f])
        XCTAssertEqual(enc(.char("/")), [0x2f])
        XCTAssertEqual(enc(.char("~")), [0x7e])
    }

    func testControlLetters() {
        XCTAssertEqual(enc(.char("c"), .init(control: true)), [0x03])  // Ctrl+C
        XCTAssertEqual(enc(.char("a"), .init(control: true)), [0x01])
        XCTAssertEqual(enc(.char("C"), .init(control: true)), [0x03])  // case-insensitive
        XCTAssertEqual(enc(.char("z"), .init(control: true)), [0x1a])
    }

    func testControlSymbolsBoundaries() {
        XCTAssertEqual(enc(.char("@"), .init(control: true)), [0x00])  // NUL
        XCTAssertEqual(enc(.char(" "), .init(control: true)), [0x00])
        XCTAssertEqual(enc(.char("["), .init(control: true)), [0x1b]) // ESC
        XCTAssertEqual(enc(.char("\\"), .init(control: true)), [0x1c])
        XCTAssertEqual(enc(.char("_"), .init(control: true)), [0x1f])
        XCTAssertEqual(enc(.char("?"), .init(control: true)), [0x7f]) // DEL
    }

    func testControlWithoutMappingFallsBackToPlain() {
        // Ctrl+1 has no control form → send the plain char.
        XCTAssertEqual(enc(.char("1"), .init(control: true)), [0x31])
    }

    func testOptionPrefixesEscOnChars() {
        XCTAssertEqual(enc(.char("x"), .init(option: true)), [0x1b, 0x78])      // Alt+x
        XCTAssertEqual(enc(.char("c"), .init(control: true, option: true)), [0x1b, 0x03]) // Alt+Ctrl+C
    }

    func testShiftUppercasesLetterAndBackTabs() {
        XCTAssertEqual(enc(.char("a"), .init(shift: true)), [0x41])  // 'A'
        XCTAssertEqual(enc(.tab, .init(shift: true)), Array("\u{1b}[Z".utf8))  // back-tab
    }

    func testArrowsRespectCursorKeyMode() {
        XCTAssertEqual(enc(.arrow(.up)),  Array("\u{1b}[A".utf8))
        XCTAssertEqual(enc(.arrow(.left)), Array("\u{1b}[D".utf8))
        XCTAssertEqual(enc(.arrow(.up), app: true), Array("\u{1b}OA".utf8))
        XCTAssertEqual(enc(.arrow(.right), app: true), Array("\u{1b}OC".utf8))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter KeyEncodingTests`
Expected: FAIL — `cannot find 'encodeKey' in scope`.

- [ ] **Step 3: Implement `KeyEncoding.swift`**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// A directional arrow key.
public enum ArrowDirection: Equatable, Sendable { case up, down, left, right }

/// A logical key the keybar can emit (before modifiers / terminal mode are applied).
public enum KeyInput: Equatable, Sendable {
    case char(Character)
    case escape
    case tab
    case enter
    case backspace
    case arrow(ArrowDirection)
}

/// The modifier set armed against a keystroke.
public struct KeyModifiers: Equatable, Sendable {
    public var control: Bool
    public var option: Bool
    public var shift: Bool
    public init(control: Bool = false, option: Bool = false, shift: Bool = false) {
        self.control = control; self.option = option; self.shift = shift
    }
}

/// The control byte for `ch` in caret notation, or nil when `ch` has no control
/// form (e.g. a digit). `a`–`z`/`A`–`Z`→1–26, `@A–Z[\]^_`→`&0x1f`, space/`@`→0, `?`→DEL.
private func controlByte(for ch: Character) -> UInt8? {
    guard let a = ch.asciiValue else { return nil }
    switch a {
    case 0x61...0x7a: return a - 0x60          // a-z → 1..26
    case 0x40...0x5f: return a & 0x1f          // @ A-Z [ \ ] ^ _  → 0..31
    case 0x20:        return 0x00              // space → NUL
    case 0x3f:        return 0x7f              // ? → DEL
    default:          return nil
    }
}

/// Encode one logical keystroke to the raw bytes a terminal expects, applying
/// modifiers and the terminal's cursor-key mode (DECCKM). xterm conventions.
public func encodeKey(_ key: KeyInput, modifiers: KeyModifiers, applicationCursorKeys: Bool) -> [UInt8] {
    switch key {
    case .escape:    return [0x1b]
    case .enter:     return [0x0d]
    case .backspace: return [0x7f]
    case .tab:       return modifiers.shift ? Array("\u{1b}[Z".utf8) : [0x09]
    case .arrow(let d):
        let final: Character = { switch d { case .up: return "A"; case .down: return "B"
                                            case .right: return "C"; case .left: return "D" } }()
        let prefix = applicationCursorKeys ? "\u{1b}O" : "\u{1b}["
        return Array((prefix + String(final)).utf8)
    case .char(let ch):
        var base: [UInt8]
        if modifiers.control, let cb = controlByte(for: ch) {
            base = [cb]
        } else {
            let c = modifiers.shift ? Character(ch.uppercased()) : ch
            base = Array(String(c).utf8)
        }
        if modifiers.option { base.insert(0x1b, at: 0) }  // meta-sends-escape
        return base
    }
}
```

- [ ] **Step 4: Run to verify passing**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter KeyEncodingTests`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Keybar/KeyEncoding.swift Tests/SemicolynKitTests/KeyEncodingTests.swift
git commit -m "feat(keybar): keystroke→bytes codec (control/meta/arrows/cursor-key mode)"
```

---

### Task 2: ModifierState — arming state machine

**Files:**
- Create: `Sources/SemicolynKit/Keybar/ModifierState.swift`
- Test: `Tests/SemicolynKitTests/ModifierStateTests.swift`

**Interfaces:**
- Consumes: `KeyModifiers` (Task 1).
- Produces:
  - `enum CtrlState: Equatable, Sendable { case off, armed, locked }`
  - `struct ModifierState: Equatable, Sendable` with `private(set) var ctrl: CtrlState`, `private(set) var altArmed: Bool`, `private(set) var shiftArmed: Bool`, and mutating methods `tapCtrl()` (off→armed, armed→off, locked→off), `lockCtrl()` (→locked), `armAlt()` (one-shot), `armShift()` (one-shot), `func current() -> KeyModifiers`, `mutating func consumeAfterKeystroke()` (armed ctrl→off, alt/shift→off, locked ctrl persists).

- [ ] **Step 1: Write the failing tests** (`Tests/SemicolynKitTests/ModifierStateTests.swift`)

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ModifierStateTests: XCTestCase {
    func testTapArmsCtrlOneShotThenClearsOnConsume() {
        var m = ModifierState()
        m.tapCtrl()
        XCTAssertEqual(m.ctrl, .armed)
        XCTAssertEqual(m.current(), KeyModifiers(control: true))
        m.consumeAfterKeystroke()
        XCTAssertEqual(m.ctrl, .off)               // one-shot cleared
        XCTAssertEqual(m.current(), KeyModifiers())
    }

    func testDoubleTapLocksCtrlAndPersistsAcrossKeystrokes() {
        var m = ModifierState()
        m.lockCtrl()
        XCTAssertEqual(m.ctrl, .locked)
        m.consumeAfterKeystroke()
        XCTAssertEqual(m.ctrl, .locked)            // lock persists
        m.consumeAfterKeystroke()
        XCTAssertEqual(m.ctrl, .locked)
        XCTAssertEqual(m.current(), KeyModifiers(control: true))
    }

    func testTapWhileLockedUnlocks() {
        var m = ModifierState()
        m.lockCtrl()
        m.tapCtrl()
        XCTAssertEqual(m.ctrl, .off)
    }

    func testTapWhileArmedTogglesOff() {
        var m = ModifierState()
        m.tapCtrl(); m.tapCtrl()
        XCTAssertEqual(m.ctrl, .off)
    }

    func testAltAndShiftAreOneShotNoLock() {
        var m = ModifierState()
        m.armAlt()
        XCTAssertEqual(m.current(), KeyModifiers(option: true))
        m.consumeAfterKeystroke()
        XCTAssertFalse(m.current().option)         // cleared
        m.armShift()
        XCTAssertEqual(m.current(), KeyModifiers(shift: true))
        m.consumeAfterKeystroke()
        XCTAssertFalse(m.current().shift)
    }

    func testCombinedCtrlLockedPlusAltOneShot() {
        var m = ModifierState()
        m.lockCtrl(); m.armAlt()
        XCTAssertEqual(m.current(), KeyModifiers(control: true, option: true))
        m.consumeAfterKeystroke()
        XCTAssertEqual(m.current(), KeyModifiers(control: true))  // ctrl locked stays, alt gone
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ModifierStateTests`
Expected: FAIL — `cannot find 'ModifierState' in scope`.

- [ ] **Step 3: Implement `ModifierState.swift`**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Ctrl arming state (function-keys spec: tap=arm one-shot, double-tap=lock).
public enum CtrlState: Equatable, Sendable { case off, armed, locked }

/// The keybar's modifier arming state machine. Ctrl supports lock (Emacs-style
/// chord sequences); Alt and Shift are one-shot only (function-keys spec
/// "Companion change: Ctrl gets double-tap-to-lock").
public struct ModifierState: Equatable, Sendable {
    public private(set) var ctrl: CtrlState = .off
    public private(set) var altArmed: Bool = false
    public private(set) var shiftArmed: Bool = false

    public init() {}

    /// Single tap on the Ctrl gesture: off→armed, armed→off, locked→off (unlock).
    public mutating func tapCtrl() {
        switch ctrl {
        case .off:    ctrl = .armed
        case .armed:  ctrl = .off
        case .locked: ctrl = .off
        }
    }

    /// Double tap on the Ctrl gesture: lock until tapped off.
    public mutating func lockCtrl() { ctrl = .locked }

    /// Swipe-up arms Alt for one keystroke (no lock).
    public mutating func armAlt() { altArmed = true }

    /// Swipe-down arms Shift for one keystroke (no lock).
    public mutating func armShift() { shiftArmed = true }

    /// The modifiers to apply to the next keystroke.
    public func current() -> KeyModifiers {
        KeyModifiers(control: ctrl != .off, option: altArmed, shift: shiftArmed)
    }

    /// Clear one-shot arms after a keystroke fires; a Ctrl lock persists.
    public mutating func consumeAfterKeystroke() {
        if ctrl == .armed { ctrl = .off }
        altArmed = false
        shiftArmed = false
    }
}
```

- [ ] **Step 4: Run to verify passing**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ModifierStateTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Keybar/ModifierState.swift Tests/SemicolynKitTests/ModifierStateTests.swift
git commit -m "feat(keybar): modifier arming state machine with Ctrl double-tap-lock"
```

---

### Task 3: KeybarLayout — default slot model

**Files:**
- Create: `Sources/SemicolynKit/Keybar/KeybarLayout.swift`
- Test: `Tests/SemicolynKitTests/KeybarLayoutTests.swift`

**Interfaces:**
- Produces:
  - `enum KeybarSlot: Equatable, Sendable { case escPill; case pad; case modifier; case tab; case symbol(String) }`
  - `struct KeybarLayout: Equatable, Sendable { let locked: [KeybarSlot]; let scroll: [KeybarSlot]; init(locked:scroll:); static let `default`: KeybarLayout }`
  - `.default` = locked `[.escPill, .pad, .modifier, .tab]`, scroll `[.symbol("/"), .symbol("|"), .symbol("~"), .symbol("-"), .symbol("("), .symbol(")")]`.

- [ ] **Step 1: Write the failing tests** (`Tests/SemicolynKitTests/KeybarLayoutTests.swift`)

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class KeybarLayoutTests: XCTestCase {
    func testDefaultLockedRegionIsEscPadModifierTab() {
        XCTAssertEqual(KeybarLayout.default.locked, [.escPill, .pad, .modifier, .tab])
    }

    func testDefaultScrollSymbolsMatchSpec() {
        XCTAssertEqual(KeybarLayout.default.scroll,
                       [.symbol("/"), .symbol("|"), .symbol("~"), .symbol("-"), .symbol("("), .symbol(")")])
    }

    func testEscAndPadAreLockedNotInScroll() {
        XCTAssertFalse(KeybarLayout.default.scroll.contains(.escPill))
        XCTAssertFalse(KeybarLayout.default.scroll.contains(.pad))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter KeybarLayoutTests`
Expected: FAIL — `cannot find 'KeybarLayout' in scope`.

- [ ] **Step 3: Implement `KeybarLayout.swift`**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// One keybar slot. v1 (4a) ships the four built-in widgets plus default symbol
/// slots; custom slots / macros / Fn arrive in later 4x slices.
public enum KeybarSlot: Equatable, Sendable {
    case escPill
    case pad
    case modifier
    case tab
    case symbol(String)
}

/// The keybar's slot composition, split into the locked region (never scrolls)
/// and the horizontally scrollable region. 4a renders `.default`; the
/// Settings→Keybar editor that mutates this is Phase 4d.
public struct KeybarLayout: Equatable, Sendable {
    public let locked: [KeybarSlot]
    public let scroll: [KeybarSlot]
    public init(locked: [KeybarSlot], scroll: [KeybarSlot]) {
        self.locked = locked; self.scroll = scroll
    }

    /// Locked `Esc · Pad · Modifier · Tab`; scroll = the six convenience symbols
    /// (keybar-customization spec "Default locked-left composition" + "Scroll region").
    public static let `default` = KeybarLayout(
        locked: [.escPill, .pad, .modifier, .tab],
        scroll: [.symbol("/"), .symbol("|"), .symbol("~"), .symbol("-"), .symbol("("), .symbol(")")]
    )
}
```

- [ ] **Step 4: Run to verify passing**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter KeybarLayoutTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Keybar/KeybarLayout.swift Tests/SemicolynKitTests/KeybarLayoutTests.swift
git commit -m "feat(keybar): default keybar layout model (locked Esc·Pad·Modifier·Tab + symbols)"
```

---

### Task 4: KeybarInputRouter — gesture events → bytes

**Files:**
- Create: `Sources/SemicolynKit/Keybar/KeybarInputRouter.swift`
- Test: `Tests/SemicolynKitTests/KeybarInputRouterTests.swift`

**Interfaces:**
- Consumes: `KeyInput`/`encodeKey` (Task 1), `ModifierState` (Task 2).
- Produces:
  - `final class KeybarInputRouter` with `init(applicationCursorKeys: @escaping () -> Bool, send: @escaping ([UInt8]) -> Void)`, read-only `var modifiers: ModifierState`, and methods `tapCtrl()`, `doubleTapCtrl()`, `armAlt()`, `armShift()`, `tapSymbol(_ c: Character)`, `tapEscape()`, `tapTab()`, `arrow(_ d: ArrowDirection)`.
  - Modifier-gesture methods mutate state only (no send). Key methods encode with the current modifiers + the live `applicationCursorKeys()`, call `send`, then `consumeAfterKeystroke()`.
- Not `Sendable` — owned and called on the App main actor; tests drive it single-threaded.

- [ ] **Step 1: Write the failing tests** (`Tests/SemicolynKitTests/KeybarInputRouterTests.swift`)

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class KeybarInputRouterTests: XCTestCase {
    /// Captures bytes the router emits.
    private final class Spy {
        var sent: [[UInt8]] = []
        func send(_ b: [UInt8]) { sent.append(b) }
    }

    private func make(app: Bool = false) -> (KeybarInputRouter, Spy) {
        let spy = Spy()
        let router = KeybarInputRouter(applicationCursorKeys: { app }, send: spy.send)
        return (router, spy)
    }

    func testArmedCtrlAppliesToNextSymbolThenClears() {
        let (r, spy) = make()
        r.tapCtrl()
        r.tapSymbol("c")
        XCTAssertEqual(spy.sent, [[0x03]])              // Ctrl+C
        r.tapSymbol("c")
        XCTAssertEqual(spy.sent, [[0x03], [0x63]])      // second is plain 'c' (one-shot cleared)
    }

    func testLockedCtrlAppliesToMultipleKeystrokes() {
        let (r, spy) = make()
        r.doubleTapCtrl()
        r.tapSymbol("x"); r.tapSymbol("s")
        XCTAssertEqual(spy.sent, [[0x18], [0x13]])      // Ctrl+X, Ctrl+S — lock persists
    }

    func testAltSymbolEmitsMetaEscapeOnce() {
        let (r, spy) = make()
        r.armAlt()
        r.tapSymbol("x")
        XCTAssertEqual(spy.sent, [[0x1b, 0x78]])        // Alt+x
        r.tapSymbol("x")
        XCTAssertEqual(spy.sent.last, [0x78])           // plain after consume
    }

    func testEscTabAndArrowsEmitExpectedBytes() {
        let (r, spy) = make()
        r.tapEscape(); r.tapTab(); r.arrow(.up)
        XCTAssertEqual(spy.sent, [[0x1b], [0x09], Array("\u{1b}[A".utf8)])
    }

    func testArrowRespectsApplicationCursorKeys() {
        let (r, spy) = make(app: true)
        r.arrow(.left)
        XCTAssertEqual(spy.sent, [Array("\u{1b}OD".utf8)])
    }

    func testModifierGestureDoesNotSendUntilAKeyFires() {
        let (r, spy) = make()
        r.tapCtrl()
        XCTAssertTrue(spy.sent.isEmpty)                  // arming alone sends nothing
        XCTAssertEqual(r.modifiers.ctrl, .armed)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter KeybarInputRouterTests`
Expected: FAIL — `cannot find 'KeybarInputRouter' in scope`.

- [ ] **Step 3: Implement `KeybarInputRouter.swift`**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Ties the keybar's gesture events to byte output: holds the `ModifierState`,
/// encodes each keystroke with `encodeKey` against the live cursor-key mode, and
/// emits via the injected `send`. Pure (no UIKit); the App's slot views call
/// these methods. Modifier-gesture methods only arm state — they never send.
public final class KeybarInputRouter {
    private var state = ModifierState()
    private let applicationCursorKeys: () -> Bool
    private let send: ([UInt8]) -> Void

    public init(applicationCursorKeys: @escaping () -> Bool, send: @escaping ([UInt8]) -> Void) {
        self.applicationCursorKeys = applicationCursorKeys
        self.send = send
    }

    /// Current arming state, for the UI to render armed/locked slot visuals.
    public var modifiers: ModifierState { state }

    // Modifier gestures (no keystroke emitted).
    public func tapCtrl()       { state.tapCtrl() }
    public func doubleTapCtrl() { state.lockCtrl() }
    public func armAlt()        { state.armAlt() }
    public func armShift()      { state.armShift() }

    // Keystroke gestures.
    public func tapSymbol(_ c: Character) { fire(.char(c)) }
    public func tapEscape()               { fire(.escape) }
    public func tapTab()                  { fire(.tab) }
    public func arrow(_ d: ArrowDirection) { fire(.arrow(d)) }

    private func fire(_ key: KeyInput) {
        let bytes = encodeKey(key, modifiers: state.current(),
                              applicationCursorKeys: applicationCursorKeys())
        send(bytes)
        state.consumeAfterKeystroke()
    }
}
```

- [ ] **Step 4: Run to verify passing**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter KeybarInputRouterTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Keybar/KeybarInputRouter.swift Tests/SemicolynKitTests/KeybarInputRouterTests.swift
git commit -m "feat(keybar): input router wiring modifier state + key codec to byte output"
```

---

### Task 5: App — view-model hooks (router, zoom, window nav)

**Files:**
- Modify: `App/ConnectionViewModel.swift`
- Modify: `App/TmuxRuntime.swift`

**Validation:** App tier — macOS CI build only (not locally compilable / not Simulator-run).

**Interfaces:**
- Consumes: `KeybarInputRouter` (Task 4), existing `sendTerminalInput(_:)`, `selectWindow(_:)`, `TmuxCommand.zoomPane`, `tmuxState`.
- Produces on `ConnectionViewModel`: `let keybar: KeybarInputRouter` (sends through `sendTerminalInput`, cursor-key mode is a best-effort closure — see note); `func zoomActivePane()`; `func selectNextWindow()`; `func selectPrevWindow()`. On `TmuxRuntime`: `func zoomActivePane()` that submits `TmuxCommand.zoomPane(target: activePane)`.

- [ ] **Step 1: Add `zoomActivePane()` to `TmuxRuntime`** — mirror the existing `selectWindow`/`write` pattern in `App/TmuxRuntime.swift`:

```swift
    /// Toggle zoom on the active pane (tmux emits the layout change).
    func zoomActivePane() {
        guard let pane = activePane else { return }
        write(TmuxCommand.zoomPane(target: pane))
    }
```

- [ ] **Step 2: Add the router + actions to `ConnectionViewModel`** — add a stored `keybar` router and the action methods.

Add the router property (initialised lazily so `self` is available for the send closure):

```swift
    /// Routes keybar gesture events to terminal bytes. Cursor-key mode is
    /// best-effort `false` in v1 (the per-pane DECCKM read is a 4b refinement);
    /// most apps accept normal-mode arrows.
    private(set) lazy var keybar = KeybarInputRouter(
        applicationCursorKeys: { false },
        send: { [weak self] bytes in self?.sendTerminalInput(bytes) })
```

Add the tmux action methods near `selectWindow`:

```swift
    /// Toggle zoom on the active pane (Pad tap). No-op in raw-PTY mode.
    func zoomActivePane() { tmux?.zoomActivePane() }

    /// Esc-pill swipe-right: next tmux window (wraps). No-op with <2 windows.
    func selectNextWindow() { stepWindow(+1) }
    /// Esc-pill swipe-left: previous tmux window (wraps).
    func selectPrevWindow() { stepWindow(-1) }

    private func stepWindow(_ delta: Int) {
        guard let state = tmuxState, state.windows.count > 1,
              let active = state.activeWindow,
              let idx = state.windows.firstIndex(where: { $0.id == active }) else { return }
        let next = state.windows[(idx + delta + state.windows.count) % state.windows.count]
        selectWindow(next.id)
    }
```

- [ ] **Step 3: Commit (CI-gated)**

```bash
git add App/TmuxRuntime.swift App/ConnectionViewModel.swift
git commit -m "feat(keybar): vm hooks — input router, pane zoom, window prev/next"
```

(No local build — Tasks 5–6 are validated together on the macOS CI job after Task 6.)

---

### Task 6: App — KeybarView + slot views + mount

**Files:**
- Create: `App/Keybar/KeybarView.swift`
- Create: `App/Keybar/KeybarSlotViews.swift`
- Modify: `App/SessionView.swift`

**Validation:** App tier — macOS CI build only. Interaction/visual verification deferred to a Simulator/device run (see "Verification reality").

**Interfaces:**
- Consumes: `KeybarLayout` (Task 3), `ConnectionViewModel.keybar`/`zoomActivePane`/`selectNextWindow`/`selectPrevWindow`, `Theme.Keybar` tokens, `@Environment(\.theme)`.
- Produces: a `KeybarView(layout:vm:)` rendering the locked region (fixed) + a horizontally scrollable region; slot subviews for Esc pill, Pad, Modifier, Tab, Symbol. Mounted via `.safeAreaInset(edge: .bottom)` on the session content.

- [ ] **Step 1: Implement `App/Keybar/KeybarSlotViews.swift`** — one SwiftUI view per slot kind. Keep gestures minimal-but-correct; route to `vm.keybar` / vm actions.

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Shared slot chrome: themed background + label, fixed min size.
private struct SlotChrome<Label: View>: View {
    let bg: Color
    @ViewBuilder var label: () -> Label
    var body: some View {
        label()
            .frame(minWidth: 34, minHeight: 34)
            .padding(.horizontal, 6)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// A plain symbol slot (tap = send the literal character).
struct SymbolSlotView: View {
    let symbol: String
    let vm: ConnectionViewModel
    @Environment(\.theme) private var theme
    var body: some View {
        SlotChrome(bg: Color(theme.keybar.slotBg)) {
            Text(symbol).font(.system(.body, design: .monospaced)).foregroundStyle(Color(theme.text.primary))
        }
        .onTapGesture { if let c = symbol.first { vm.keybar.tapSymbol(c) } }
    }
}

/// Tab slot.
struct TabSlotView: View {
    let vm: ConnectionViewModel
    @Environment(\.theme) private var theme
    var body: some View {
        SlotChrome(bg: Color(theme.keybar.slotBg)) {
            Text("⇥").foregroundStyle(Color(theme.text.primary))
        }
        .onTapGesture { vm.keybar.tapTab() }
    }
}

/// Modifier slot: tap=arm Ctrl, double-tap=lock Ctrl, swipe-up=Alt, swipe-down=Shift.
struct ModifierSlotView: View {
    let vm: ConnectionViewModel
    @Environment(\.theme) private var theme
    private var bg: Color {
        switch vm.keybar.modifiers.ctrl {
        case .locked: return Color(theme.keybar.slotBgLocked)
        case .armed:  return Color(theme.keybar.slotBgArmed)
        case .off:    return Color(theme.keybar.slotBg)
        }
    }
    var body: some View {
        SlotChrome(bg: bg) {
            Text("⌃").foregroundStyle(Color(theme.text.primary))
        }
        // Double-tap must be registered before single-tap so it wins the gesture.
        .onTapGesture(count: 2) { vm.keybar.doubleTapCtrl() }
        .onTapGesture(count: 1) { vm.keybar.tapCtrl() }
        .gesture(DragGesture(minimumDistance: 12).onEnded { g in
            if g.translation.height < -12 { vm.keybar.armAlt() }
            else if g.translation.height > 12 { vm.keybar.armShift() }
        })
    }
}

/// Esc pill: tap=Esc; swipe-left/right = prev/next window. (Pickers = later slice.)
struct EscPillView: View {
    let vm: ConnectionViewModel
    @Environment(\.theme) private var theme
    var body: some View {
        SlotChrome(bg: Color(theme.keybar.slotBg)) {
            Text("Esc").font(.caption).foregroundStyle(Color(theme.text.primary))
        }
        .onTapGesture { vm.keybar.tapEscape() }
        .gesture(DragGesture(minimumDistance: 18).onEnded { g in
            if g.translation.width > 18 { vm.selectNextWindow() }
            else if g.translation.width < -18 { vm.selectPrevWindow() }
        })
    }
}

/// Pad: drag = arrow key (dominant axis), tap = zoom active pane.
/// (Long-press pane-mode + splits = a later slice.)
struct PadView: View {
    let vm: ConnectionViewModel
    @Environment(\.theme) private var theme
    var body: some View {
        SlotChrome(bg: Color(theme.keybar.slotBg)) {
            Image(systemName: "dpad").foregroundStyle(Color(theme.text.primary))
        }
        .onTapGesture { vm.zoomActivePane() }
        .gesture(DragGesture(minimumDistance: 16).onEnded { g in
            let dx = g.translation.width, dy = g.translation.height
            if abs(dx) > abs(dy) { vm.keybar.arrow(dx > 0 ? .right : .left) }
            else { vm.keybar.arrow(dy > 0 ? .down : .up) }
        })
    }
}
```

- [ ] **Step 2: Implement `App/Keybar/KeybarView.swift`** — render the layout: fixed locked region + horizontally scrollable region.

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// The keyboard accessory bar. Locked region renders fixed at the leading edge;
/// the scroll region pans horizontally. 4a renders `KeybarLayout.default`;
/// customization (4d) will supply a user layout.
struct KeybarView: View {
    let layout: KeybarLayout
    @ObservedObject var vm: ConnectionViewModel
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(layout.locked.enumerated()), id: \.offset) { _, slot in
                slotView(slot)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(layout.scroll.enumerated()), id: \.offset) { _, slot in
                        slotView(slot)
                    }
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(Color(theme.surface.panel))
    }

    @ViewBuilder private func slotView(_ slot: KeybarSlot) -> some View {
        switch slot {
        case .escPill:        EscPillView(vm: vm)
        case .pad:            PadView(vm: vm)
        case .modifier:       ModifierSlotView(vm: vm)
        case .tab:            TabSlotView(vm: vm)
        case .symbol(let s):  SymbolSlotView(symbol: s, vm: vm)
        }
    }
}
```

- [ ] **Step 3: Mount in `SessionView`** — attach the bar to the bottom of the live-shell content. In `App/SessionView.swift`, in the `if case .shell = vm.state` branch, add a `.safeAreaInset` on the content that renders the terminal (both the tmux `VStack` and the raw `TerminalScreen`). Add, after the existing `.overlay`/`.animation` modifiers on that content:

```swift
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        KeybarView(layout: .default, vm: vm)
                    }
```

(If the content is split across the tmux-vs-raw branches, apply the same inset to each so the bar is present in both modes. The `ProgressView`/prompt/status branches get no keybar.)

- [ ] **Step 4: Commit + validate on macOS CI**

```bash
git add App/Keybar/KeybarView.swift App/Keybar/KeybarSlotViews.swift App/SessionView.swift
git commit -m "feat(keybar): MVP keybar view + slots, mounted in the session"
git push -u github feat/phase-4a-keybar-mvp
gh run watch $(gh run list --branch feat/phase-4a-keybar-mvp --limit 1 --json databaseId -q '.[0].databaseId')
```
Expected: `macos` job green (compiles the keybar views + vm hooks). `linux-rust` flake → `gh run rerun <id> --failed`. **Note:** green CI proves it *compiles*, not that the bar renders/behaves correctly — that needs a Simulator/device run.

---

## Wrap-up

- [ ] **Full SemicolynKit suite green:** `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test` — all existing + the 4 new keybar suites pass.
- [ ] **Update `TODO.md`** — Phase 4 row: note keybar MVP (mount + core input slots) landed; 4b–4e (promotions/Fn, predictor strip, customization, external keyboard) pending. Commit `docs: mark Phase 4a keybar MVP done`.
- [ ] **Open PR** to `github` `main` (squash-merge). State plainly that interaction/visual verification is pending a Simulator/device run.

---

## Self-Review notes

- **Spec coverage:** locked-left `Esc·Pad·Modifier·Tab` → Task 3 + Task 6; default symbols → Task 3; Ctrl double-tap-lock + Alt/Shift one-shot → Task 2; keystroke encoding (control/meta/arrows/Shift-Tab) → Task 1; Esc tap + window swipes, Pad arrows + zoom → Tasks 4–6; scroll region → Task 6.
- **Deliberately deferred (later 4x slices, flagged in Global Constraints):** promotions render + Fn (4b), predictor strip (4c), Settings→Keybar editor + custom slots + macros + reverse-bar (4d), external keyboard (4e), Esc-pill pickers + swipe-up/down, Pad long-press pane-mode + splits. None are gaps.
- **Known limitations (documented, not gaps):** (1) the bar mounts via `safeAreaInset(.bottom)` — a global always-visible bar that does NOT track above the iOS soft keyboard; the `inputAccessoryView` approach is a follow-up pending a Simulator check (Verification reality). (2) `applicationCursorKeys` is hard-`false` in v1; per-pane DECCKM read is a 4b refinement. (3) Interaction/visual behavior is unverified by this toolchain — macOS CI is build-only.
