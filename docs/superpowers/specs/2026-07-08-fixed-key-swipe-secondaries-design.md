<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Fixed-key swipe secondaries (Topic E)

**Date:** 2026-07-08
**Status:** Approved (brainstorming), pending implementation plan
**Related:** the locked keybar-customization design
(`docs/superpowers/specs/2026-06-15-keybar-customization-design.md` — "Slot interaction:
tap=primary, swipe-up=secondary, swipe-down=tertiary, shown as small dim glyphs");
`docs/brainstorming-decisions.md` (same locked rule); `Sources/SemicolynKit/Keybar/`,
`App/Keybar/KeybarSlotViews.swift`, `App/Keybar/KeybarEditorView.swift`.

## Problem

The locked keybar design gives every slot a tap + swipe-up + swipe-down, rendered as dim
corner glyphs. This shipped for **custom** slots, **promotion** slots, and the **Ctrl
modifier** — but the **fixed** keys (`KeybarSlot.symbol(String)`, `.tab`, and the F-keys) are
tap-only. There is no way to, e.g., swipe up on `-` to send `_`, or on `Tab` to send
Shift-Tab.

## Goal

Give the fixed keys (symbols + Tab + F-keys) swipe-up/down secondaries, with **built-in
defaults** and **per-key user overrides**, rendered with the existing dim corner-glyph
pattern. Vertical swipes only (horizontal is reserved for Esc window-nav / scroll-region pan
— locked).

## Decisions (locked during brainstorming)

- **Scope: all fixed keys** — symbols, Tab, and F1–F12.
- **Built-in defaults + user overrides, both in one feature.**
- **Overrides stored as a SEPARATE map** in `KeybarSettings` (keyed by a stable fixed-key
  id); `KeybarSlot.symbol(String)` is unchanged — no layout-schema migration.
- **A secondary is a literal OR a logical key+modifier** (so `Tab` swipe-up = Shift-Tab reuses
  the existing `KeyInput.tab` + shift path, which already emits `ESC [ Z`).
- **Resolution: override wins, else default, else none.**
- **Rendering: the existing dim glyph pattern** (top/bottom, ~7–9pt, secondary color) —
  reuse, don't reinvent.

## Non-goals (YAGNI)

- Horizontal swipes (reserved).
- The v2 custom `inputView` / long-press-alts on iOS letter keys (a separate, deferred
  roadmap item — this feature is only about our own keybar's fixed slots).
- Changing custom/promotion/modifier slots (they already have this).
- Per-host or context-specific fixed-key secondaries (global map only).

## Architecture

### 1. Kit — the secondary model + resolution (Linux-tested)

New `Sources/SemicolynKit/Keybar/FixedKeySecondary.swift`:

```swift
/// What a swipe on a fixed key emits: a literal string, or a logical key with modifiers.
public enum SecondaryValue: Equatable, Sendable, Codable {
    case literal(String)                       // e.g. "_"
    case key(KeyInput, KeyModifiers)           // e.g. (.tab, shift) → Shift-Tab (ESC [ Z)
}

/// The swipe-up / swipe-down secondaries bound to a fixed key. Either may be nil.
public struct SwipeSecondaries: Equatable, Sendable, Codable {
    public var up: SecondaryValue?
    public var down: SecondaryValue?
    public init(up: SecondaryValue? = nil, down: SecondaryValue? = nil) { self.up = up; self.down = down }
}

/// A stable, Codable id for a fixed key, used as the override-map key.
public enum FixedKeyID: Hashable, Sendable, Codable {
    case symbol(String)   // the symbol char(s)
    case tab
    case fkey(Int)        // 1...12
}
```

- **`FixedKeyDefaults`** — a pure static resolver `defaults(for: FixedKeyID) -> SwipeSecondaries`.
  A curated table for common symbols (`-`→up `_`; `/`→up `\`; `.`→up `..`; `:`→up `;`;
  `'`→up `"`; `` ` ``→up `~`; `9`/`0` shells etc. as sensible), `Tab`→up `.key(.tab, shift)`
  (Shift-Tab), F-keys → empty (no natural default; user-overridable). Symbols not in the
  table → empty. The exact table is finalized in the plan; it is data, not logic.
- **`KeybarSettings` gains `var fixedKeySecondaries: [FixedKeyID: SwipeSecondaries]`** (empty
  by default) — the user-override map. Codable → persists with the existing settings blob.
- **Resolution (the tested logic):**
  `resolveSecondaries(for id: FixedKeyID, overrides: [FixedKeyID: SwipeSecondaries]) -> SwipeSecondaries`
  — returns `overrides[id]` if present, else `FixedKeyDefaults.defaults(for: id)`. A
  per-direction merge is NOT done (an override replaces the whole pair) — simpler and
  predictable; documented.
- **Emit bytes:** `SecondaryValue` resolves to bytes through the existing `KeyEncoding`
  (`.literal` → the string's bytes via the symbol path; `.key(input, mods)` → the existing
  `encode(input, modifiers:)`). No new byte-encoding logic; reuse `KeyEncoding`.

### 2. App — gestures + glyphs on fixed slots

In `App/Keybar/KeybarSlotViews.swift` (`SymbolSlotView`, `FkeySlotView`, the Tab slot) and
wherever fixed slots render, add — mirroring `PromotionSlotView` exactly:

- A `DragGesture(minimumDistance: 12)` `.onEnded`: `height < -12` → emit the resolved `up`
  secondary; `height > 12` → emit the resolved `down`. Emit via the VM (literal →
  `vm.keybar.tapSymbol(...)`; key → the VM's existing key path, e.g. `vm.keybar.tapKey(input,
  modifiers:)` or the equivalent already used for Tab/F-keys — the plan wires the exact call).
- Dim glyph overlays: `˄` top / `˅` bottom when the resolved `up`/`down` is non-nil (reuse the
  `hintGlyph`/overlay pattern already in `CustomSlotView`; ~7pt secondary color). For a
  literal, show the char; for a key, show a short label (e.g. `⇤` for Shift-Tab).
- The resolved secondaries come from §1 using `store.settings.fixedKeySecondaries`.

The keybar view already has the `vm` + `keybarSettings`; thread the override map to the slot
views (or resolve once and pass `SwipeSecondaries` into each fixed slot view).

### 3. App — per-key override editor

In `App/Keybar/KeybarEditorView.swift`, give fixed-key rows (symbol / tab / fkey) an edit
affordance (pencil, exactly like custom slots today) → a new
`App/Keybar/FixedKeySecondaryEditorView.swift`:

- Shows the key's identity + two direction editors (**Swipe up**, **Swipe down**). Each
  direction editor supports BOTH secondary kinds (locked decision — full editor):
  - **Literal:** a single/short text field for a literal string (e.g. `_`, `..`).
  - **Special key:** a picker choosing a `KeyInput` (Tab, Esc, Enter, Backspace, an
    F-key F1–F12, an arrow) plus modifier toggles (Ctrl/Alt/Shift) → a `.key(input, mods)`
    secondary (e.g. Tab + Shift = Shift-Tab).
  - A small segmented control per direction selects **None / Literal / Special key**; "None"
    with no override = falls back to the built-in default, and an explicit "Clear override"
    removes the map entry entirely (reverts both directions to defaults).
- The built-in default for the direction is shown (e.g. as placeholder / secondary text) so
  the user sees what they're overriding.
- Writes to `store.settings.fixedKeySecondaries[id]`.

### 4. Data flow

Slot render → `resolveSecondaries(for: id, overrides: store.settings.fixedKeySecondaries)` →
`SwipeSecondaries` → glyphs + gesture handlers. Swipe → `SecondaryValue` → `KeyEncoding` bytes
→ VM send. Editor writes overrides → `@Published` settings change → keybar re-renders (live).
Persistence rides the existing `KeybarSettings` Codable/UserDefaults path.

## Error handling / edge cases

- Symbol with no default and no override → no swipe, no glyph (unchanged tap-only behavior).
- An override that clears both directions → `SwipeSecondaries(up: nil, down: nil)`; treated as
  "no secondaries" (equivalent to removing the map entry; the resolver + editor normalize
  this).
- Multi-character literal secondary (e.g. `..`) → emitted as the full string; glyph shows it
  (may be tight — the plan caps/renders gracefully).
- Swipe threshold + horizontal reservation identical to promotion slots (no new gesture
  conflict; the locked gesture-ownership rules already cover vertical-on-slot).

## Testing

- **Kit (Linux XCTest):**
  - `SecondaryValue` + `SwipeSecondaries` Codable round-trip (each case).
  - `FixedKeyDefaults.defaults(for:)` — assert exact secondaries for representative keys
    (`-`→`_`, `/`→`\`, `Tab`→Shift-Tab, an F-key→empty, a symbol-with-no-default→empty).
  - `resolveSecondaries` — override present → override; absent → default; EP over
    symbol-with-default / symbol-without / tab / fkey / overridden. Assert exact values.
  - Emit: a `SecondaryValue.key(.tab, shift)` encodes to `ESC [ Z` via `KeyEncoding`
    (reuses/reasserts the existing back-tab path); a `.literal("_")` encodes to `_`.
- **App tier (macOS CI + device):** swipe-up/down on a symbol/Tab/F-key fires the resolved
  secondary; glyphs render; the editor writes an override and the keybar reflects it live; a
  cleared override reverts to default.

## Files touched (anticipated)

- `Sources/SemicolynKit/Keybar/FixedKeySecondary.swift` — new (model + `FixedKeyDefaults` +
  `resolveSecondaries`).
- `Sources/SemicolynKit/Keybar/KeybarSettings*.swift` — add `fixedKeySecondaries` map
  (Codable).
- `Tests/SemicolynKitTests/FixedKeySecondaryTests.swift` — new.
- `App/Keybar/KeybarSlotViews.swift` — swipe gestures + glyphs on symbol/Tab/F-key slots.
- `App/Keybar/FixedKeySecondaryEditorView.swift` — new (override editor).
- `App/Keybar/KeybarEditorView.swift` — edit affordance on fixed-key rows → the editor.
- Possibly `App/…` VM keybar (a `tapKey(input, modifiers:)` seam if one isn't already exposed
  for the swipe path).

## Scope note

This is materially larger than topics A–D (Kit model + persistence + gestures + rendering + a
new editor screen). It remains one coherent plan but expect ~3× the task count. The plan may
sequence it Kit-first (model + resolution + defaults, fully testable) → rendering/gestures →
editor, so each layer lands behind a compile/test gate.
