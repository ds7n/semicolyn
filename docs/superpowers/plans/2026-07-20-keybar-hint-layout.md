<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Keybar Hint Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the keybar's edge-pinned swipe-hint glyphs with a main-glyph-left + stacked-secondaries-right layout, in the theme accent, with uniform slot width and a tighter bar (device issue #2).

**Architecture:** A pure Kit projection (`hintGlyphs(for:)`) computes the up/down hint strings for a `SwipeSecondaries`, unit-tested on Linux. The App-tier `SlotChrome` gains an optional stacked-secondary column (up over down, accent-tinted, main centered via a spacer); `fixedKeySwipes` drops its `.overlay` glyphs but keeps the swipe gesture. Slot width is unified and the bar padding trimmed.

**Tech Stack:** Swift 6 (SemicolynKit, Linux XCTest), Swift 5 App tier (SwiftUI, macOS-CI-only).

## Global Constraints

- SPDX header on every source file: `// SPDX-FileCopyrightText: 2026 True Positive LLC` then `// SPDX-License-Identifier: GPL-3.0-only`.
- Kit code (`Sources/SemicolynKit/`): Swift 6 strict-concurrency, `Sendable`, `import Foundation` only, NO UIKit/SwiftUI.
- Kit tests run ONLY in the `semicolyn-dev` Docker container: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <Suite>`. Docker needs `dangerouslyDisableSandbox: true` on the Bash call.
- App-tier (`App/`) does NOT compile on Linux; validated by the macOS CI job only.
- Hint color is `theme.accent.primary` (verified real; the accent is top-level `theme.accent`, NOT `theme.keybar` which only has slot backgrounds). Never hardcode a color.
- Swipe GESTURE behavior is unchanged: only the hint RENDERING and slot sizing/height change.
- Stage files EXPLICITLY by path (never `git add -A` — `extern/` submodules must stay untracked).
- Conventional commits. No em-dashes anywhere.

---

### Task 1: Kit hint-glyph projection

**Files:**
- Create: `Sources/SemicolynKit/Keybar/HintGlyphs.swift`
- Test: `Tests/SemicolynKitTests/HintGlyphsTests.swift`

**Interfaces:**
- Consumes: `SecondaryValue` (`.literal(String)` / `.key(KeyInput, KeyModifiers)`), `SwipeSecondaries { up: SecondaryValue?; down: SecondaryValue? }`, `KeyInput` (`.tab/.escape/.enter/.backspace/.arrow(ArrowDirection)/.function(Int)/.char(Character)`) — all existing in `Sources/SemicolynKit/Keybar/`.
- Produces:
  - `hintGlyph(for v: SecondaryValue) -> String`
  - `hintGlyphs(for s: SwipeSecondaries) -> (up: String?, down: String?)`

- [ ] **Step 1: Write the failing tests**

Create `Tests/SemicolynKitTests/HintGlyphsTests.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class HintGlyphsTests: XCTestCase {

    // MARK: hintGlyph(for:) per secondary kind (EP, exact glyph strings)

    func testLiteralGlyphIsTheLiteral() {
        XCTAssertEqual(hintGlyph(for: .literal("\\")), "\\")
        XCTAssertEqual(hintGlyph(for: .literal("_")), "_")
        XCTAssertEqual(hintGlyph(for: .literal("&")), "&")
    }
    func testPlainTabGlyph() {
        XCTAssertEqual(hintGlyph(for: .key(.tab, KeyModifiers())), "⇥")
    }
    func testShiftTabGlyph() {
        XCTAssertEqual(hintGlyph(for: .key(.tab, KeyModifiers(shift: true))), "⇤")
    }
    func testEscapeGlyph() {
        XCTAssertEqual(hintGlyph(for: .key(.escape, KeyModifiers())), "⎋")
    }
    func testArrowGlyphs() {
        XCTAssertEqual(hintGlyph(for: .key(.arrow(.up), KeyModifiers())), "↑")
        XCTAssertEqual(hintGlyph(for: .key(.arrow(.down), KeyModifiers())), "↓")
        XCTAssertEqual(hintGlyph(for: .key(.arrow(.left), KeyModifiers())), "←")
        XCTAssertEqual(hintGlyph(for: .key(.arrow(.right), KeyModifiers())), "→")
    }
    func testFunctionKeyGlyph() {
        XCTAssertEqual(hintGlyph(for: .key(.function(5), KeyModifiers())), "F5")
    }
    func testCharGlyph() {
        XCTAssertEqual(hintGlyph(for: .key(.char("x"), KeyModifiers())), "x")
    }

    // MARK: hintGlyphs(for:) projection onto (up, down)

    func testBothPresentStacks() {
        // The | key example: up "(" over down ")".
        let s = SwipeSecondaries(up: .literal("("), down: .literal(")"))
        let g = hintGlyphs(for: s)
        XCTAssertEqual(g.up, "(")
        XCTAssertEqual(g.down, ")")
    }
    func testUpOnly() {
        // The common case: "/" -> up "\", no down.
        let g = hintGlyphs(for: SwipeSecondaries(up: .literal("\\")))
        XCTAssertEqual(g.up, "\\")
        XCTAssertNil(g.down)
    }
    func testDownOnly() {
        let g = hintGlyphs(for: SwipeSecondaries(down: .literal(";")))
        XCTAssertNil(g.up)
        XCTAssertEqual(g.down, ";")
    }
    func testNeither() {
        let g = hintGlyphs(for: SwipeSecondaries())
        XCTAssertNil(g.up)
        XCTAssertNil(g.down)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter HintGlyphsTests` (Docker: `dangerouslyDisableSandbox: true`)
Expected: FAIL to compile — "cannot find 'hintGlyph' in scope" / "cannot find 'hintGlyphs' in scope".

- [ ] **Step 3: Write the implementation**

Create `Sources/SemicolynKit/Keybar/HintGlyphs.swift`. Port the glyph mapping from the App's
existing `fixedKeyGlyphLabel` (`App/Keybar/KeybarSlotViews.swift:74-90`) into Kit:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// The display glyph for a swipe secondary: a literal renders as itself; a key
/// renders as its symbol (tab -> ⇥, shift-tab -> ⇤, escape -> ⎋, enter -> ⏎,
/// backspace -> ⌫, arrows -> ↑↓←→, Fn -> "F<n>", char -> the char). Pure so the
/// keybar's hint labels are unit-tested on Linux, not only visually on device.
public func hintGlyph(for v: SecondaryValue) -> String {
    switch v {
    case .literal(let s): return s
    case .key(let input, let mods):
        switch input {
        case .tab:       return mods.shift ? "⇤" : "⇥"
        case .escape:    return "⎋"
        case .enter:     return "⏎"
        case .backspace: return "⌫"
        case .arrow(let d):
            switch d { case .up: return "↑"; case .down: return "↓"
                       case .left: return "←"; case .right: return "→" }
        case .function(let n): return "F\(n)"
        case .char(let c):     return String(c)
        }
    }
}

/// The up/down hint glyphs for a key, each nil when that direction is unbound.
/// A pure projection of `SwipeSecondaries` onto (up, down) display strings, so the
/// slot view can render the stacked hint column (up over down) without logic.
public func hintGlyphs(for s: SwipeSecondaries) -> (up: String?, down: String?) {
    (up: s.up.map(hintGlyph(for:)), down: s.down.map(hintGlyph(for:)))
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter HintGlyphsTests` (Docker: `dangerouslyDisableSandbox: true`)
Expected: PASS, 12 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Keybar/HintGlyphs.swift Tests/SemicolynKitTests/HintGlyphsTests.swift
git commit -m "feat(keybar): pure Kit hint-glyph projection (hintGlyph + hintGlyphs)"
```

---

### Task 2: `SlotChrome` renders the stacked-secondary column; `fixedKeySwipes` drops overlays

**Files:**
- Modify: `App/Keybar/KeybarSlotViews.swift` (`SlotChrome`, `fixedKeySwipes`, `fixedKeyGlyphLabel`, and the slot views that pass secondaries)

**Interfaces:**
- Consumes: `hintGlyphs(for:)` (Task 1); `theme.accent.primary`; existing `SwipeSecondaries`, `resolveSecondaries(for:overrides:)`, `SecondaryValue`.
- Produces: a `SlotChrome` that accepts optional up/down hint strings and renders them as a stacked accent column right of the label; slot views feed it their resolved secondaries.

> **Note:** App-tier — does NOT compile on Linux, invisible to `swift test`. Validated by the macOS CI job (I trigger it) + device retest. No local red/green.

- [ ] **Step 1: Rework `SlotChrome` to take optional hints and render the column**

Replace `SlotChrome` (`App/Keybar/KeybarSlotViews.swift:6-17`) with a version that accepts
optional `(up: String?, down: String?)` and renders `HStack { label ; hintColumn }`. Full code:

```swift
/// Shared slot chrome: themed background + label, uniform min size. When a slot has
/// swipe secondaries, they render as a small accent-tinted column to the RIGHT of the
/// label: swipe-up glyph on top, swipe-down below. A single-direction key fills only its
/// slot; the other is an invisible spacer so the main label stays vertically centered
/// (device issue #2: replaces the old edge-pinned overlay glyphs).
private struct SlotChrome<Label: View>: View {
    let bg: Color
    var up: String? = nil
    var down: String? = nil
    @Environment(\.theme) private var theme
    @ViewBuilder var label: () -> Label

    private var hasHints: Bool { up != nil || down != nil }

    var body: some View {
        HStack(spacing: 3) {
            label()
            if hasHints {
                VStack(spacing: 0) {
                    hintText(up)
                    hintText(down)
                }
            }
        }
        .frame(minWidth: 40, minHeight: 34)   // uniform width (device #2); tune on device
        .padding(.horizontal, 6)
        .background(bg)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// One hint glyph, or an invisible spacer of the same metrics when the direction is
    /// unbound (keeps the main label centered and both single-swipe directions aligned).
    @ViewBuilder private func hintText(_ s: String?) -> some View {
        Text(s ?? " ")
            .font(.system(size: 8, design: .monospaced))
            .foregroundStyle(Color(theme.accent.primary))
            .opacity(s == nil ? 0 : 0.85)
    }
}
```

- [ ] **Step 2: Point `fixedKeySwipes` at the column, drop the overlays, keep the gesture**

Replace `fixedKeySwipes` (`App/Keybar/KeybarSlotViews.swift:56-71`). The hint glyphs now come
from `SlotChrome`, so this modifier only carries the gesture. But `SlotChrome` needs the hint
strings, which the slot views already have. The cleanest shape: have the slot views pass
`up:`/`down:` INTO `SlotChrome` directly (Step 3), and reduce `fixedKeySwipes` to gesture-only:

```swift
extension View {
    /// The swipe-up / swipe-down gesture that emits a fixed key's secondaries. The hint
    /// GLYPHS are rendered by SlotChrome's column (fed hintGlyphs(for:)); this modifier is
    /// now gesture-only (device #2 removed the edge-pinned overlay glyphs).
    func fixedKeySwipes(_ secondaries: SwipeSecondaries,
                        emit: @escaping (SecondaryValue) -> Void) -> some View {
        self.gesture(DragGesture(minimumDistance: 12).onEnded { g in
            if g.translation.height < -12, let up = secondaries.up { emit(up) }
            else if g.translation.height > 12, let down = secondaries.down { emit(down) }
        })
    }
}
```

Delete the now-unused App-tier `fixedKeyGlyphLabel` (`KeybarSlotViews.swift:74-90`) — its logic
moved to Kit `hintGlyph` in Task 1. (If any other caller remains, replace it with `hintGlyph`.)

- [ ] **Step 3: Feed secondaries into `SlotChrome` from `SymbolSlotView` and `TabSlotView`**

In `SymbolSlotView` (`KeybarSlotViews.swift:20-35`) and `TabSlotView` (`:38-52`), compute the
resolved secondaries once, pass their glyphs to `SlotChrome(up:down:)`, and keep the
`.fixedKeySwipes(...)` gesture. Example for `SymbolSlotView`:

```swift
struct SymbolSlotView: View {
    let symbol: String
    let vm: ConnectionViewModel
    let keybarSettings: KeybarSettingsStore
    @Environment(\.theme) private var theme
    var body: some View {
        let secondaries = resolveSecondaries(for: .symbol(symbol),
                                             overrides: keybarSettings.settings.fixedKeySecondaries)
        let g = hintGlyphs(for: secondaries)
        SlotChrome(bg: Color(theme.keybar.slotBg), up: g.up, down: g.down) {
            Text(symbol).font(.system(.body, design: .monospaced)).foregroundStyle(Color(theme.text.primary))
        }
        .onInputClickTap { if let c = symbol.first { vm.keybar.tapSymbol(c) } }
        .fixedKeySwipes(secondaries) { v in vm.keybar.emitSecondary(v) }
    }
}
```

Apply the same pattern to `TabSlotView` (resolve `.tab`, pass `up:/down:`, keep tap + swipes).
Any other slot view that used `.fixedKeySwipes` gets the same treatment. Slots WITHOUT
secondaries call `SlotChrome(bg:)` unchanged (up/down default nil -> no column).

- [ ] **Step 4: Trim the bar height**

In `KeybarView.barChrome` (`App/Keybar/KeybarView.swift:54-59`), change `.padding(.vertical, 5)`
to `.padding(.vertical, 3)` (tighter bar; tune on device). No other change.

- [ ] **Step 5: Push + validate on macOS CI**

No local build for App-tier. Commit, push, watch the macos job.

```bash
git add App/Keybar/KeybarSlotViews.swift App/Keybar/KeybarView.swift
git commit -m "feat(keybar): stacked accent hint column + uniform width + tighter bar (issue #2)"
git push github feat/finger-drag-window-transition
```

Watch: `gh run list --repo ds7n/semicolyn --branch feat/finger-drag-window-transition --limit 1`
Expected: the `macos` job passes.

- [ ] **Step 6: Gate TestFlight on macOS-green, then device-verify**

Once macos is green, trigger TestFlight and device-verify:
- The `|` key shows `(` over `)` in accent color to the right of `|`.
- Single-swipe keys (`/`->`\`, `-`->`_`, `⇥`->`⇤`) show one top glyph; the main glyph stays centered.
- Slot widths are uniform; the bar reads tighter; no edge-pinned floating glyphs.
- Swiping up/down on a key still emits the right secondary (gesture unchanged).

```bash
gh workflow run "Release to TestFlight" --repo ds7n/semicolyn --ref feat/finger-drag-window-transition
```

---

## Self-Review

**Spec coverage:**
- Kit hint-glyph projection (`hintGlyph` + `hintGlyphs`), Linux-tested -> Task 1. ✓
- Stacked column (up-top/down-bottom, accent, spacer keeps main centered) -> Task 2 Step 1. ✓
- Drop `.overlay` edge glyphs, keep swipe gesture -> Task 2 Step 2. ✓
- Feed secondaries from the slot views -> Task 2 Step 3. ✓
- Uniform slot width -> Task 2 Step 1 (`minWidth: 40`). ✓
- Tight bar height -> Task 2 Step 4. ✓
- Accent color `theme.accent.primary` (not a hardcode) -> Task 2 Step 1. ✓
- Device verification of the | ( ) example + single-swipe centering -> Task 2 Step 6. ✓
- Non-goal (gesture behavior unchanged) -> gesture code preserved verbatim in Task 2 Step 2. ✓

**Placeholder scan:** `minWidth: 40` / `.vertical, 3` are explicit tune-on-device starting values (spec-sanctioned), not lazy TODOs. All code shown in full. ✓

**Type consistency:** `hintGlyph(for: SecondaryValue) -> String` and `hintGlyphs(for: SwipeSecondaries) -> (up: String?, down: String?)` (Task 1) are consumed with those exact signatures in Task 2. `SlotChrome(bg:up:down:)` matches its call sites. `resolveSecondaries(for:overrides:)` unchanged. ✓
