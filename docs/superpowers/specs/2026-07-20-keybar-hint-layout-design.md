<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Design: keybar hint layout + slot sizing (device issue #2) — 2026-07-20

## Problem

Device issue #2 (TF build 66, screenshot IMG_4020): the keybar's swipe-secondary hint
glyphs render as tiny 7px characters pinned to each key's top/bottom edge, overlapping the
main glyph and reading as misaligned clutter. Keys with a hint look different from keys
without one, the slot widths are uneven, and the bar reads too tall.

Root cause (code): `fixedKeySwipes` (`App/Keybar/KeybarSlotViews.swift:56-71`) renders the
secondaries as `.overlay(alignment: .top)` / `.overlay(alignment: .bottom)` at
`font(.system(size: 7))`. Overlays add no layout size, so they float on the key edge over
the primary glyph. `SlotChrome` uses `minWidth: 34` so content-sized keys vary in width; the
overall bar padding + edge glyphs make the row read loose.

## Locked design (from the mockup `mockups/drafts/2026-07-20-keybar-layout-fix.html`)

The tapped glyph is **large, left, vertically centered**. Its swipe secondaries sit **to the
right as a small stacked column**: **swipe-up on top, swipe-down below**.

- **Two swipes** (up + down present): both glyphs stack right, up over down.
- **One swipe** (only up, the common case, e.g. `/`→`\`, `-`→`_`, `⇥`→Shift-Tab): the top
  slot is filled; the bottom is an **invisible spacer** so the main glyph stays vertically
  centered (no upward drift).
- **No swipes**: no secondary column; the key is just its main glyph.
- **Hint color:** the theme accent, `theme.accent.primary` (coral in neonMidnight; note the
  accent lives at the top-level `theme.accent`, NOT under `theme.keybar`, which only carries
  slot backgrounds). NOT a hardcoded color, so it adapts per theme. Slightly reduced opacity
  so the hint reads as secondary to the main glyph.
- **Slot width:** uniform. Every keybar slot shares one width so hint-stack keys and bare
  keys line up (this directly fixes the "uneven gaps" complaint; the gap was always uniform,
  the widths varied). The uniform width must be wide enough for a main glyph + the stack.
- **Bar height:** tight. Trim the `barChrome` vertical padding; the hint column lives inside
  the existing slot height (34pt) rather than adding an edge band, so no extra height.

This REPLACES the `.overlay(.top/.bottom)` edge glyphs entirely.

## Components

### 1. Kit: hint glyph strings for a `SwipeSecondaries` (pure, testable)

`fixedKeyGlyphLabel(_ v: SecondaryValue) -> String` already exists
(`KeybarSlotViews.swift`) but is App-tier. Move / add a pure Kit helper so the up/down hint
strings are computed and tested in `SemicolynKit`, mirroring the tested-seam pattern:

```swift
// Sources/SemicolynKit/Keybar/HintGlyphs.swift
/// The display glyph for a secondary value (tab->⇥/⇤, arrows->↑↓←→, literal as-is).
public func hintGlyph(for v: SecondaryValue) -> String

/// The up/down hint glyphs to show for a key, each nil when that direction is unbound.
/// Pure projection of SwipeSecondaries onto (up, down) display strings.
public func hintGlyphs(for s: SwipeSecondaries) -> (up: String?, down: String?)
```

`hintGlyph` is the existing `fixedKeyGlyphLabel` logic relocated to Kit (the App keeps a thin
call or the moved function). This makes glyph mapping (Shift-Tab -> `⇤`, arrows, literals)
unit-testable on Linux.

### 2. App: `SlotChrome` gains an optional stacked-secondary column

Rework `SlotChrome` (`KeybarSlotViews.swift:6-17`) so a slot renders:
`HStack { mainGlyph ; if hasHints { VStack { upGlyph ; downGlyph } } }`, where the VStack is
a fixed-width, accent-tinted, small-font column (~8pt), up over down, with an invisible
spacer when a direction is unbound. The main glyph stays centered. Provide a
`SlotChrome`-level API (or a new `KeySlot` view) that takes the main label + an optional
`(up: String?, down: String?)` so every slot type (symbol, tab, custom) renders hints
uniformly instead of each calling `.fixedKeySwipes` with overlays.

Uniform width: give the slot a single shared `minWidth` (compute from the widest expected
content: main glyph + hint column) so all slots match. The value is tuned on-device but
starts at ~40pt (natural 34 + ~6 for the hint column).

### 3. App: replace `fixedKeySwipes` overlays with the new column + keep the gesture

`fixedKeySwipes` currently does BOTH the overlay glyphs AND the `DragGesture` that emits the
secondary. Keep the gesture (swipe-up/down -> emit up/down secondary) exactly as-is; remove
the two `.overlay` modifiers. The hint glyphs now come from the `SlotChrome` column, fed by
`hintGlyphs(for:)`. `SymbolSlotView`, `TabSlotView`, and any fixed-key slot pass their
resolved `SwipeSecondaries` into the slot so the column renders.

### 4. App: bar height trim

In `KeybarView.barChrome` (`KeybarView.swift:54-59`), reduce `.padding(.vertical, 5)` to the
tight value the mockup uses (tune on-device; start ~3). No structural change; the hint column
lives inside the slot so nothing else adds height.

## Testing

- **Kit (Linux, TDD):** `hintGlyph(for:)` and `hintGlyphs(for:)` — EP over the cases:
  literal (`\`, `_`), key+mods (Shift-Tab -> `⇤`; plain tab -> `⇥`), arrows (each direction),
  both-present (`|` with up `(` + down `)` -> `("(", ")")`), up-only (`/` -> `("\\", nil)`),
  down-only, neither (`(nil, nil)`). Assert exact glyph strings (anti-tautology).
- **App-tier (macOS-CI + device):** the SlotChrome/column layout is App-tier (not
  Linux-testable). Validation = macOS CI compile + device retest: the `|` key shows `(` over
  `)` in accent color to the right of `|`; single-swipe keys show one top glyph with the main
  centered; slot widths are uniform; the bar is tighter; swipe gestures still emit the right
  secondary.

## Non-goals

- No change to WHICH secondaries a key has (the `FixedKeyDefaults` table is unchanged; only
  how they're DISPLAYED). Adding new default down-swipes is a separate concern.
- No change to the swipe GESTURE thresholds or emit behavior — only the hint rendering and
  slot sizing/height.
- The d-pad key (`PadView`) is not a fixed-key-secondary slot and is unaffected.
