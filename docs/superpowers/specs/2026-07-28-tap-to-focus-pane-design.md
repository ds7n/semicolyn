<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Tap-to-focus-pane (coexisting with tap-to-place-cursor)

**Status:** Design approved 2026-07-28. Ready for implementation plan.

## Problem

In a multi-pane tmux `-CC` window there is no touch gesture to switch which pane
is focused. `TmuxCommand.selectPane(target:)` exists but is called from no
gesture; focus can only move via ⌘-arrow / the keybar (`selectPaneRelative`).
Tapping an inactive pane does nothing useful today: `handleSingleTap` either
places a text cursor in the *already-active* pane (`.localScroll`) or yields
entirely (`.appOwnsInput` / `.mouseReporting`). Device report (2026-07-28):
"long-press zooms (good), but tapping doesn't switch panes."

This was always the intended behavior. `docs/brainstorming-decisions.md`:
- line 92: "**Tap inactive pane** in terminal area = focus moves. Tap is consumed
  by focus-switch; not sent to remote as click."
- line 127: "**Single-tap-to-place-cursor is KEPT**."

The two were designed to coexist; the focus-switch half was simply never wired.

## Core model

The two behaviors never compete on the same tap. They are disambiguated by
*which pane received the tap*, not by gesture type:

```
single tap on a pane
        │
        ▼
  is this the ACTIVE pane?
   │                    │
   NO                   YES
   │                    │
   ▼                    ▼
 FOCUS it          existing mode action (UNCHANGED):
 (select-pane)      • .localScroll   → place cursor / clear selection
 consume tap        • .appOwnsInput  → yield
 (nothing sent)     • .mouseReporting → forward SGR mouse (SwiftTerm)
```

Decisions (locked with the user):

1. **Always focus first.** A tap on an inactive pane focuses it in *every* mode,
   including `.appOwnsInput` (Claude/vim/htop) and `.mouseReporting` (`mouse=a`).
   The focus-switch is a semicolyn-level action, consumed locally; nothing is
   forwarded to the remote.
2. **Focus only, then act (two-step).** The inactive-pane tap is spent focusing.
   To place a cursor (shell) or forward a mouse click (`mouse=a`) in that pane,
   the user taps again, now it is the active pane and the existing mode action
   runs. Matches iTerm2 / desktop-tmux / tiling-WM convention; mode-uniform.
3. **Optimistic local focus.** On tap, move the accent border + first responder
   locally *before* the `select-pane` round-trip, so focus feels instant on a
   laggy link. tmux's echoed layout confirms it authoritatively.

Single-pane windows have no inactive pane → zero behavior change there.

## Components

### 1. Pure decider (SemicolynKit, Linux-tested)

New pure function mirroring the `tmuxLaunchDecision` pattern, the single source
of truth for what a pane tap does. It *composes* the existing
`TapAction`/`tapAction(hasSelection:)` decider (cases `.placeCursor` /
`.clearSelection`) rather than re-declaring those cases:

```swift
public enum PaneTapAction: Equatable, Sendable {
    case focusPane            // inactive pane → select-pane, consume tap
    case active(TapAction)    // active + .localScroll → .placeCursor / .clearSelection
    case yield                // active + .appOwnsInput / .mouseReporting
}

public func paneTapAction(isActivePane: Bool,
                          mode: InteractionMode,
                          hasSelection: Bool) -> PaneTapAction
```

Rules, in order:
1. `!isActivePane` → `.focusPane` (regardless of mode).
2. active + `.localScroll` → `.active(tapAction(hasSelection:))` (delegates to the
   existing decider).
3. active + `.appOwnsInput` / `.mouseReporting` → `.yield`.

This makes `paneTapAction` the single tested entry point for all single-tap
routing while reusing the existing `TapAction` logic. Existing symbols confirmed
present: `InteractionMode` (cases `localScroll` / `appOwnsInput` /
`mouseReporting`) and `tapAction(hasSelection:) -> TapAction`.

### 2. Gesture controller wiring (App, macOS-CI)

`TerminalGestureController` gains one new callback, alongside the existing
`currentMode` / `isMultiWindowTmux` / `applicationCursorKeys` closures:

```swift
let isActivePane: () -> Bool     // rect.pane == window.activePane
let onSelectPane: () -> Void     // focus THIS pane (optimistic + select-pane)
```

`handleSingleTap` keeps its always-raise-keyboard line, then routes through the
pure decider:

```swift
if !view.isFirstResponder { view.becomeFirstResponder() }   // unchanged
switch paneTapAction(isActivePane: callbacks.isActivePane(),
                     mode: callbacks.currentMode(),
                     hasSelection: callbacks.hasSelection()) {
case .focusPane:            callbacks.onSelectPane(); log("gesture:singleTap action=focus-pane")
case .active(.placeCursor): /* existing cell(at:) + onPlaceCursor */
case .active(.clearSelection): /* existing clearSelection */
case .yield:                /* existing appOwns log + return */
}
```

No other handler changes. Double/triple-tap keep their `.localScroll`-only guard,
so a focus tap can never be misread as word/line-select.

### 3. Optimistic focus (App, macOS-CI)

`TmuxPaneContainer` wires `onSelectPane` for each pane to:

1. Set `pendingActivePane = pane` (new `PaneID?` field on the container).
2. Immediately apply the active-pane chrome locally: move the 1.5pt accent
   border to `pane`, drop the previous active pane to the 0.5pt inactive border,
   and `becomeFirstResponder()` on `pane`'s view. (Reuses the exact border logic
   already in `apply()` at lines ~975-993; factor it into a small
   `applyActiveBorder(active:in:)` helper so both the optimistic path and
   `apply()` call it.)
3. Send `TmuxCommand.selectPane(target: pane)` via the runtime.

When tmux echoes the layout, `apply()` re-keys `window.activePane` and calls the
same border helper, normally a confirming no-op. `pendingActivePane` is a pure
visual pre-empt, never the source of truth: it is cleared/superseded on the next
`apply()`. If the server-side switch ever fails, the next authoritative layout
restores the correct border. `activePane` in `TmuxRuntime` remains
server-derived; the optimistic hint lives only in the container's view layer.

## Edge cases

| Case | Behavior |
|---|---|
| Zoomed pane (long-press zoom active) | Only one pane visible → it is active → tap = normal mode action. No focus-switch needed. |
| Mouse-mode (`mouse=a`) inactive pane | Focuses first ("always focus"). The *second* tap forwards SGR mouse. |
| Tap on a divider | Resolves to whichever pane frame contains the point (existing `paneRects` hit-testing). No special-casing. |
| Rapid double-tap on inactive pane | First tap focuses; double-tap word-select requires `.localScroll` + active, so it does not mis-fire. |
| Single-pane window | No inactive pane; `paneTapAction` never returns `.focusPane`; zero change. |
| Focus tap while a selection is active in the OTHER pane | `.focusPane` wins (inactive target); selection in the old pane is left as-is (per-pane selection scope, decisions line 148). |

## Non-goals

- No new focus-feedback UI, the accent border + corner index badge already
  exist and follow `window.activePane`.
- No drag-to-focus; no change to ⌘-arrow / keybar focus paths
  (`selectPaneRelative`).
- No selection changes. The "selection has no visual feedback under tmux" item
  (device observation #2, 2026-07-28) is separate and gated on
  `.appOwnsInput` by design; it is out of scope here.

## Testing

- **Kit (Linux, XCTest):** `paneTapAction`, equivalence partitions over
  (isActivePane × mode ∈ {localScroll, appOwnsInput, mouseReporting} ×
  hasSelection), boundary on the active/inactive split. Assert the exact
  `PaneTapAction` for each cell (no tautologies). Include the negative that an
  inactive pane in `.localScroll` returns `.focusPane`, NOT `.placeCursor`
  (the regression this feature fixes).
- **App (macOS-CI):** compile-validated wiring, `isActivePane`/`onSelectPane`
  closures, the factored `applyActiveBorder` helper, `pendingActivePane`
  plumbing. Interaction verified on device (tap inactive pane → border moves
  instantly → tmux confirms; tap active shell pane → cursor still places).

## Files touched

- `Sources/SemicolynKit/Terminal/PaneTapAction.swift` (new pure decider)
- `Tests/SemicolynKitTests/PaneTapActionTests.swift` (new)
- `App/TerminalGestureController.swift` (route `handleSingleTap` through the
  decider; add `isActivePane`/`onSelectPane` callbacks; absorb `tapAction`)
- `App/TmuxPaneContainer.swift` (wire the two callbacks; `pendingActivePane` +
  `applyActiveBorder` helper factored out of `apply()`)

Small, contained; no structural change.
