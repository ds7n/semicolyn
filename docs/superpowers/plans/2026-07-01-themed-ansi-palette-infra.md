# Themed Terminal Palette (ANSI-16) Infrastructure — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the terminal's colors theme-driven — add an authored 16-color ANSI palette to `Theme` as the single source of hue, with typed UI-role references into it, and wire a SwiftTerm bridge so switching themes recolors the live terminal.

**Architecture:** New pure types in `SemicolynKit/Theme/` (`ANSISlot`, `ANSIPalette`, `ANSIRoleMap`, a `Theme.fromANSI` factory, a `TerminalPalette` DTO) — all Linux-tested. The two existing themes are migrated through the factory so their exact colors are preserved by regression tests. A thin App-tier bridge (`applyPalette(_:to:)`) maps the DTO onto SwiftTerm's `installColors` + native fg/bg/caret/selection setters at terminal-view creation and on theme change.

**Tech Stack:** Swift 6 (strict concurrency), XCTest, SwiftTerm (`from: "1.0.0"`), Docker dev image `semicolyn-dev`.

## Global Constraints

- **Every source file starts with the SPDX header** — `// SPDX-FileCopyrightText: 2026 True Positive LLC` then `// SPDX-License-Identifier: GPL-3.0-only` (REUSE-compliant).
- **`SemicolynKit` is platform-agnostic + Swift-6 `Sendable`** — NO `import UIKit`/`SwiftUI`/`SwiftTerm`. All new pure types conform to `Equatable, Sendable`.
- **App-tier code (`App/`) is macOS-CI-only** — does NOT compile on Linux, invisible to `swift test`. Verify via the `macos` CI job + Simulator, never locally.
- **Tests are real** (`2026-06-18-testing-standards-design.md`): assert exact hex values / specific inequalities; no "constructed OK" tautologies.
- **Conventional commits**; feature branch `feat/themed-ansi-palette`; squash-merge to `main`.
- **Kit test command:** `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter <Suite>`
- **Derivation contract:** the 16 ANSI colors are the single source of hue. `accent.primary` + `state.success/degraded/broken/warning` are typed references (`ANSISlot`) into the palette. `accent.highlight` is an authored decorative tint (NOT a slot). `bell.edge` and `focus.paneBorder` derive from `accent.primary`.

---

### Task 1: `ANSISlot` + `ANSIPalette`

**Files:**
- Create: `Sources/SemicolynKit/Theme/ANSIPalette.swift`
- Test: `Tests/SemicolynKitTests/ANSIPaletteTests.swift`

**Interfaces:**
- Produces: `enum ANSISlot: Int, CaseIterable, Sendable` (16 cases, `black = 0` … `brightWhite = 15`); `struct ANSIPalette: Equatable, Sendable` with `init(_ colors: [ThemeColor])`, `subscript(_ slot: ANSISlot) -> ThemeColor`, `func ordered() -> [ThemeColor]`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/SemicolynKitTests/ANSIPaletteTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ANSIPaletteTests: XCTestCase {
    /// Build a 16-color palette where each color encodes its own index in the blue channel.
    private func indexPalette() -> ANSIPalette {
        ANSIPalette((0..<16).map { ThemeColor(String(format: "#0000%02X", $0)) })
    }

    func testSlotRawValuesAreSwiftTermIndexOrder() {
        // installColors relies on rawValue == ANSI index.
        XCTAssertEqual(ANSISlot.black.rawValue, 0)
        XCTAssertEqual(ANSISlot.red.rawValue, 1)
        XCTAssertEqual(ANSISlot.green.rawValue, 2)
        XCTAssertEqual(ANSISlot.yellow.rawValue, 3)
        XCTAssertEqual(ANSISlot.blue.rawValue, 4)
        XCTAssertEqual(ANSISlot.magenta.rawValue, 5)
        XCTAssertEqual(ANSISlot.cyan.rawValue, 6)
        XCTAssertEqual(ANSISlot.white.rawValue, 7)
        XCTAssertEqual(ANSISlot.brightBlue.rawValue, 12)
        XCTAssertEqual(ANSISlot.brightWhite.rawValue, 15)
        XCTAssertEqual(ANSISlot.allCases.count, 16)
    }

    func testSubscriptResolvesSlotToAuthoredColor() {
        let p = indexPalette()
        XCTAssertEqual(p[.blue], ThemeColor("#000004"))
        XCTAssertEqual(p[.brightBlue], ThemeColor("#00000C"))
    }

    func testOrderedReturnsSixteenInIndexOrder() {
        let p = indexPalette()
        let ordered = p.ordered()
        XCTAssertEqual(ordered.count, 16)
        XCTAssertEqual(ordered[0], ThemeColor("#000000"))
        XCTAssertEqual(ordered[15], ThemeColor("#00000F"))
        // ordered[i] must equal the slot with rawValue i.
        for slot in ANSISlot.allCases {
            XCTAssertEqual(ordered[slot.rawValue], p[slot])
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ANSIPaletteTests`
Expected: FAIL — `cannot find 'ANSISlot' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/SemicolynKit/Theme/ANSIPalette.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// The 16 ANSI colors in SwiftTerm's `installColors` index order — `rawValue`
/// IS the palette index (0…15), so the enum doubles as the ordering key.
public enum ANSISlot: Int, CaseIterable, Sendable {
    case black = 0, red, green, yellow, blue, magenta, cyan, white
    case brightBlack, brightRed, brightGreen, brightYellow
    case brightBlue, brightMagenta, brightCyan, brightWhite
}

/// A theme's authored 16-color ANSI palette — the single source of hue.
/// UI semantic tokens reference into this; the terminal bridge installs `ordered()`.
public struct ANSIPalette: Equatable, Sendable {
    private let colors: [ThemeColor]

    /// - Parameter colors: exactly 16 colors, indexed by `ANSISlot.rawValue`.
    public init(_ colors: [ThemeColor]) {
        precondition(colors.count == 16, "ANSIPalette requires exactly 16 colors")
        self.colors = colors
    }

    /// Resolves a role's slot to its authored color.
    public subscript(_ slot: ANSISlot) -> ThemeColor { colors[slot.rawValue] }

    /// The 16 colors in index order, ready for `installColors`.
    public func ordered() -> [ThemeColor] { colors }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ANSIPaletteTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Theme/ANSIPalette.swift Tests/SemicolynKitTests/ANSIPaletteTests.swift
git commit -m "feat(theme): ANSISlot enum + ANSIPalette (16-color source of hue)"
```

---

### Task 2: Extend `Theme.Terminal`, add `Theme.ansi`, and the `fromANSI` factory

**Files:**
- Modify: `Sources/SemicolynKit/Theme/Theme.swift` (extend `Terminal`; add `ansi` property + explicit `init`)
- Create: `Sources/SemicolynKit/Theme/ThemeFromANSI.swift` (`ANSIRoleMap` + `Theme.fromANSI`)
- Test: `Tests/SemicolynKitTests/ThemeFromANSITests.swift`

**Interfaces:**
- Consumes: `ANSISlot`, `ANSIPalette` (Task 1).
- Produces: `Theme.Terminal.init(bg:fg:cursor:cursorText:selection:)` (last 3 defaulted); `Theme.ansi: ANSIPalette`; `struct ANSIRoleMap: Equatable, Sendable { accentPrimary, success, degraded, broken, warning: ANSISlot }`; `static func Theme.fromANSI(ansi:roles:highlight:surface:text:terminal:) -> Theme`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/SemicolynKitTests/ThemeFromANSITests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ThemeFromANSITests: XCTestCase {
    private func palette() -> ANSIPalette {
        // Distinct, recognizable colors per slot.
        ANSIPalette([
            ThemeColor("#101010"), // black 0
            ThemeColor("#E5455E"), // red 1  (crimson)
            ThemeColor("#5FB0A2"), // green 2
            ThemeColor("#F5A524"), // yellow 3 (amber)
            ThemeColor("#6E80FF"), // blue 4
            ThemeColor("#B98CFF"), // magenta 5
            ThemeColor("#33C9DC"), // cyan 6
            ThemeColor("#E8ECF5"), // white 7
            ThemeColor("#2A2A2A"), // brightBlack 8
            ThemeColor("#FF6F5E"), // brightRed 9 (coral)
            ThemeColor("#7CF0BE"), // brightGreen 10
            ThemeColor("#FFC860"), // brightYellow 11
            ThemeColor("#9FADFF"), // brightBlue 12
            ThemeColor("#D0B0FF"), // brightMagenta 13
            ThemeColor("#7FE0FF"), // brightCyan 14
            ThemeColor("#FFFFFF"), // brightWhite 15
        ])
    }

    private func makeTheme() -> Theme {
        Theme.fromANSI(
            ansi: palette(),
            roles: ANSIRoleMap(accentPrimary: .brightRed, success: .green,
                               degraded: .yellow, broken: .red, warning: .yellow),
            highlight: ThemeColor("#FFB7A6"),
            surface: .init(bg: ThemeColor("#07090E"), panel: ThemeColor("#0E1118"),
                           panelHigh: ThemeColor("#161A24"), line: ThemeColor("#232A3A")),
            text: .init(primary: ThemeColor("#E8EBF0"), secondary: ThemeColor("#8A93A3"),
                        muted: ThemeColor("#8A93A3"), inverse: ThemeColor("#05070B")),
            terminal: .init(bg: ThemeColor("#05070B"), fg: ThemeColor("#CFD6E4"))
        )
    }

    func testAccentPrimaryResolvesFromSlot() {
        // accent.primary must equal the brightRed slot (coral), NOT a raw literal.
        XCTAssertEqual(makeTheme().accent.primary, ThemeColor("#FF6F5E"))
    }

    func testHighlightIsAuthoredNotDerived() {
        XCTAssertEqual(makeTheme().accent.highlight, ThemeColor("#FFB7A6"))
    }

    func testStateColorsResolveFromSlots() {
        let t = makeTheme()
        XCTAssertEqual(t.state.success, ThemeColor("#5FB0A2")) // green slot
        XCTAssertEqual(t.state.broken, ThemeColor("#E5455E"))  // red slot
        XCTAssertEqual(t.state.warning, ThemeColor("#F5A524")) // yellow slot
    }

    func testAccentAndBrokenAreDistinct() {
        // The coral-vs-crimson separation must survive derivation.
        let t = makeTheme()
        XCTAssertNotEqual(t.accent.primary, t.state.broken)
    }

    func testBellAndFocusDeriveFromAccent() {
        let t = makeTheme()
        XCTAssertEqual(t.bell.edge, t.accent.primary)
        XCTAssertEqual(t.focus.paneBorder, t.accent.primary)
        XCTAssertEqual(t.focus.paneBorderInactive, t.surface.line)
    }

    func testKeybarLadderDerivesFromAccent() {
        let t = makeTheme()
        XCTAssertEqual(t.keybar.slotBgPromoted, ThemeColor("#FF6F5E", opacity: 0.12))
        XCTAssertEqual(t.keybar.slotBgArmed,    ThemeColor("#FF6F5E", opacity: 0.20))
        XCTAssertEqual(t.keybar.slotBgLocked,   ThemeColor("#FF6F5E", opacity: 0.30))
    }

    func testAnsiPaletteIsStored() {
        XCTAssertEqual(makeTheme().ansi[.brightBlue], ThemeColor("#9FADFF"))
    }

    func testTerminalDefaultsForNewFields() {
        // cursor/cursorText/selection default when omitted.
        let term = Theme.Terminal(bg: ThemeColor("#05070B"), fg: ThemeColor("#CFD6E4"))
        XCTAssertEqual(term.cursor, ThemeColor("#CFD6E4"))        // defaults to fg
        XCTAssertEqual(term.cursorText, ThemeColor("#05070B"))   // defaults to bg
        XCTAssertEqual(term.selection, ThemeColor("#CFD6E4", opacity: 0.30)) // fg @ 30%
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ThemeFromANSITests`
Expected: FAIL — `cannot find 'ANSIRoleMap'` / `extra argument 'cursor'`.

- [ ] **Step 3a: Extend `Theme.Terminal` and add `ansi` in `Theme.swift`**

In `Sources/SemicolynKit/Theme/Theme.swift`, replace the `Terminal` struct:

```swift
    public struct Terminal: Equatable, Sendable {
        public let bg, fg, cursor, cursorText, selection: ThemeColor
        /// New fields default so existing `.init(bg:fg:)` call sites keep compiling:
        /// cursor→fg, cursorText→bg, selection→fg @ 30%.
        public init(bg: ThemeColor, fg: ThemeColor,
                    cursor: ThemeColor? = nil, cursorText: ThemeColor? = nil,
                    selection: ThemeColor? = nil) {
            self.bg = bg
            self.fg = fg
            self.cursor = cursor ?? fg
            self.cursorText = cursorText ?? bg
            self.selection = selection ?? fg.alpha(0.30)
        }
    }
```

Add the stored `ansi` property and an explicit `init` on `Theme` (replaces the synthesized memberwise init; `ansi` is trailing-defaulted so existing constructions still compile). After the existing `public let terminal: Terminal` line, add:

```swift
    /// Authored 16-color ANSI palette — source of hue for the terminal + UI refs.
    public let ansi: ANSIPalette

    public init(surface: Surface, text: Text, accent: Accent, state: State,
                bell: Bell, focus: Focus, keybar: Keybar, predictor: Predictor,
                banner: Banner, terminal: Terminal,
                ansi: ANSIPalette = ANSIPalette.neutralFallback) {
        self.surface = surface; self.text = text; self.accent = accent
        self.state = state; self.bell = bell; self.focus = focus
        self.keybar = keybar; self.predictor = predictor; self.banner = banner
        self.terminal = terminal; self.ansi = ansi
    }
```

- [ ] **Step 3b: Add `neutralFallback` to `ANSIPalette.swift`**

Append to `Sources/SemicolynKit/Theme/ANSIPalette.swift`:

```swift
extension ANSIPalette {
    /// A neutral placeholder used only until a theme is migrated to `fromANSI`.
    /// Standard xterm-ish 16; real themes author their own.
    public static let neutralFallback = ANSIPalette([
        "#000000", "#CD0000", "#00CD00", "#CDCD00", "#0000EE", "#CD00CD", "#00CDCD", "#E5E5E5",
        "#7F7F7F", "#FF0000", "#00FF00", "#FFFF00", "#5C5CFF", "#FF00FF", "#00FFFF", "#FFFFFF",
    ].map(ThemeColor.init))
}
```

- [ ] **Step 3c: Create `ThemeFromANSI.swift`**

```swift
// Sources/SemicolynKit/Theme/ThemeFromANSI.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Which ANSI slot feeds each strictly-derived UI semantic role. `accent.highlight`
/// is intentionally absent — it is an authored decorative tint, not a slot.
public struct ANSIRoleMap: Equatable, Sendable {
    public let accentPrimary: ANSISlot
    public let success, degraded, broken, warning: ANSISlot

    public init(accentPrimary: ANSISlot, success: ANSISlot,
                degraded: ANSISlot, broken: ANSISlot, warning: ANSISlot) {
        self.accentPrimary = accentPrimary
        self.success = success
        self.degraded = degraded
        self.broken = broken
        self.warning = warning
    }
}

extension Theme {
    /// Builds a Theme whose accent-primary + state colors are RESOLVED from `ansi`
    /// via `roles` (strict derivation), while `highlight`, surfaces, text, and the
    /// terminal tokens are authored directly. bell/focus/keybar/predictor/banner
    /// are derived here — the single place that logic lives.
    public static func fromANSI(
        ansi: ANSIPalette, roles: ANSIRoleMap, highlight: ThemeColor,
        surface: Surface, text: Text, terminal: Terminal
    ) -> Theme {
        let accent = ansi[roles.accentPrimary]
        let success = ansi[roles.success]
        let degraded = ansi[roles.degraded]
        let broken = ansi[roles.broken]
        let warning = ansi[roles.warning]
        return Theme(
            surface: surface,
            text: text,
            accent: .init(primary: accent, highlight: highlight),
            state: .init(success: success, degraded: degraded, broken: broken, warning: warning),
            bell: .init(edge: accent),
            focus: .init(paneBorder: accent, paneBorderInactive: surface.line),
            keybar: .init(slotBg: surface.panel,
                          slotBgPromoted: accent.alpha(0.12),
                          slotBgArmed: accent.alpha(0.20),
                          slotBgLocked: accent.alpha(0.30)),
            predictor: .init(stripBg: surface.panel, suggestionBg: surface.panelHigh,
                             suggestionText: text.primary),
            banner: .init(amberBg: warning.alpha(0.15), redBg: broken.alpha(0.15),
                          neutralBg: surface.panel),
            terminal: terminal,
            ansi: ansi
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ThemeFromANSITests`
Expected: PASS (8 tests). Also run the full suite to confirm existing themes still compile with the new `Terminal.init` + defaulted `ansi`:
Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ThemeTests`
Expected: PASS (existing 14 unchanged).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Theme/Theme.swift Sources/SemicolynKit/Theme/ANSIPalette.swift Sources/SemicolynKit/Theme/ThemeFromANSI.swift Tests/SemicolynKitTests/ThemeFromANSITests.swift
git commit -m "feat(theme): ANSIRoleMap + Theme.fromANSI factory + terminal cursor/selection tokens"
```

---

### Task 3: `TerminalPalette` DTO + `Theme.terminalPalette()`

**Files:**
- Create: `Sources/SemicolynKit/Theme/TerminalPalette.swift`
- Test: `Tests/SemicolynKitTests/TerminalPaletteTests.swift`

**Interfaces:**
- Consumes: `Theme`, `ANSIPalette` (Tasks 1–2).
- Produces: `struct TerminalPalette: Equatable, Sendable { fg, bg, cursor, cursorText, selection: ThemeColor; ansi16: [ThemeColor] }`; `func Theme.terminalPalette() -> TerminalPalette`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/SemicolynKitTests/TerminalPaletteTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class TerminalPaletteTests: XCTestCase {
    func testBundlesTerminalTokensAndSixteenAnsi() {
        let p = Theme.neonMidnight.terminalPalette()
        XCTAssertEqual(p.bg, Theme.neonMidnight.terminal.bg)
        XCTAssertEqual(p.fg, Theme.neonMidnight.terminal.fg)
        XCTAssertEqual(p.cursor, Theme.neonMidnight.terminal.cursor)
        XCTAssertEqual(p.cursorText, Theme.neonMidnight.terminal.cursorText)
        XCTAssertEqual(p.selection, Theme.neonMidnight.terminal.selection)
        XCTAssertEqual(p.ansi16.count, 16)
        XCTAssertEqual(p.ansi16, Theme.neonMidnight.ansi.ordered())
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TerminalPaletteTests`
Expected: FAIL — `value of type 'Theme' has no member 'terminalPalette'`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/SemicolynKit/Theme/TerminalPalette.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Flat, platform-agnostic bundle of everything the terminal view is colored by.
/// The App bridge consumes this without touching `Theme` internals.
public struct TerminalPalette: Equatable, Sendable {
    public let fg, bg, cursor, cursorText, selection: ThemeColor
    public let ansi16: [ThemeColor]

    public init(fg: ThemeColor, bg: ThemeColor, cursor: ThemeColor,
                cursorText: ThemeColor, selection: ThemeColor, ansi16: [ThemeColor]) {
        self.fg = fg; self.bg = bg; self.cursor = cursor
        self.cursorText = cursorText; self.selection = selection; self.ansi16 = ansi16
    }
}

extension Theme {
    /// The terminal-facing view of this theme: fg/bg/cursor/cursorText/selection
    /// plus the ordered 16 ANSI colors.
    public func terminalPalette() -> TerminalPalette {
        TerminalPalette(fg: terminal.fg, bg: terminal.bg, cursor: terminal.cursor,
                        cursorText: terminal.cursorText, selection: terminal.selection,
                        ansi16: ansi.ordered())
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter TerminalPaletteTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Theme/TerminalPalette.swift Tests/SemicolynKitTests/TerminalPaletteTests.swift
git commit -m "feat(theme): TerminalPalette DTO + Theme.terminalPalette()"
```

---

### Task 4: Migrate Neon Midnight to `fromANSI` (author its 16 + role map)

**Files:**
- Modify: `Sources/SemicolynKit/Theme/NeonMidnightTheme.swift`
- Test: `Tests/SemicolynKitTests/ThemeTests.swift` (add ANSI assertions; existing ones are the regression guard)

**Interfaces:**
- Consumes: `Theme.fromANSI`, `ANSIPalette`, `ANSIRoleMap` (Tasks 1–3).
- Produces: `Theme.neonMidnight` unchanged in its public token values, now ANSI-backed.

- [ ] **Step 1: Write the failing test**

Append to `Tests/SemicolynKitTests/ThemeTests.swift`:

```swift
    func testNeonMidnightAnsiCoralAndCrimsonSlots() {
        // accent(coral) lives in brightRed; error(crimson) in red — kept distinct.
        XCTAssertEqual(Theme.neonMidnight.ansi[.brightRed], ThemeColor("#FF6F5E"))
        XCTAssertEqual(Theme.neonMidnight.ansi[.red], ThemeColor("#E5455E"))
    }

    func testNeonMidnightAnsiHasSixteen() {
        XCTAssertEqual(Theme.neonMidnight.ansi.ordered().count, 16)
    }

    func testNeonMidnightTerminalCursorIsAccent() {
        XCTAssertEqual(Theme.neonMidnight.terminal.cursor, ThemeColor("#FF6F5E"))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ThemeTests`
Expected: FAIL — `testNeonMidnightAnsiCoralAndCrimsonSlots` fails (fallback ANSI has different values).

- [ ] **Step 3: Rewrite `NeonMidnightTheme.swift` via `fromANSI`**

Replace the file body (keep the SPDX header + palette-story comment):

```swift
// Palette constants unchanged; the 16 ANSI colors are designed to sit on the
// midnight night. accent=coral lives in brightRed, error=crimson in red.
private let coral500      = ThemeColor("#FF6F5E")
private let coral300      = ThemeColor("#FFB7A6")
private let crimson500    = ThemeColor("#E5455E")
private let patina500     = ThemeColor("#5FB0A2")
private let amber500      = ThemeColor("#F5A524")
private let night0        = ThemeColor("#07090E")
private let nightPanel    = ThemeColor("#0E1118")
private let nightPanelHi  = ThemeColor("#161A24")
private let nightLine     = ThemeColor("#232A3A")
private let nightTerm     = ThemeColor("#05070B")
private let textPrimary   = ThemeColor("#E8EBF0")
private let textMuted     = ThemeColor("#8A93A3")
private let termFg        = ThemeColor("#CFD6E4")

// 16 ANSI colors for the night. Semantic slots carry the existing hues so
// derivation reproduces the shipped accent/state exactly; blue/magenta/cyan
// are cool neons tuned for the dark base; brights are lifted variants.
private let neonMidnightANSI = ANSIPalette([
    ThemeColor("#0B0E14"), // black
    crimson500,            // red    (error / crimson)
    patina500,             // green  (verdigris)
    amber500,              // yellow (amber)
    ThemeColor("#5B8CFF"), // blue
    ThemeColor("#B98CFF"), // magenta
    ThemeColor("#4FC7D6"), // cyan
    ThemeColor("#C9D1E0"), // white
    ThemeColor("#2A3346"), // brightBlack
    coral500,              // brightRed  (accent / coral)
    ThemeColor("#7CE0C4"), // brightGreen
    ThemeColor("#FFC860"), // brightYellow
    ThemeColor("#8AA6FF"), // brightBlue
    ThemeColor("#D0B0FF"), // brightMagenta
    ThemeColor("#86ECF7"), // brightCyan
    ThemeColor("#F2F5FA"), // brightWhite
])

extension Theme {
    public static let neonMidnight = Theme.fromANSI(
        ansi: neonMidnightANSI,
        roles: ANSIRoleMap(accentPrimary: .brightRed, success: .green,
                           degraded: .yellow, broken: .red, warning: .yellow),
        highlight: coral300,
        surface: .init(bg: night0, panel: nightPanel, panelHigh: nightPanelHi, line: nightLine),
        text: .init(primary: textPrimary, secondary: textMuted, muted: textMuted, inverse: nightTerm),
        terminal: .init(bg: nightTerm, fg: termFg,
                        cursor: coral500, cursorText: nightTerm, selection: coral500.alpha(0.30))
    )
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ThemeTests`
Expected: PASS — the pre-existing Neon Midnight assertions (accent coral, broken crimson-distinct, success verdigris, keybar ladder, surfaces) still hold AND the 3 new ANSI assertions pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Theme/NeonMidnightTheme.swift Tests/SemicolynKitTests/ThemeTests.swift
git commit -m "refactor(theme): back Neon Midnight with an authored ANSI-16 palette"
```

---

### Task 5: Migrate Bell Bronze to `fromANSI`

**Files:**
- Modify: `Sources/SemicolynKit/Theme/BellBronzeTheme.swift`
- Test: `Tests/SemicolynKitTests/ThemeTests.swift`

**Interfaces:**
- Consumes: `Theme.fromANSI` (Task 2). `Theme.all` (defined at bottom of this file) is unchanged.
- Produces: `Theme.bellBronze` ANSI-backed; public token values unchanged.

- [ ] **Step 1: Write the failing test**

Append to `Tests/SemicolynKitTests/ThemeTests.swift`:

```swift
    func testBellBronzeAnsiYellowIsBronze() {
        // Bronze is the theme's warm hue → occupies the yellow slot; accent refs it.
        XCTAssertEqual(Theme.bellBronze.ansi[.yellow], ThemeColor("#D49A5C"))
        XCTAssertEqual(Theme.bellBronze.accent.primary, ThemeColor("#D49A5C"))
    }

    func testBellBronzeAnsiHasSixteen() {
        XCTAssertEqual(Theme.bellBronze.ansi.ordered().count, 16)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test --filter ThemeTests`
Expected: FAIL — `testBellBronzeAnsiYellowIsBronze` (fallback ANSI yellow ≠ bronze).

- [ ] **Step 3: Rewrite `BellBronzeTheme.swift` via `fromANSI`**

Keep the SPDX header and the `Theme.all` definition at the bottom. Replace the palette + `bellBronze` construction:

```swift
private let bronze500       = ThemeColor("#D49A5C")
private let bronze300       = ThemeColor("#F2C58A")
private let coolDarkAnchor  = ThemeColor("#0E1116")
private let coolDarkPanel   = ThemeColor("#161A22")
private let coolDarkPanelHi = ThemeColor("#1F2530")
private let coolDarkLine    = ThemeColor("#2A323F")
private let patina500       = ThemeColor("#5FA89C")
private let amber500        = ThemeColor("#F5A524")
private let red500          = ThemeColor("#E06B6B")
private let textPrimary     = ThemeColor("#E8EBF0")
private let textMuted       = ThemeColor("#8A93A3")

// Bronze is the warm accent → yellow slot = bronze. degraded/warning use a
// separate amber slot (brightYellow) so bronze-accent and amber-warning stay
// visibly distinct, matching the shipped theme.
private let bellBronzeANSI = ANSIPalette([
    ThemeColor("#0A0C10"), // black
    red500,                // red    (error)
    patina500,             // green
    bronze500,             // yellow (bronze / accent)
    ThemeColor("#5E86C7"), // blue
    ThemeColor("#A98BC7"), // magenta
    ThemeColor("#5FA8B5"), // cyan
    ThemeColor("#C9D1DE"), // white
    ThemeColor("#2A323F"), // brightBlack
    ThemeColor("#F08A8A"), // brightRed
    ThemeColor("#7FC4B7"), // brightGreen
    amber500,              // brightYellow (amber / warning)
    ThemeColor("#8AAAE0"), // brightBlue
    ThemeColor("#C8ADE0"), // brightMagenta
    ThemeColor("#8FCDD9"), // brightCyan
    ThemeColor("#F2F5FA"), // brightWhite
])

extension Theme {
    public static let bellBronze = Theme.fromANSI(
        ansi: bellBronzeANSI,
        roles: ANSIRoleMap(accentPrimary: .yellow, success: .green,
                           degraded: .brightYellow, broken: .red, warning: .brightYellow),
        highlight: bronze300,
        surface: .init(bg: coolDarkAnchor, panel: coolDarkPanel,
                       panelHigh: coolDarkPanelHi, line: coolDarkLine),
        text: .init(primary: textPrimary, secondary: textMuted, muted: textMuted, inverse: coolDarkAnchor),
        terminal: .init(bg: ThemeColor("#0A0C10"), fg: ThemeColor("#CFD6E4"),
                        cursor: bronze500, cursorText: ThemeColor("#0A0C10"),
                        selection: bronze500.alpha(0.30))
    )

    // Neon Midnight is the default (first); Bell-bronze retained as a switchable
    // alternate (candidate Pro cosmetic).
    public static let all: [Theme] = catalog.map(\.theme)
}
```

**Note:** the shipped Bell Bronze had `degraded == warning == amber500 (#F5A524)`. The role map maps both `degraded` and `warning` to `.brightYellow` (= `amber500`), preserving that equality. `testAlphaProducesOpacityVariant` (keybar promoted = bronze @ 12%) still holds because keybar derives from `accent.primary` = bronze.

- [ ] **Step 4: Run test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev swift test`
Expected: PASS — full suite green (all ThemeTests incl. the bronze accent, keybar-promoted-alpha, registry-count, plus the 2 new ANSI assertions).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Theme/BellBronzeTheme.swift Tests/SemicolynKitTests/ThemeTests.swift
git commit -m "refactor(theme): back Bell Bronze with an authored ANSI-16 palette"
```

---

### Task 6: App bridge — `applyPalette(_:to:)` + `TerminalScreen` hooks

**Files:**
- Create: `App/TerminalPaletteBridge.swift`
- Modify: `App/TerminalScreen.swift` (call the bridge in `makeUIView` + `updateUIView`)

> **App-tier — macOS-CI only.** No Linux test. Verify via the `macos` CI job compile + Simulator visual check.

**Interfaces:**
- Consumes: `TerminalPalette`, `Theme.terminalPalette()` (Task 3); SwiftTerm `TerminalView`.
- Produces: `func applyPalette(_ palette: TerminalPalette, to view: TerminalView)`; `extension SwiftTerm.Color { convenience init(themeColor:) }`.

- [ ] **Step 1: Create the bridge**

```swift
// App/TerminalPaletteBridge.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SwiftTerm
import SemicolynKit

extension SwiftTerm.Color {
    /// Bridges a `ThemeColor` to a SwiftTerm 16-bit-channel `Color`.
    /// Reuses the unit-tested `rgba()` parser; opacity is dropped (opaque terminal).
    convenience init(themeColor: ThemeColor) {
        let c = themeColor.rgba()
        self.init(red: UInt16(c.red * 65535),
                  green: UInt16(c.green * 65535),
                  blue: UInt16(c.blue * 65535))
    }
}

/// Applies a theme's terminal palette to a live SwiftTerm view: installs the 16
/// ANSI colors and sets fg/bg/cursor/cursor-text/selection. Called at view
/// creation and whenever the observed theme changes.
func applyPalette(_ palette: TerminalPalette, to view: TerminalView) {
    view.installColors(palette.ansi16.map { SwiftTerm.Color(themeColor: $0) })
    view.nativeForegroundColor = UIColor(Color(palette.fg))
    view.nativeBackgroundColor = UIColor(Color(palette.bg))
    view.caretColor = UIColor(Color(palette.cursor))
    view.caretTextColor = UIColor(Color(palette.cursorText))
    view.selectedTextBackgroundColor = UIColor(Color(palette.selection))
}
```

- [ ] **Step 2: Hook `TerminalScreen.makeUIView`**

In `App/TerminalScreen.swift`, inside `makeUIView`, immediately after `terminal.getTerminal().options.scrollback = s.scrollbackLines` (line ~44), add:

```swift
        // Apply the theme's terminal palette (bg/fg/cursor/selection + 16 ANSI).
        applyPalette(theme.terminalPalette(), to: terminal)
```

- [ ] **Step 3: Hook `TerminalScreen.updateUIView`**

In `updateUIView`, after the halo `configure` line (line ~81), add:

```swift
        // Recolor the live terminal when the theme changes.
        applyPalette(theme.terminalPalette(), to: uiView)
```

- [ ] **Step 4: Verify (macOS CI)**

Run: `git push` the branch and confirm the **`macos`** CI job compiles (`~15–18 min`). There is no Linux test for App code.
Expected: `macos` job green.

- [ ] **Step 5: Commit**

```bash
git add App/TerminalPaletteBridge.swift App/TerminalScreen.swift
git commit -m "feat(terminal): apply theme ANSI palette + fg/bg/cursor to SwiftTerm (TerminalScreen)"
```

---

### Task 7: App bridge — `TmuxPaneContainer` hook

**Files:**
- Modify: `App/TmuxPaneContainer.swift` (apply palette where each pane `TerminalView` is created, ~line 388; re-apply on theme change)

> **App-tier — macOS-CI only.**

**Interfaces:**
- Consumes: `applyPalette(_:to:)` (Task 6); the container's `theme` (thread it in if not already present).

- [ ] **Step 1: Confirm theme availability in the container**

Run: `rg -n "var theme|Theme" App/TmuxPaneContainer.swift`
Expected: a `theme` property exists (mirrors `TerminalScreen`). If absent, add `var theme: Theme = .neonMidnight` to the representable and pass it from the call site (same pattern as `TerminalScreen`).

- [ ] **Step 2: Apply palette at pane creation**

In `App/TmuxPaneContainer.swift`, immediately after `let t = TerminalView(frame: .zero)` (~line 388), add:

```swift
                    applyPalette(theme.terminalPalette(), to: t)
```

- [ ] **Step 3: Re-apply on theme change in `updateUIView`**

In `updateUIView` (~line 49), iterate the container's live pane terminal views and re-apply:

```swift
        // Recolor every live pane when the theme changes.
        for pane in uiView.paneTerminalViews {   // existing accessor for the pane's TerminalViews
            applyPalette(theme.terminalPalette(), to: pane)
        }
```

If no such accessor exists, add a computed `var paneTerminalViews: [TerminalView]` on `ContainerView` returning its current pane views (the container already tracks them for layout).

- [ ] **Step 4: Verify (macOS CI)**

Run: push; confirm the **`macos`** CI job is green.
Expected: compiles; in Simulator, splitting a tmux pane shows themed colors, and switching themes recolors all panes.

- [ ] **Step 5: Commit**

```bash
git add App/TmuxPaneContainer.swift
git commit -m "feat(terminal): apply theme ANSI palette to tmux panes"
```

---

## Self-Review

**Spec coverage:**
- ANSI-16 struct + `ANSISlot` index order → Task 1 ✓
- `ANSIRoleMap` typed derivation + `fromANSI` + extended `Terminal` (cursor/cursorText/selection) → Task 2 ✓
- Pure `TerminalPalette` DTO → Task 3 ✓
- Backfill Neon Midnight + Bell Bronze → Tasks 4, 5 ✓ (regression via existing exact-hex assertions)
- App SwiftTerm bridge (`installColors` + native fg/bg/caret/selection), hooked at creation + theme-change → Tasks 6, 7 ✓
- Testing per standards: exact-hex + specific-inequality (coral≠crimson) assertions, no tautologies → Tasks 2, 4 ✓
- Out of scope (new themes, import, 256-color) → not planned, correct ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code; test bodies are concrete. ✓

**Type consistency:** `ANSISlot` cases/rawValues, `ANSIPalette` (`subscript`/`ordered`), `ANSIRoleMap` fields (`accentPrimary/success/degraded/broken/warning`), `Theme.fromANSI(ansi:roles:highlight:surface:text:terminal:)`, `TerminalPalette` fields, and `applyPalette(_:to:)` / `SwiftTerm.Color(themeColor:)` are named identically across all tasks. `highlight` is authored (not in `ANSIRoleMap`) consistently in Tasks 2/4/5. ✓

**Known deviation from spec:** spec §Architecture mentioned storing `roles` on `Theme` for import round-trip; deferred (YAGNI — import is Piece 3). Only `ansi` is stored, which is all the bridge needs. Strict derivation is still enforced because `fromANSI` requires slots.
