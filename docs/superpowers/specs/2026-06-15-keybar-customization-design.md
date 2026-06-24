# Keybar layout, customization, and gesture rules — design

**Status:** locked
**Date:** 2026-06-15
**Supersedes (partially):** the Keybar v0 layout in `mockups/specs/keybar.html`, the locked-region composition in §"Keybar integration" of `2026-06-14-context-detection-design.md`, and the window-pill / pane-pill decisions in the `brainstorming-decisions.md` window-switching and pane-management tables.
**Related specs:** context-detection (2026-06-14), function-keys (2026-06-14), degraded-mode (2026-06-14), multi-connection-switching (2026-06-15)

## Summary

A revisit of the v0 keybar layout based on three insights:

1. The previous Esc slot + Window pill could be **fused** into a single leftmost pill with richer gesture vocabulary. Window navigation, settings entry, and the Esc keystroke unify into one widget.
2. The previous Pane pill + arrow-pad could be **fused** into a single widget where the long-press gesture arms a pane-management mode. Arrow drag and pane operations live on one surface.
3. The locked / scrollable distinction (`survives panning` vs `visible at scroll rest`) is meaningful enough to expose as a first-class user-customizable boundary. Almost every slot should be reorderable, removable, and movable between regions.

The previous v0 locked set was six conceptual items (window pill, pane pill, arrow-pad, Esc, plus Ctrl/Tab living at scroll-rest). After fusion and revisit it's four locked items: **Esc pill · Pad · Modifier · Tab**.

## Scope

In scope:
- Default locked-left composition
- Esc pill gesture vocabulary and visual
- Pad gesture vocabulary (arrows + pane management)
- Customization surface (reorder, remove, lock-vs-scroll boundary)
- Custom slot creation and binding model
- Macro creation surface
- Reverse-bar option (locked-right for left-handed / preference users)
- Gesture-ownership rules at the bar level (pan vs widget claims)

Out of scope (carried forward unchanged from earlier specs):
- Predictive input surface (sits above the keybar)
- Context-detection promotions (still drives bronze-tinted slots in scroll region; promotion-set authoring unchanged)
- Function-keys (Fn slot still toggles F-key mode on scroll region)
- v2 custom inputView (system-keyboard-extension territory)

Out of scope (deferred to v1.5+):
- Swipe-left / swipe-right bindings on user-created slots (revisit if demand surfaces)
- iPad-specific keybar adaptation
- Per-host keybar overrides
- Telemetry-driven default tuning (already locked direction; not part of this spec)

## Default locked-left composition

Four widgets, in this default order, left to right:

| Position | Widget | Type | Removable | Movable to scroll |
|---|---|---|---|---|
| 1 | **Esc pill** | special widget | no | no |
| 2 | **Pad** (arrow + pane) | special widget | no | no |
| 3 | **Modifier** (Ctrl/Alt/Shift) | regular slot | yes | yes |
| 4 | **Tab** | regular slot | yes | yes |

Esc pill and Pad are constrained to the locked region for three reasons:

- **Functional anchoring** — Esc pill is the single top-level handle to Settings / hosts / windows. Allowing it to be hidden behind a pan would orphan the user.
- **Muscle-memory anchoring** — Pad's arrow drag is too fundamental to hide.
- **Gesture-ownership** — both widgets use horizontal swipes as bound actions. Confining them to the locked region eliminates pan-collision dead zones in the scrollable region.

Within the locked region, all four widgets are reorderable. The user can put Esc third, Pad fourth, Modifier first, Tab second — whatever fits their hand. Modifier and Tab can also be moved into scroll if the user prefers (they'd then be visible at scroll rest but lost when panning).

## Esc pill

Replaces the previous separate Esc slot and Window pill. Single widget carrying the Esc keystroke, window navigation, and unified-picker entry.

### Gestures

| Gesture | Action |
|---|---|
| Tap | Esc keystroke |
| Swipe right | Next window (wraps) |
| Swipe left | Previous window (wraps) |
| Swipe up | Quick window picker (compact vertical list anchored above the pill — current host's windows only) |
| Swipe down | Create new window — inline confirm sheet, "Create new window? [Create] [Cancel]" |
| Long-press | Unified picker (full sheet anchored above keybar — current host's windows + Live hosts + Recent + Connect + Settings) |

Light haptic on window-switch wrap (matches the previous window-pill behavior). The quick window picker on swipe-up supports drag-up-then-release-on-row selection (carried over from the old window-pill long-press picker mechanics).

### Visual

The pill carries the literal label **"Esc"** plus a small dim bronze `≡` glyph in the corner — the same hint-glyph pattern used elsewhere in Neotilde to signal "this slot has more gestures." Window title is *not* shown on the pill itself; the user identifies the current window by terminal content or by opening a picker.

Pressed state (during long-press or while the picker is open): bronze-tint fill, accent border, brighter glyph color — same treatment as the existing armed-modifier state.

Mockup: `mockups/drafts/esc-pill.html`.

### Discoverability

The `≡` glyph signals "more options exist here." Users discover the gesture vocabulary by long-pressing (most discoverable — opens the full picker), then through accidental swipes that reveal window navigation. The settings tree being reachable only via this pill teaches the long-press gesture early.

## Pad (fused arrow + pane)

Replaces the previous separate arrow-pad and Pane pill. Single widget carrying arrow keystrokes and pane management.

### Gestures

| Gesture | Action |
|---|---|
| Drag (any direction from center) | Arrow keystroke (↑ ↓ ← →) — unchanged from previous arrow-pad behavior |
| Tap (touch + quick release, no drag) | Zoom toggle for the active pane |
| Long-press (~400ms, no movement) | Arms "pane mode" — bronze tint + quadrant hint overlay appears |
| Long-press + swipe horizontal | Horizontal split (`tmux split-window -v`) |
| Long-press + swipe vertical | Vertical split (`tmux split-window -h`) |
| Long-press + release without swipe | Opens leftover-actions menu: **Swap with next · Close pane** |

Disambiguation between drag (arrow) and long-press (pane mode) is gesturally clean: arrow drag requires immediate motion; pane mode requires holding without movement for ~400ms. The bronze tint + overlay on long-press confirms the user has armed pane mode.

### Zoom indicator

Since the Pane pill is gone, zoom state has no in-keybar indicator. Instead, **zoom state shows on the focused pane itself**: when a pane is zoomed, its accent border switches from the standard active-pane treatment to a brighter bronze fill, and the corner index badge gains a `⊕` glyph next to the index number. This is the only visual cue for zoom state. Acceptable because the user only cares about zoom state when they're already looking at the panes.

### Pane-mode overlay

While the long-press is held and the gesture is in the "armed but no swipe yet" window:

- The Pad's background fills with bronze tint (~20% opacity).
- A subtle quadrant overlay shows direction hints: small `↕` glyph indicates vertical-split, `↔` indicates horizontal-split, dim labels at top/bottom for "Vert split" and "Horiz split" (or just glyphs).
- Light haptic on enter-pane-mode (matches the locked engage-haptic for armed states).

On swipe → action commits, overlay disappears, layout updates. On release without swipe → leftover-actions menu appears as a small anchored sheet above the Pad.

## Modifier slot

Combined Ctrl/Alt/Shift slot, carried forward unchanged from the locked design. Three gestures select which modifier to arm:

- Tap: arm Ctrl (sticky-for-one-keystroke; double-tap to lock per the existing Ctrl lock decision)
- Swipe-up: arm Alt (sticky only)
- Swipe-down: arm Shift (sticky only; iOS already provides caps-lock for Shift)

Default position is locked-left position 3. The user can move it to scroll if they prefer; the Modifier remains a regular slot regardless of region.

## Tab slot

Default position locked-left position 4. Regular slot, tap only. Movable to scroll or removable like any other non-special slot.

## Scroll region (default rest position)

When the bar is at scroll rest (no user panning), the scrollable region shows, left to right:

1. **Promotions area** (zero or more bronze-tinted slots from the engaged context's promotion set — unchanged from context-detection spec).
2. **Defaults** — `/`, `\|`, `~`, `-`, `(`, `)` (carried forward; user-customizable).
3. **Fn** — function-keys toggle (carried forward from function-keys spec).

Promotions land directly after the locked region (or after the locked region's last item, whichever is rightmost). Defaults and Fn extend to the right; panning reveals further items if any.

## Customization model

### Surface

**Settings → Keybar** — a single editable list of all keybar slots in order.

Each row in the list represents one slot. Rows include:
- The four built-in widgets (Esc pill, Pad, Modifier, Tab)
- Default convenience slots (`/`, `\|`, `~`, `-`, `(`, `)`, Fn)
- Any user-created custom slots
- Any macros the user has pinned to the keybar

A **draggable divider** appears between rows, marking the boundary between locked region (above) and scroll region (below).

### Mechanics

- **Drag-handle** on each row lets the user reorder freely within their current region.
- **Drag across the divider** moves the row between regions (lock ↔ scroll). Esc pill and Pad refuse drag across the divider (they're constrained to locked); a small lock-icon on those rows indicates the constraint.
- **Swipe-left on a row** offers Delete. Built-in slots that aren't removable (Esc pill, Pad) show no delete affordance; other built-ins (Modifier, Tab, defaults) confirm with a one-time first-time warning ("Remove Modifier? You'll lose Ctrl/Alt/Shift access.") that doesn't nag on repeat removes.
- **"+ Add"** at the bottom opens a sub-sheet with three options:
  - **Pin a macro** — pick from the Launcher's macro library.
  - **Create new macro** — opens the macro-creation flow (see Macro creation).
  - **Create new slot** — opens the custom-slot editor.
- **"Reset to defaults"** at the top of the screen restores the v1 default layout (Esc · Pad · Modifier · Tab in locked region; defaults + Fn in scroll). Single tap, no confirm — the user can re-customize freely.

### Sticky rules summary

| Slot | Removable | Movable across divider | Reorderable within region |
|---|---|---|---|
| Esc pill | no | no | yes (within locked) |
| Pad | no | no | yes (within locked) |
| Modifier | yes (with first-time confirm) | yes | yes |
| Tab | yes | yes | yes |
| Default symbols | yes | yes | yes |
| Fn | yes | yes | yes |
| User custom slots | yes | yes | yes |
| Pinned macros | yes | yes | yes |

## Custom slot binding model

A user-created slot is a bundle of gesture bindings. Each binding points at a macro (a single keystroke is treated as a one-element macro). This unifies "slot" and "macro consumer."

### Bindable gestures

| Gesture | Bindable on custom slot? |
|---|---|
| Tap | yes |
| Swipe-up | yes |
| Swipe-down | yes |
| Long-press | yes |
| Swipe-left | **no — deferred to v1.5+** |
| Swipe-right | **no — deferred to v1.5+** |

The horizontal-swipe restriction matches Blink's pattern: regular keys don't have horizontal swipes because horizontal touches on the bar are reserved for panning the scroll region. Only the two built-in special widgets (Esc pill, Pad) use horizontal swipes, and they live in the locked region where panning isn't a question. If a future user-research signal shows real demand for horizontal-swipe bindings on user slots, we'll add an explicit opt-in toggle that promotes a slot to "special widget" status, accepting the pan dead-zone trade-off. Not in v1.

### Binding payload

Each gesture binding holds:
- **Macro reference** (pointer to a macro in the Launcher's library, or null = unbound)
- **Optional override label** (shown on the slot for that gesture; if absent, inherits from the macro's name)

A slot with no bindings is meaningless and not allowed — the slot editor requires **at least one binding** (any of the four) before Save is enabled. Tap is the most common but not required (a slot can exist with only a swipe-up binding, for instance — useful for less-frequent actions where the user wants the slot to be deliberately "quiet" on accidental taps).

### Slot display content

The slot's visual is built from its bindings:

- **Primary label/glyph** — user-defined text or single character (e.g., `kc` for a kubectl macro, `:` for a single colon). If not overridden, defaults to the name of the macro bound to tap (or the first bound gesture, if tap is unbound).
- **Optional swipe-glyphs** — small dim characters at top and bottom edges of the slot if swipe-up / swipe-down are bound. Matches the existing locked design's dim-secondary-character pattern.
- **Optional `≡` hint glyph** — small dim corner glyph if long-press is bound. Matches the existing locked discoverability pattern.

### Editing custom slots

- **Open editor:** Settings → Keybar → tap any custom-slot row.
- **Editor contents:**
  - Label/glyph editor at top (text field with character limit ~3 chars for compact slots, ~6 for wider).
  - Four binding rows (tap / swipe-up / swipe-down / long-press), each tappable to assign a macro or "Record new."
  - Save / Cancel / Delete buttons at bottom.
- **Macro selection:** tap a binding row → Launcher library list with search → pick a macro → returns to slot editor.
- **Record new:** tap a binding row → "Record new" → enters record mode (see Macro creation) → on save, returns to the slot editor with the new macro pre-assigned to that binding.

The "long-press = edit slot" shortcut from the original v0 keybar interaction model is **removed**. Slot editing happens only via Settings → Keybar. Long-press becomes a fourth full-power bindable gesture for the user.

## Macro creation

The macro concept is already locked: "a recorded sequence of input events." This section defines the creation surface in v1.

### Entry points

- **Launcher view** (the searchable full macro list) — "+ New macro" at top.
- **Custom-slot editor** — "Record new" on any binding row.
- **Settings → Keybar → "+ Add" → Create new macro** (jumps to the launcher-side creation flow).

### Authoring modes

**Record mode:**
1. Tap "Start recording."
2. The keybar enters a special record state (bronze frame, blinking-cursor indicator).
3. The user types the sequence using any input surface: iOS keys, modifier slots, special widgets — everything is captured as raw input events.
4. Tap "Stop."
5. The sequence is displayed as a chip list for review; the user can reorder, delete, or insert chips before saving.

**Template mode:**
1. Type the literal output string in a text field.
2. Inline modifier syntax for chords (e.g., `{Ctrl+R}docker{Enter}` — the placeholders are parsed and rendered as visual chord chips during edit).
3. Save when done.

### Macro metadata

A macro has:
- **Name** — display label (used as slot label fallback)
- **Body** — sequence of input events (chord/string/mixed)
- **Optional placeholders** — already locked: parameterized commands with defaults and per-host remembered values
- **Optional context filter** — empty in v1 (locked direction for v2 context-specific macros)
- **Pin location** — Launcher only (default) or pinned to a specific keybar slot

### Macro library

The Launcher's full macro list is the authoritative library. Pinning a macro to a keybar slot creates a *reference* — editing the macro in the launcher updates everywhere it's used. Unpinning from the keybar does not delete the macro (still lives in the launcher).

## Reverse-bar option

A global toggle to mirror the keybar layout for left-thumb users or just preference. Single setting:

**Settings → Keybar → Layout direction: [Locked-left] / [Locked-right]**

When set to **Locked-right**:
- The locked region renders on the right side of the bar.
- The scroll region renders to the left of it (pans the opposite direction; defaults are leftward, panning reveals further left).
- The scroll-fade indicator moves to the left edge.
- The Esc pill, if positioned first in the locked region, ends up at the **far-right of the bar** — still the "menu entry" anchor, just on the opposite edge.

Implementation note: this is a layout-mirror only. No separate gesture logic. The Esc pill's swipe-left / swipe-right still mean previous / next window (no semantic mirroring; the gestures are about navigation direction in the windows-list, not about screen direction).

## Gesture-ownership rules

The keybar contains multiple gesture surfaces that can compete for touch events. The rule across all of them:

**Gesture ownership is decided at touch-down location, not at touch-move position.**

This is the standard iOS UIKit gesture-recognizer hierarchy:

- Touch starts within Esc pill or Pad bounds → that widget's gesture recognizers claim the touch. Pan recognizer for the scroll region does not engage, even if the finger subsequently moves across other slots or across the scroll region.
- Touch starts in the scroll region or on a regular slot → pan recognizer engages on horizontal motion. Even if the finger drifts across Esc/Pad widget bounds during the pan, those widgets' recognizers do not fire.
- Touch starts on a regular slot (tap-only or with vertical-swipe bindings) → the slot's recognizers handle vertical motion; horizontal motion above a small threshold transfers to pan (this is the same "vertical-motion-stays-with-child" iOS pattern that scroll views already use).

In practice: **to pan, touch the scroll region or a regular slot and move horizontally. To use a special-widget gesture, touch within the widget.** No ambiguity.

Optional polish: during a live pan, slightly dim the Esc pill and Pad slots to visually indicate they're "out of play" for this gesture. Minor enhancement; can be implemented or deferred.

## Migration / supersession notes

This spec **supersedes** the following previously-locked items. The earlier specs will need housekeeping updates (rolled into the next `sync` task):

1. `2026-06-14-context-detection-design.md`, "Keybar integration → Locked region" — the table listing window pill · pane pill · arrow-pad · Esc is replaced by **Esc pill · Pad · Modifier · Tab**.
2. `2026-06-14-context-detection-design.md`, "Keybar integration → Scrollable region" — the order list (Ctrl/Alt/Shift, Tab, promotions, defaults) is updated: Modifier and Tab are now in the locked region by default; scroll region defaults to "promotions area · defaults · Fn."
3. `brainstorming-decisions.md` "Window switching" table — "single pill in the keybar" is replaced by "Esc pill (fused) with horizontal-swipe window prev/next and swipe-up quick picker." The terminal-area swipe path is unchanged.
4. `brainstorming-decisions.md` "Pane management" table — "second pill in the keybar" is replaced by "Pad (fused with arrows) with tap=zoom, long-press=pane mode, long-press+swipe=split." The pane-focus behavior (tap inactive pane = focus) is unchanged.
5. `brainstorming-decisions.md` "Keybar" table — "Three actions per slot, long-press = edit the slot" — long-press is no longer reserved for edit on user-created custom slots. Edit moves to Settings → Keybar. (The three-actions-per-slot pattern still holds for regular default symbols where long-press isn't bound — they fall back to "no action.")
6. `brainstorming-decisions.md` "Host management & settings access" — "Long-press Esc slot" is now "Long-press Esc pill" (cosmetic update; behavior unchanged).
7. `mockups/specs/keybar.html` — the rendered iPhone frame shows the old v0 layout. Mockup should be regenerated to match the new locked-left composition; treat as a v1 mockup refresh.

## Open / deferred

- **Horizontal-swipe bindings on user-created slots** — deferred to v1.5+ pending real usage data.
- **iPad keybar adaptation** — the locked-region constraint and customization model carry forward conceptually, but iPad's horizontal real estate may justify a different default and possibly two locked regions (one each side). Separate spec.
- **Telemetry-driven default tuning** — once predictor telemetry exists, revisit which slots ship as defaults. Locked direction; not in this spec.
- **Slot-level "owns its bounds" opt-in for custom slots** — the mechanism exists conceptually (matches how Esc pill and Pad work); not exposed to user customization in v1.
- **Per-host keybar overrides** — global keybar config in v1; per-host customization deferred (already locked direction in host-config-model).
- **Quick in-place slot edit shortcut** — long-press-to-edit was removed in this spec. If post-launch usage shows demand for an in-place edit shortcut, candidates: two-finger long-press, an explicit edit mode toggle in Settings → Keybar.

## Acceptance summary

The user experience this spec defines:

- The default keybar's locked-left region is **Esc · Pad · Modifier · Tab**. Esc and Pad are the only constrained widgets.
- Esc pill is the single top-level handle to windows, hosts, and settings via tap-Esc / horizontal-swipe-windows / swipe-up-quick-picker / swipe-down-new-window / long-press-unified-picker.
- Pad combines arrow input (drag) with pane management (tap-zoom, long-press to arm + swipe for splits).
- Almost every other slot is reorderable, removable, and movable between locked / scroll regions via a single Settings → Keybar editor.
- Users can create their own slots with up to four bindable gestures (tap, swipe-up, swipe-down, long-press), each bound to a macro.
- Macros are created either by recording a live sequence or by typing a template with inline modifier chords.
- Left-handed users (or anyone who prefers) can flip the entire bar with a single Settings toggle.
- Gesture ownership is unambiguous: special widgets own their bounds at touch-down; everything else respects pan.
