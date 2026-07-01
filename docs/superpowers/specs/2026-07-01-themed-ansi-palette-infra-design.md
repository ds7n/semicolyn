# Themed terminal palette (ANSI-16) — infrastructure design

**Date:** 2026-07-01
**Status:** Designed (pending implementation plan)
**Type:** Token-structure + integration design. **Introduces new `Theme` token *structure*** (an authored 16-color ANSI palette as the single source of hue, typed UI-role references into it, and expanded terminal tokens) **and** the App-tier SwiftTerm bridge that finally applies theme colors to the live terminal. This is **Piece 1 of 3**; it unblocks — but does not include — the two new blue themes (Piece 2) and third-party theme import (Piece 3).

## Context — why

Two new blue-oriented themes were brainstormed (2026-07-01): a hand-tuned **Neon Cobalt** (accent `#6E80FF`) and an even-spaced, blue-anchored theme. During brainstorming the color-count question ("why 5 hues?") surfaced the real answer: **a color only matters if a role consumes it**, and today the `Theme` token set has only ~5 hue-bearing UI roles. The natural "more colors" answer is the **ANSI-16 terminal palette** (the R/Y/G/B/M/C 60° wheel), which is *also* what standard terminal color schemes (iTerm2 `.itermcolors`, base16, Alacritty/Windows-Terminal JSON) are made of.

Verifying SwiftTerm (pinned `from: "1.0.0"`, `project.yml`) confirmed the primitives exist:

- `TerminalView.installColors(_ colors: [Color])` applies the 16 ANSI colors live (`Apple/AppleTerminalView.swift:411`); `Terminal.installPalette(colors:)` requires exactly 16 (`Terminal.swift:706`).
- `nativeForegroundColor`, `nativeBackgroundColor`, `caretColor` (cursor), `caretTextColor` (glyph under cursor), `selectedTextBackgroundColor` (selection) are all independently settable (`iOS/iOSTerminalView.swift:1230–1290`).
- `Color(red:green:blue:)` uses 16-bit channels; a built-in `parseColor`/`parseHex` handles X11/xterm hex (`Colors.swift:355`).

**Current gap:** the theme controls only UI *chrome*. `theme.terminal.bg/fg` isn't even wired to the live terminal — it's used solely by the picker's preview swatch (`App/ThemePickerView.swift:73`). The terminal renders in SwiftTerm defaults. This design closes that gap.

## Locked decisions (from brainstorming)

1. **6 colored categories via themed ANSI-16**, sequenced **infra first**, then the two themes, then import.
2. **Full explicit 16** ANSI colors are authored per theme (not 8 + derived brights) — 1:1 with import formats, matches what SwiftTerm wants, maximal control.
3. **Strict typed derivation:** the ANSI-16 palette is the **single source of hue**; UI semantic tokens (accent/state) are **typed references into ANSI slots**, not free-floating hex. This guarantees UI/terminal cohesion, prevents drift, and lets a future importer auto-populate the UI from an imported 16-color scheme.
4. Per-theme role map resolves the "non-blue accent" case: normal/bright pairs keep shades distinct (e.g. Neon Midnight `accent = brightRed` coral vs `broken = red` crimson).

## Architecture

Three units, split across the two tiers per the repo's "pure logic in `SemicolynKit`, thin wiring in `App/`" rule.

### 1. Token structure — `SemicolynKit/Theme/` (Linux-tested)

**`ANSISlot`** — the 16 ANSI colors in SwiftTerm index order, so `rawValue` *is* the `installColors` index:

```swift
public enum ANSISlot: Int, CaseIterable, Sendable {
    case black = 0, red, green, yellow, blue, magenta, cyan, white
    case brightBlack, brightRed, brightGreen, brightYellow,
         brightBlue, brightMagenta, brightCyan, brightWhite
}
```

**`ANSIPalette`** — the authored 16 colors, source of truth for hue:

```swift
public struct ANSIPalette: Equatable, Sendable {
    private let colors: [ThemeColor]                 // exactly 16, indexed by ANSISlot.rawValue
    public init(_ colors: [ThemeColor])              // precondition(colors.count == 16)
    public subscript(_ slot: ANSISlot) -> ThemeColor // resolve a role's slot
    public func ordered() -> [ThemeColor]            // 0…15 for installColors
}
```

**`ANSIRoleMap`** — which ANSI slot feeds each UI semantic role (per theme):

```swift
public struct ANSIRoleMap: Equatable, Sendable {
    public let accentPrimary, accentHighlight: ANSISlot
    public let success, degraded, broken, warning: ANSISlot
    // bell.edge and focus.paneBorder derive from accentPrimary.
}
```

**Extended `Theme.Terminal`** — adds `cursor`, `cursorText`, `selection` to the existing `bg, fg`. These are directly-authored `ThemeColor`s (terminal fg/bg/cursor are conceptually outside the 16 ANSI slots, matching SwiftTerm's separate `nativeForegroundColor`/`caretColor` fields).

**`Theme` gains `ansi: ANSIPalette`** and a **resolving factory**:

```swift
extension Theme {
    /// Builds a Theme whose accent/state colors are RESOLVED from the ANSI
    /// palette via `roles` — the strict-derivation contract. Stores both the
    /// resolved ThemeColors (so existing UI code reading `theme.accent.primary`
    /// is unchanged) AND `ansi` + `roles` (for the terminal bridge and future
    /// import round-trip). keybar/predictor/banner tints derive from the
    /// resolved accent/state, centralizing what the theme files hand-build today.
    public static func fromANSI(
        ansi: ANSIPalette, roles: ANSIRoleMap,
        surface: Surface, text: Text, terminal: Terminal
    ) -> Theme
}
```

The factory enforces derivation *by construction*: a theme author passes `ANSISlot`s, never raw hex, for accent/state. It cannot drift out of the 16.

### 2. Pure bridge value — `SemicolynKit` (Linux-tested)

**`TerminalPalette`** — everything the terminal view needs, as a flat DTO the App consumes without touching `Theme` internals:

```swift
public struct TerminalPalette: Equatable, Sendable {
    public let fg, bg, cursor, cursorText, selection: ThemeColor
    public let ansi16: [ThemeColor]   // ordered 0…15
}
extension Theme { public func terminalPalette() -> TerminalPalette }
```

### 3. App-tier SwiftTerm bridge — `App/` (macOS-CI only)

`applyPalette(_ palette: TerminalPalette, to view: TerminalView)`:
- `view.installColors(palette.ansi16.map(SwiftTermColor.init(themeColor:)))`
- sets `nativeForegroundColor`, `nativeBackgroundColor`, `caretColor`, `caretTextColor`, `selectedTextBackgroundColor`

A `ThemeColor → SwiftTerm.Color` converter scales `rgba()` 0…1 doubles to UInt16 0…65535 (`× 65535`, rounded); opacity is dropped (terminal colors are opaque). Hooked in **two places**: when a terminal view is created, and when the observed theme changes (via `ThemeEnvironment`), so switching themes recolors live sessions.

## Data flow

```
Theme (authored: ansi + roles + terminal tokens)
   │  Theme.terminalPalette()            ← pure, Kit, Linux-tested
   ▼
TerminalPalette (fg/bg/cursor/cursorText/selection + ansi16[16])
   │  applyPalette(_:to:)                ← App bridge, macOS-CI
   ▼
SwiftTerm TerminalView (installColors + native fg/bg/caret/selection)
```

## Backfill: existing themes

Both shipped themes must gain an authored ANSI-16 palette + role map (they currently hand-build accent/state as hex). This is **real palette-design work for two themes**, mocked up like the new ones before coding:

- **Neon Midnight** — coral-neon on blue night. `accent = brightRed` (coral `#FF6F5E`), `broken = red` (crimson `#E5455E`), `success = green` (verdigris family), `warning/degraded = yellow` (amber). The 16 are designed to sit on the existing `#07090E`/`#05070B` night.
- **Bell Bronze** — its bronze accent must occupy an ANSI slot (its `yellow`), so terminal yellow reads bronze — on-theme.

## Error handling

- `ANSIPalette.init` `precondition`s exactly 16 — a construction bug, not a runtime input, so a hard precondition is correct.
- The bridge is total: every `TerminalPalette` field is non-optional and typed-resolved, so there is no "missing color" runtime path. If SwiftTerm rejects a palette (count ≠ 16, impossible given the type), the view keeps its prior colors — no crash.
- Theme fg/bg `ThemeColor`s are authored at `opacity: 1.0`; the converter asserts opaque for terminal roles.

## Testing (per `2026-06-18-testing-standards-design.md`)

**Kit (real, Linux — the whole point of keeping this tier pure):**
- **EP/exact-value:** `ANSIPalette.ordered()` returns 16 in slot order; `palette[.brightBlue]` returns the authored hex exactly; `ANSISlot.blue.rawValue == 4` (SwiftTerm index) — asserted, not assumed.
- **Derivation:** `Theme.fromANSI(...)` resolves `accent.primary == ansi[roles.accentPrimary]` (exact hex), and Neon Midnight's `accent != broken` (the coral-vs-crimson distinction — a real regression guard).
- **Boundary/negative:** `ANSIPalette([15 colors])` traps (precondition) — documented, tested via the 16-count guarantee at call sites; `terminalPalette()` round-trips all five terminal tokens + the 16 by value.
- **Backfilled themes:** exact-hex assertions for Neon Midnight & Bell Bronze accent/state *after* derivation, so a wrong role map fails loudly.
- **Anti-tautology:** every test asserts a concrete resolved hex or a specific inequality — never "constructed OK".

**App bridge (not Linux-testable):** macOS-CI compile + Simulator visual pass (the owed Simulator feel-pass covers it). No fake-driven assertions; the bridge is thin mapping over verified pure values.

## Scope — explicitly NOT in this piece

- **The two new blue themes** (Neon Cobalt + even-spaced). Neon Cobalt's UI palette is locked (`accent #6E80FF`, `highlight #9FADFF`, `success #2CE59B`, `broken #FF5C6C`, `warning #FFB020`, bluer night `#06080F`/`#04060D`); its **ANSI-16 palette + role map** are designed in Piece 2, on top of this infra.
- **Theme import** (parse iTerm2/base16/etc). This infra is the enabling primitive; the parser + import UI are Piece 3.
- **256-color palette** — SwiftTerm derives it from the 16 via its `ansi256PaletteStrategy` (xterm cube); we supply only the 16.
- Non-blue category count changes beyond adding the ANSI block; UI keeps its accent + 4 state roles, now *referencing* ANSI.

## Reference artifacts (mockups, `mockups/drafts/`)

- `2026-07-01-theme-blue-neon-candidates.html` — Concept A/B side-by-side.
- `2026-07-01-theme-cobalt-legibility.html` — cobalt contrast tuning (`#6E80FF` @ 5.9:1 chosen).
- `2026-07-01-theme-neon-cobalt-final.html` — Neon Cobalt in context + full swatch header (the standard theme-page pattern).
- `2026-07-01-theme-even-spacing-counts.html` — the N=4…8 ring comparison behind the "6 categories" decision.

## Open follow-ups

- Piece 2 spec: the two blue themes' full 16-color ANSI palettes + role maps.
- Piece 3 spec: theme import (format parsers → `ANSIPalette` + `ANSIRoleMap`).
- `useBrightColors` (SwiftTerm, default `true`) interaction with authored bright slots — verify in Simulator.
