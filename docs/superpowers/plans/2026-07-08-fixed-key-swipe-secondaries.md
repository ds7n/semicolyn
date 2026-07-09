<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Fixed-Key Swipe Secondaries Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the fixed keybar keys (symbols, Tab, F1–F12) swipe-up/down secondaries with built-in defaults + per-key user overrides + a full override editor, rendered with the existing dim corner-glyph pattern.

**Architecture:** Pure Kit model — `SecondaryValue` (literal | key+modifiers), `SwipeSecondaries`, `FixedKeyID`, a `FixedKeyDefaults` map, and `resolveSecondaries(override-wins)` — all Linux-tested. A new `KeybarInputRouter.emitSecondary(_:)` reuses the existing `encodeKey`. The App replicates the promotion-slot swipe+glyph pattern onto the fixed slots and adds a `FixedKeySecondaryEditorView` reached by a pencil in `KeybarEditorView`.

**Tech Stack:** Swift 6 (Kit, XCTest on Linux), SwiftUI (App), Docker dev image for `swift test`.

**Spec:** `docs/superpowers/specs/2026-07-08-fixed-key-swipe-secondaries-design.md`

## Global Constraints

- **Two-tier rule:** `Sources/SemicolynKit/` = pure logic, Linux-tested, NO `import UIKit`/`SwiftUI`, `Sendable`. `App/` = Apple-only, macOS-CI + device gated.
- SPDX header (both lines) on every new source file.
- Tests real: assert exact observable values (no tautologies); EP over the input classes.
- Vertical swipes only (horizontal reserved). Swipe threshold = 12pt (match `PromotionSlotView`).
- Scope: symbols + Tab + F1–F12. Built-in defaults + user overrides (separate map, no layout-schema migration). Override replaces the whole `SwipeSecondaries` pair for a key.
- Editor is FULL: per direction a None / Literal / Special-key(+modifiers) choice.
- Reuse existing `encodeKey(_:modifiers:applicationCursorKeys:)` for bytes; reuse the dim-glyph overlay + `DragGesture(minimumDistance: 12)` pattern from `PromotionSlotView`/`CustomSlotView`.
- Conventional commits; branch `feat/fixed-key-swipe-secondaries` (spec committed, off current main); squash-merge.
- Kit test cmd (sandbox-disabled for Docker socket): `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <name>`.

## Existing types this builds on (verified)

- `KeyInput` enum: `.char(Character)`, `.escape`, `.tab`, `.enter`, `.backspace`, `.arrow(ArrowDirection)`, `.function(Int)` — `Equatable, Sendable` (NOT yet Codable — Task 1 adds it).
- `KeyModifiers { control, option, shift: Bool }` — `Equatable, Sendable, Codable`.
- `encodeKey(_ key: KeyInput, modifiers: KeyModifiers, applicationCursorKeys: Bool) -> [UInt8]` — the encoder; `.tab` + shift already emits `ESC [ Z`.
- `KeybarInputRouter` (the `vm.keybar` type): has `send`, `applicationCursorKeys`, `tapSymbol`, `tapTab`, `tapFKey`, `fire(KeyInput)` (private), `encodeKey` in scope.
- `KeybarSettings { layout, direction, library, hideKeybarWithHardwareKeyboard }` — `Codable`.
- `KeybarSlot.symbol(String)` / `.tab` / F-keys (`.fkey(Int)` in `KeybarScrollContent`).
- Slot views: `SymbolSlotView`, `FkeySlotView`, the Tab slot — in `App/Keybar/KeybarSlotViews.swift`. `PromotionSlotView` is the swipe+glyph template.

---

### Task 1: Kit — secondary model + FixedKeyDefaults + resolve (Linux-tested)

**Files:**
- Create: `Sources/SemicolynKit/Keybar/FixedKeySecondary.swift`
- Modify: `Sources/SemicolynKit/Keybar/KeyEncoding.swift` (add `Codable` to `KeyInput`)
- Test: `Tests/SemicolynKitTests/FixedKeySecondaryTests.swift`

**Interfaces:**
- Consumes: `KeyInput`, `KeyModifiers` (existing).
- Produces:
  - `KeyInput: Codable` (added).
  - `public enum SecondaryValue: Equatable, Sendable, Codable { case literal(String); case key(KeyInput, KeyModifiers) }`
  - `public struct SwipeSecondaries: Equatable, Sendable, Codable { public var up: SecondaryValue?; public var down: SecondaryValue?; public init(up:down:) }`
  - `public enum FixedKeyID: Hashable, Sendable, Codable { case symbol(String); case tab; case fkey(Int) }`
  - `public enum FixedKeyDefaults { public static func defaults(for id: FixedKeyID) -> SwipeSecondaries }`
  - `public func resolveSecondaries(for id: FixedKeyID, overrides: [FixedKeyID: SwipeSecondaries]) -> SwipeSecondaries`

- [ ] **Step 1: Write the failing test**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class FixedKeySecondaryTests: XCTestCase {
    // Codable round-trip for each SecondaryValue case.
    func testSecondaryValueLiteralRoundTrip() throws {
        let v = SecondaryValue.literal("_")
        XCTAssertEqual(try JSONDecoder().decode(SecondaryValue.self, from: JSONEncoder().encode(v)), v)
    }
    func testSecondaryValueKeyRoundTrip() throws {
        let v = SecondaryValue.key(.tab, KeyModifiers(shift: true))
        XCTAssertEqual(try JSONDecoder().decode(SecondaryValue.self, from: JSONEncoder().encode(v)), v)
    }
    func testSwipeSecondariesRoundTrip() throws {
        let s = SwipeSecondaries(up: .literal("_"), down: .key(.function(5), KeyModifiers()))
        XCTAssertEqual(try JSONDecoder().decode(SwipeSecondaries.self, from: JSONEncoder().encode(s)), s)
    }
    func testFixedKeyIDRoundTrip() throws {
        for id in [FixedKeyID.symbol("-"), .tab, .fkey(3)] {
            XCTAssertEqual(try JSONDecoder().decode(FixedKeyID.self, from: JSONEncoder().encode(id)), id)
        }
    }
    // Built-in defaults: representative exact values.
    func testDefaultDashToUnderscore() {
        XCTAssertEqual(FixedKeyDefaults.defaults(for: .symbol("-")).up, .literal("_"))
    }
    func testDefaultSlashToBackslash() {
        XCTAssertEqual(FixedKeyDefaults.defaults(for: .symbol("/")).up, .literal("\\"))
    }
    func testDefaultTabToShiftTab() {
        XCTAssertEqual(FixedKeyDefaults.defaults(for: .tab).up, .key(.tab, KeyModifiers(shift: true)))
    }
    func testDefaultFKeyEmpty() {
        XCTAssertEqual(FixedKeyDefaults.defaults(for: .fkey(1)), SwipeSecondaries())
    }
    func testDefaultUnknownSymbolEmpty() {
        XCTAssertEqual(FixedKeyDefaults.defaults(for: .symbol("Z")), SwipeSecondaries())
    }
    // Resolution: override wins; absent → default.
    func testResolveOverrideWins() {
        let ov: [FixedKeyID: SwipeSecondaries] = [.symbol("-"): SwipeSecondaries(up: .literal("X"))]
        XCTAssertEqual(resolveSecondaries(for: .symbol("-"), overrides: ov).up, .literal("X"))
    }
    func testResolveFallsBackToDefault() {
        XCTAssertEqual(resolveSecondaries(for: .symbol("-"), overrides: [:]).up, .literal("_"))
    }
    func testResolveNoDefaultNoOverrideIsEmpty() {
        XCTAssertEqual(resolveSecondaries(for: .fkey(2), overrides: [:]), SwipeSecondaries())
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter FixedKeySecondaryTests` (sandbox-disabled)
Expected: FAIL — types undefined (and `KeyInput` not Codable).

- [ ] **Step 3: Add `Codable` to `KeyInput`**

In `Sources/SemicolynKit/Keybar/KeyEncoding.swift`, change:
```swift
public enum KeyInput: Equatable, Sendable {
```
to:
```swift
public enum KeyInput: Equatable, Sendable, Codable {
```
(All associated values — `Character`, `Int`, `ArrowDirection` — are Codable; `Character` is Codable via its `String` conformance in Swift. If the compiler rejects `Character` auto-Codable, add an explicit `Codable` conformance encoding `.char` as a `String`; the plan's fallback: a hand-written `Codable` mirroring `KeybarSlot`'s discriminator style. Verify on the failing→passing run.)

- [ ] **Step 4: Write `FixedKeySecondary.swift`**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// What a swipe on a fixed key emits: a literal string, or a logical key + modifiers.
public enum SecondaryValue: Equatable, Sendable, Codable {
    case literal(String)
    case key(KeyInput, KeyModifiers)
}

/// The swipe-up / swipe-down secondaries bound to a fixed key. Either may be nil.
public struct SwipeSecondaries: Equatable, Sendable, Codable {
    public var up: SecondaryValue?
    public var down: SecondaryValue?
    public init(up: SecondaryValue? = nil, down: SecondaryValue? = nil) {
        self.up = up; self.down = down
    }
}

/// A stable, Codable identifier for a fixed key — the override-map key.
public enum FixedKeyID: Hashable, Sendable, Codable {
    case symbol(String)
    case tab
    case fkey(Int)
}

/// Built-in swipe secondaries for the fixed keys. Data, not logic: a curated
/// table of sensible defaults. Symbols/keys not listed have no default.
public enum FixedKeyDefaults {
    public static func defaults(for id: FixedKeyID) -> SwipeSecondaries {
        switch id {
        case .tab:
            return SwipeSecondaries(up: .key(.tab, KeyModifiers(shift: true)))  // Shift-Tab
        case .fkey:
            return SwipeSecondaries()  // no natural default; user-overridable
        case .symbol(let s):
            return symbolTable[s] ?? SwipeSecondaries()
        }
    }

    /// Common symbol pairs. Swipe-up = the "shifted/partner" glyph.
    private static let symbolTable: [String: SwipeSecondaries] = [
        "-": SwipeSecondaries(up: .literal("_")),
        "/": SwipeSecondaries(up: .literal("\\")),
        ".": SwipeSecondaries(up: .literal("..")),
        ":": SwipeSecondaries(up: .literal(";")),
        "'": SwipeSecondaries(up: .literal("\"")),
        "`": SwipeSecondaries(up: .literal("~")),
        "|": SwipeSecondaries(up: .literal("&")),
        "=": SwipeSecondaries(up: .literal("+")),
        "*": SwipeSecondaries(up: .literal("^")),
    ]
}

/// Resolve the effective secondaries for a fixed key: a user override replaces
/// the whole pair; otherwise the built-in default; otherwise empty. Never merges
/// per-direction (predictable).
public func resolveSecondaries(for id: FixedKeyID,
                               overrides: [FixedKeyID: SwipeSecondaries]) -> SwipeSecondaries {
    overrides[id] ?? FixedKeyDefaults.defaults(for: id)
}
```

- [ ] **Step 5: Run tests + full sweep**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter FixedKeySecondaryTests` then `… swift test`.
Expected: FixedKeySecondaryTests all pass; full sweep green (report total).

- [ ] **Step 6: Commit**

```bash
git add Sources/SemicolynKit/Keybar/FixedKeySecondary.swift Sources/SemicolynKit/Keybar/KeyEncoding.swift Tests/SemicolynKitTests/FixedKeySecondaryTests.swift
git commit -m "feat(kit): fixed-key swipe-secondary model, defaults, and resolver"
```

---

### Task 2: Kit — persist override map + router emit (Linux-tested)

**Files:**
- Modify: `Sources/SemicolynKit/Keybar/KeybarSettings.swift` (add `fixedKeySecondaries`)
- Modify: `Sources/SemicolynKit/Keybar/KeybarInputRouter.swift` (add `emitSecondary`)
- Test: `Tests/SemicolynKitTests/FixedKeySecondaryTests.swift` (extend)

**Interfaces:**
- Consumes: `SecondaryValue`, `SwipeSecondaries`, `FixedKeyID` (Task 1); `encodeKey` (existing).
- Produces:
  - `KeybarSettings.fixedKeySecondaries: [FixedKeyID: SwipeSecondaries]` (default `[:]`).
  - `KeybarInputRouter.emitSecondary(_ value: SecondaryValue)` — emits a literal's bytes or `encodeKey(input, modifiers:applicationCursorKeys:)` bytes via `send`.

- [ ] **Step 1: Write the failing test (append)**

```swift
    // KeybarSettings persists the override map.
    func testKeybarSettingsCarriesOverrides() throws {
        var s = KeybarSettings()
        s.fixedKeySecondaries = [.symbol("-"): SwipeSecondaries(up: .literal("X"))]
        let back = try JSONDecoder().decode(KeybarSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.fixedKeySecondaries[.symbol("-")]?.up, .literal("X"))
    }
    // Router emits the right bytes for each SecondaryValue kind.
    func testEmitSecondaryLiteral() {
        var sent: [UInt8] = []
        let r = KeybarInputRouter(applicationCursorKeys: { false }, send: { sent += $0 })
        r.emitSecondary(.literal("_"))
        XCTAssertEqual(sent, Array("_".utf8))
    }
    func testEmitSecondaryShiftTab() {
        var sent: [UInt8] = []
        let r = KeybarInputRouter(applicationCursorKeys: { false }, send: { sent += $0 })
        r.emitSecondary(.key(.tab, KeyModifiers(shift: true)))
        XCTAssertEqual(sent, Array("\u{1b}[Z".utf8))   // back-tab
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `… swift test --filter FixedKeySecondaryTests` — FAIL (`fixedKeySecondaries`/`emitSecondary` undefined).

- [ ] **Step 3: Add the settings field**

In `KeybarSettings.swift`, add the stored property + its `init`/`Codable` participation:
```swift
    /// User overrides for fixed-key swipe secondaries (symbol/tab/fkey). Empty = all defaults.
    public var fixedKeySecondaries: [FixedKeyID: SwipeSecondaries] = [:]
```
Note: `[FixedKeyID: …]` — `FixedKeyID` is `Codable & Hashable`, but a Swift `Dictionary` with a non-`String`/`Int` key encodes as a JSON ARRAY of alternating key/value. That is valid Codable and round-trips; the test asserts the round-trip. If `KeybarSettings` uses a memberwise `init`, add the param with a `[:]` default at the END so existing call-sites are unaffected. If it has custom `Codable`, add the key with `decodeIfPresent(… ) ?? [:]` (back-compat for old persisted blobs).

- [ ] **Step 4: Add `emitSecondary` to the router**

In `KeybarInputRouter.swift`:
```swift
    /// Emit a fixed-key swipe secondary. A literal sends its UTF-8 bytes; a key
    /// secondary encodes through `encodeKey` with its modifiers (e.g. Shift-Tab).
    public func emitSecondary(_ value: SecondaryValue) {
        switch value {
        case .literal(let s):
            let bytes = Array(s.utf8)
            if !bytes.isEmpty { send(bytes) }
        case .key(let input, let mods):
            let bytes = encodeKey(input, modifiers: mods, applicationCursorKeys: applicationCursorKeys())
            if !bytes.isEmpty { send(bytes) }
        }
    }
```
(`send` and `applicationCursorKeys` are already stored on the router. This does NOT touch the armed `ModifierState` — a secondary carries its own modifiers, like a macro.)

- [ ] **Step 5: Run tests + full sweep** — `… --filter FixedKeySecondaryTests` then `… swift test`. Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/SemicolynKit/Keybar/KeybarSettings.swift Sources/SemicolynKit/Keybar/KeybarInputRouter.swift Tests/SemicolynKitTests/FixedKeySecondaryTests.swift
git commit -m "feat(kit): persist fixed-key overrides + router emitSecondary"
```

---

### Task 3: App — swipe gestures + glyphs on fixed slots

**Files:**
- Modify: `App/Keybar/KeybarSlotViews.swift` (SymbolSlotView, FkeySlotView, Tab slot)

**Interfaces:**
- Consumes: `resolveSecondaries`, `SwipeSecondaries`, `SecondaryValue`, `FixedKeyID` (Kit); `KeybarInputRouter.emitSecondary` + `tapSymbol`/`tapTab`/`tapFKey` (Kit); `vm.keybar` (the router); the keybar's `KeybarSettings.fixedKeySecondaries`.
- Produces: fixed slots emit swipe-up/down secondaries + show dim glyphs.

> App-tier: macOS-CI + device gated. No local build.

- [ ] **Step 1: Add a shared swipe+glyph modifier**

In `App/Keybar/KeybarSlotViews.swift`, add a helper the fixed slots reuse (mirrors `PromotionSlotView`'s gesture + `CustomSlotView`'s glyph overlays):

```swift
private extension View {
    /// Attach vertical swipe-up/down secondaries + dim corner glyphs to a fixed slot.
    /// `secondaries` is the resolved pair; `emit` fires a chosen SecondaryValue.
    @ViewBuilder
    func fixedKeySwipes(_ secondaries: SwipeSecondaries,
                        emit: @escaping (SecondaryValue) -> Void) -> some View {
        self
            .overlay(alignment: .top) {
                if let up = secondaries.up { Text(glyphLabel(up)).font(.system(size: 7)).foregroundStyle(.secondary) }
            }
            .overlay(alignment: .bottom) {
                if let down = secondaries.down { Text(glyphLabel(down)).font(.system(size: 7)).foregroundStyle(.secondary) }
            }
            .gesture(DragGesture(minimumDistance: 12).onEnded { g in
                if g.translation.height < -12, let up = secondaries.up { emit(up) }
                else if g.translation.height > 12, let down = secondaries.down { emit(down) }
            })
    }
}

/// Short display label for a secondary: the literal itself, or a symbol for a key.
private func glyphLabel(_ v: SecondaryValue) -> String {
    switch v {
    case .literal(let s): return s
    case .key(let input, let mods):
        switch input {
        case .tab: return mods.shift ? "⇤" : "⇥"
        case .escape: return "⎋"
        case .enter: return "⏎"
        case .backspace: return "⌫"
        case .arrow(let d): return ["up":"↑","down":"↓","left":"←","right":"→"][d.rawValue] ?? "→"
        case .function(let n): return "F\(n)"
        case .char(let c): return String(c)
        }
    }
}
```

- [ ] **Step 2: Wire the symbol slot**

In `SymbolSlotView`, compute the resolved secondaries and attach the modifier. The view needs the override map + the router; thread the keybar settings in (the keybar already has `keybarSettings` + `vm`). Example:
```swift
        // inside SymbolSlotView body, on the slot chrome view:
        .fixedKeySwipes(resolveSecondaries(for: .symbol(String(symbol)),
                                           overrides: keybarSettings.settings.fixedKeySecondaries)) { v in
            vm.keybar.emitSecondary(v)
        }
```
`SymbolSlotView` must receive `keybarSettings` (a `KeybarSettingsStore`) — add it as a property and pass it from the parent that instantiates symbol slots (the keybar content view already holds `keybarSettings`). Match how `vm` is already passed.

- [ ] **Step 3: Wire the Tab slot and `FkeySlotView`**

Same `.fixedKeySwipes(...)` with `FixedKeyID.tab` and `.fkey(n)` respectively, emitting via `vm.keybar.emitSecondary`. The Tab slot's `id` is `.tab`; the F-key slot's is `.fkey(n)` where `n` is its number.

- [ ] **Step 4: Grep-verify the fixed slots now resolve secondaries**

Run: `rg -n "fixedKeySwipes|resolveSecondaries" App/Keybar/KeybarSlotViews.swift`
Expected: the helper + one call per fixed slot type (symbol, tab, fkey).

- [ ] **Step 5: Commit**

```bash
git add App/Keybar/KeybarSlotViews.swift
git commit -m "feat(app): swipe secondaries + dim glyphs on fixed keybar slots"
```

---

### Task 4: App — the override editor view

**Files:**
- Create: `App/Keybar/FixedKeySecondaryEditorView.swift`

**Interfaces:**
- Consumes: `FixedKeyID`, `SwipeSecondaries`, `SecondaryValue`, `KeyInput`, `KeyModifiers`, `FixedKeyDefaults` (Kit); `KeybarSettingsStore`.
- Produces: `FixedKeySecondaryEditorView(store: KeybarSettingsStore, id: FixedKeyID)` — edits `store.settings.fixedKeySecondaries[id]`.

- [ ] **Step 1: Write the editor**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Per-key override editor for a fixed key's swipe-up/down secondaries. Each
/// direction is None / Literal / Special-key(+modifiers). Writes the whole
/// SwipeSecondaries pair to `store.settings.fixedKeySecondaries[id]`; "Clear
/// override" removes the entry (reverts to the built-in default).
struct FixedKeySecondaryEditorView: View {
    @ObservedObject var store: KeybarSettingsStore
    let id: FixedKeyID
    @Environment(\.dismiss) private var dismiss

    private var effective: SwipeSecondaries {
        resolveSecondaries(for: id, overrides: store.settings.fixedKeySecondaries)
    }

    var body: some View {
        Form {
            Section("Swipe up")  { directionEditor(\.up) }
            Section("Swipe down"){ directionEditor(\.down) }
            Section {
                Button("Clear override (use defaults)", role: .destructive) {
                    store.settings.fixedKeySecondaries[id] = nil
                }
            }
        }
        .navigationTitle(title)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { InputClickFeedback.play(); dismiss() } } }
    }

    private var title: String {
        switch id {
        case .symbol(let s): return "Swipe: \(s)"
        case .tab: return "Swipe: Tab"
        case .fkey(let n): return "Swipe: F\(n)"
        }
    }

    /// Editor for one direction (keyPath into SwipeSecondaries). Reads/writes the
    /// override map, seeding from the current effective value.
    @ViewBuilder
    private func directionEditor(_ dir: WritableKeyPath<SwipeSecondaries, SecondaryValue?>) -> some View {
        let current = effective[keyPath: dir]
        // Mode picker: None / Literal / Key
        Picker("Action", selection: Binding(
            get: { mode(of: current) },
            set: { setMode($0, dir: dir) })) {
                Text("None").tag(0); Text("Literal").tag(1); Text("Special key").tag(2)
        }.pickerStyle(.segmented)

        if case .literal(let s)? = binding(dir).wrappedValue {
            TextField("Character(s)", text: Binding(
                get: { s },
                set: { writeOverride(dir: dir, .literal($0)) }))
                .autocorrectionDisabled()
        } else if case .key(let input, let mods)? = binding(dir).wrappedValue {
            keyPicker(input: input, mods: mods, dir: dir)
        }
    }

    // Helpers: mode(of:), setMode, writeOverride, binding, keyPicker.
    private func mode(of v: SecondaryValue?) -> Int {
        switch v { case .none: return 0; case .literal: return 1; case .key: return 2 }
    }
    private func setMode(_ m: Int, dir: WritableKeyPath<SwipeSecondaries, SecondaryValue?>) {
        switch m {
        case 0: writeOverride(dir: dir, nil)
        case 1: writeOverride(dir: dir, .literal(""))
        default: writeOverride(dir: dir, .key(.tab, KeyModifiers()))
        }
    }
    /// The current override pair for this key (seeded from effective so editing
    /// starts from what the user sees), used to read the live per-direction value.
    private func binding(_ dir: WritableKeyPath<SwipeSecondaries, SecondaryValue?>) -> Binding<SecondaryValue?> {
        Binding(
            get: { (store.settings.fixedKeySecondaries[id] ?? effective)[keyPath: dir] },
            set: { writeOverride(dir: dir, $0) })
    }
    private func writeOverride(dir: WritableKeyPath<SwipeSecondaries, SecondaryValue?>, _ v: SecondaryValue?) {
        var pair = store.settings.fixedKeySecondaries[id] ?? effective
        pair[keyPath: dir] = v
        store.settings.fixedKeySecondaries[id] = pair
    }
    @ViewBuilder
    private func keyPicker(input: KeyInput, mods: KeyModifiers,
                           dir: WritableKeyPath<SwipeSecondaries, SecondaryValue?>) -> some View {
        // Minimal key set for v1: Tab, Esc, Enter, Backspace, F1–F12, arrows.
        Picker("Key", selection: Binding(
            get: { keyTag(input) },
            set: { writeOverride(dir: dir, .key(keyFromTag($0), mods)) })) {
                Text("Tab").tag(0); Text("Esc").tag(1); Text("Enter").tag(2); Text("Backspace").tag(3)
                Text("↑").tag(4); Text("↓").tag(5); Text("←").tag(6); Text("→").tag(7)
                ForEach(1...12, id: \.self) { Text("F\($0)").tag(100 + $0) }
        }
        Toggle("Control", isOn: modBinding(\.control, input: input, mods: mods, dir: dir))
        Toggle("Option",  isOn: modBinding(\.option,  input: input, mods: mods, dir: dir))
        Toggle("Shift",   isOn: modBinding(\.shift,   input: input, mods: mods, dir: dir))
    }
    private func modBinding(_ kp: WritableKeyPath<KeyModifiers, Bool>, input: KeyInput, mods: KeyModifiers,
                            dir: WritableKeyPath<SwipeSecondaries, SecondaryValue?>) -> Binding<Bool> {
        Binding(get: { mods[keyPath: kp] },
                set: { var m = mods; m[keyPath: kp] = $0; writeOverride(dir: dir, .key(input, m)) })
    }
    private func keyTag(_ k: KeyInput) -> Int {
        switch k {
        case .tab: return 0; case .escape: return 1; case .enter: return 2; case .backspace: return 3
        case .arrow(let d): return ["up":4,"down":5,"left":6,"right":7][d.rawValue] ?? 4
        case .function(let n): return 100 + n
        case .char: return 0
        }
    }
    private func keyFromTag(_ t: Int) -> KeyInput {
        switch t {
        case 0: return .tab; case 1: return .escape; case 2: return .enter; case 3: return .backspace
        case 4: return .arrow(.up); case 5: return .arrow(.down); case 6: return .arrow(.left); case 7: return .arrow(.right)
        default: return .function(max(1, min(12, t - 100)))
        }
    }
}
```

- [ ] **Step 2: Self-review (no compiler).** Confirm every Kit symbol used exists (Tasks 1–2); the `Binding` closures read/write `store.settings.fixedKeySecondaries[id]`; `InputClickFeedback.play()` on Done; SPDX header. macOS CI is the gate.

- [ ] **Step 3: Commit**

```bash
git add App/Keybar/FixedKeySecondaryEditorView.swift
git commit -m "feat(app): fixed-key swipe-secondary override editor"
```

---

### Task 5: App — wire the editor into KeybarEditorView

**Files:**
- Modify: `App/Keybar/KeybarEditorView.swift`

**Interfaces:**
- Consumes: `FixedKeySecondaryEditorView(store:id:)` (Task 4); the existing `editorSheet` mechanism.
- Produces: a pencil on fixed-key rows (symbol/tab/fkey) opening the editor.

- [ ] **Step 1: Add an editor-sheet case for a fixed key**

In `KeybarEditorView`'s `editorSheet` enum (currently `.launcher/.createMacro/.createSlot/.editSlot`), add:
```swift
        case editFixed(FixedKeyID)
```
and its `id` string (mirror the existing `case .editSlot(let s): return "edit-\(s.id.raw)"` style):
```swift
        case .editFixed(let k): return "editfixed-\(k)"
```
and in the `.sheet(item:)` switch:
```swift
                case .editFixed(let k): FixedKeySecondaryEditorView(store: store, id: k)
```
(`FixedKeyID` is `Hashable` — usable in the `Identifiable` id string via interpolation.)

- [ ] **Step 2: Add the pencil affordance to fixed-key rows**

In the `row(_ slot:inScroll:)` builder, alongside the existing custom-slot pencil, add a branch for fixed keys mapping `KeybarSlot` → `FixedKeyID`:
```swift
            if let fixedID = fixedKeyID(for: slot) {
                Button { editorSheet = .editFixed(fixedID) } label: {
                    Image(systemName: "pencil").font(.footnote)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Edit swipe secondaries")
            }
```
and a helper:
```swift
    /// Map a fixed KeybarSlot to its FixedKeyID (nil for non-fixed slots).
    private func fixedKeyID(for slot: KeybarSlot) -> FixedKeyID? {
        switch slot {
        case .symbol(let s): return .symbol(s)
        case .tab: return .tab
        default: return nil   // fkeys render in the scroll region; see note
        }
    }
```
NOTE on F-keys: F-keys are a scroll-region concept (`KeybarScrollContent.fkey(Int)`), not a `KeybarSlot` case in the editor's locked/scroll lists. For v1, expose the fixed-key editor for **symbol + tab rows** here; F-key swipe editing is reachable only if F-keys appear as editable rows. If they don't, the F-key defaults (empty) + on-bar swipe still work; the editor for F-keys is deferred UNLESS the editor already lists them — verify against the current editor row set and include `.fkey` in `fixedKeyID(for:)` only if F-key rows exist. (This keeps Task 5 honest to the real row model.)

- [ ] **Step 3: Grep-verify** `rg -n "editFixed|FixedKeySecondaryEditorView|fixedKeyID" App/Keybar/KeybarEditorView.swift` → shows the case, the sheet, the pencil, the helper.

- [ ] **Step 4: Commit**

```bash
git add App/Keybar/KeybarEditorView.swift
git commit -m "feat(app): edit fixed-key swipe secondaries from the keybar editor"
```

---

### Task 6: CI green + device verification

**Files:** none.

- [ ] **Step 1: Push, open PR, wait for CI**

```bash
git push -u github feat/fixed-key-swipe-secondaries
gh pr create --title "feat: fixed-key swipe secondaries (defaults + overrides + editor)" \
  --body "Implements docs/superpowers/specs/2026-07-08-fixed-key-swipe-secondaries-design.md"
```
Expected: `linux-swift` (runs the Kit tests), `linux-rust`, `lint`, **`macos`** all green. If `macos` fails on the `ftp.gnu.org`/ncurses download step (a known network flake unrelated to code), `gh run rerun <id> --failed`.

- [ ] **Step 2: Fix any macOS compile errors, re-push.** Likely: a `Character` Codable wrinkle (handled in T1); an `@MainActor` isolation error → `MainActor.assumeIsolated { }` (idiom already in the codebase); a slot view missing the threaded `keybarSettings`.

- [ ] **Step 3: Device verify.**
  1. Swipe up on `-` → `_`; on `/` → `\`; glyphs show the secondary dim at top.
  2. Swipe up on Tab → Shift-Tab (back-tab: cursor moves to prev field in e.g. a TUI).
  3. Open keybar editor → pencil on a symbol row → editor: set a literal override → swipe reflects it live; "Clear override" reverts to default.
  4. Special-key override: set a symbol's swipe to F5 via the picker → swipe fires F5.
  5. Existing custom/promotion/modifier swipes still work (no regression).

- [ ] **Step 4: Record device outcome** in the spec; commit.

---

## Self-Review

- **Spec coverage:** Kit model+defaults+resolve (T1) ✓; persist override map + emit (T2) ✓; fixed-slot gestures+glyphs (T3) ✓; full override editor with None/Literal/Special-key picker (T4) ✓; editor wiring/affordance (T5) ✓; CI+device incl. all spec device checks (T6) ✓; literal-or-key secondary (T1 `SecondaryValue`) ✓; override-wins resolution (T1, tested) ✓; reuse `encodeKey`/back-tab (T2, tested `ESC [ Z`) ✓; separate override map, no layout migration (T2) ✓; symbols+Tab+F-keys scope (defaults T1, gestures T3; F-key *editor* row honestly gated in T5) ✓.
- **Placeholder scan:** the one conditional is T5's F-key-row caveat — it's an explicit "verify the row model, include `.fkey` only if editable rows exist" instruction with a concrete fallback, not a vague TODO. The `Character`-Codable fallback in T1 is likewise explicit. No bare TBDs.
- **Type consistency:** `SecondaryValue`/`SwipeSecondaries`/`FixedKeyID`/`resolveSecondaries(for:overrides:)`/`FixedKeyDefaults.defaults(for:)` defined in T1, used identically in T2–T5; `emitSecondary(_:)` defined T2, used T3; `KeybarSettings.fixedKeySecondaries` defined T2, used T3–T5; `FixedKeySecondaryEditorView(store:id:)` defined T4, used T5.

## Known scope caveat (flag for execution)

T5's F-key editability depends on whether the current keybar editor lists F-keys as editable rows. If it does not, the F-key swipe *defaults + on-bar gesture* (T3) still ship; only the per-F-key *editor* is deferred. The implementer verifies against the real row model and includes `.fkey` in `fixedKeyID(for:)` only if the rows exist — otherwise notes it as a documented follow-up.
