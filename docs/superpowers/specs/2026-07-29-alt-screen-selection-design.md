<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Alt-screen text selection

**Status:** Design approved 2026-07-29. Ready for implementation plan.

## Problem

Double/triple-tap text selection does not work inside a full-screen app
(Claude / vim / htop) running under tmux `-CC`. Device report (2026-07-29):
tapping to select "still isn't working." Selection IS a must-have.

Root cause (investigated, not assumed): PR #102 (commit `b83e404`)
deliberately added a `guard callbacks.currentMode() == .localScroll` to
`handleDoubleTap` / `handleTripleTap`, so on the alternate screen
(`.appOwnsInput`) and mouse-reporting panes (`.mouseReporting`) the gesture
yields instead of selecting. It was gated off because on device (build 55) it
drew a "garbage bottom row" selection: the tap mapped to the wrong row.

Since #102, the tap->cell path and pane geometry were reworked:
- `TapRowMapping` (Kit-tested) maps a content-space tap Y to the correct
  viewport row, subtracting `contentOffset` and NOT double-counting `yDisp`.
- Pane frames now fit the FULL `bounds.height` (the keybar-gap arc, PRs
  #108-111), so `cellH = bounds.height / rows` is no longer corrupted by a
  keybar-height band.

A code investigation concluded the garbage-row cause is **likely resolved**
as a side effect of that rework, but the fix is accidental: nothing durably
exercises the full tap->cell->select path on the alt-screen. Therefore the
change must be **proven on device** before merge, not assumed.

## Locked decisions

1. **Model: local-buffer, iOS-native.** Select against SwiftTerm's local grid
   (which under tmux `-CC` is the currently-visible content), same engine and
   iOS-native highlight + Copy menu as the normal-screen selection. No tmux
   copy-mode, no server-side scrollback, no tmux round-trip. Copy goes to the
   iOS clipboard.
2. **Gestures:** double-tap = word, triple-tap = line, two-finger-tap =
   re-summon Copy menu. The existing set; only the mode gate is removed.
3. **Scope: one screenful.** Selection operates on the row under the finger on
   whatever is currently visible, INCLUDING after scrolling up to earlier
   output (`TapRowMapping` handles the scrolled offset). A single selection is
   bounded to the visible screen. Multi-page selection that grows across scroll
   is DEFERRED.
4. **Both app modes:** enable select in `.appOwnsInput` AND `.mouseReporting`
   (remove the guard entirely). Single-tap / drag still forward as SGR mouse in
   `.mouseReporting`; only the multi-tap select gesture is added there.
5. **Copy: auto edit-menu on select** (unchanged current behavior:
   `presentEditMenu` after `setSelectionRange`).
6. **De-risk: device-proof before merge**, with diagnostic logging. No settings
   toggle / safety fallback.

## Core change (subtractive)

Remove the mode gate so the alt-screen uses the exact same, already-correct
selection path as the normal screen.

In `App/TerminalGestureController.swift`, `handleDoubleTap` and
`handleTripleTap` currently begin:

```swift
guard callbacks.currentMode() == .localScroll else {
    DebugLog.shared.log(.gesture, "gr:doubleTap yield mode=\(callbacks.currentMode())")
    return
}
```

Remove this guard from both handlers. The rest of each handler is unchanged:
`cell(at:)` -> `wordBounds(col:row:)` -> `setSelectionRange(...)` ->
`presentEditMenu(...)`. Word/line select now runs in every mode.

No new selection engine, no tmux interaction, no change to tap-to-focus,
long-press-zoom, single-tap cursor placement, or the normal-screen selection.

## Diagnostic logging (the de-risk)

Add a single decision-style log line to each selection handler (behind the
existing `.gesture` LogCategory) that captures the full tap->chars chain, so a
wrong-row selection is diagnosable from the log rather than guessed:

```
sel:double loc=(x,y) mode=<mode> cell=(col,row) word=(start,end) chars="<selected text>"
sel:triple loc=(x,y) mode=<mode> row=<row> chars="<selected text>"
```

The selected characters come from `getCharData(col:row:)` over the resolved
range (privacy note below). This line supersedes the existing
`sel:before hasActive=` / `sel:after set (...)` pair (keep those too if cheap;
the new line is the one that proves correctness). On device, comparing `loc`
to `chars` shows immediately whether the selection matches what was tapped.

Privacy: selection text can contain sensitive content. The `chars` field is
logged ONLY when the `.gesture` category is enabled (diagnostics are
opt-in / off by default, consistent with the predictor's no-key-content rule).
Truncate `chars` to a reasonable cap (e.g. 120 chars). Do not stream it when
diagnostics are off (the line is an `@autoclosure` no-op then, like the rest of
`DebugLog`).

## Testing

- **Kit (Linux):** the word-expansion logic is the one selection piece worth
  pinning. If `wordBounds` can be reasonably separated from the SwiftTerm view,
  extract the character-run expansion into a pure helper
  `wordBounds(isWordChar:col:cols:) -> (start, end)` (or a variant taking a row
  of chars) and cover it with EP + BVA: mid-word (expands both directions),
  word at column 0 (clamps left), word at last column (clamps right), tap on
  whitespace (empty/degenerate selection), single-char word, all-whitespace
  row. `TapRowMapping` is already Kit-tested and unchanged. If extraction is too
  invasive for this pass, note it in the plan and rely on the device-proof; do
  not fake a test that needs the view.
- **App (macOS CI):** guard removal + the log line compile-validated.
- **Device (TestFlight) - the gating check, owed before squash-merge:** in a
  Claude pane, double-tap selects the correct visible word and triple-tap the
  correct line; the iOS Copy menu appears and copies the right text to the
  clipboard; it also works after scrolling up to earlier output; long-press
  still zooms and tap-to-focus still works. Capture the `sel:double`/`sel:triple`
  lines (syslog-sink up, TLS/TCP). If any selection is wrong, the log's
  loc->chars mismatch pinpoints the residual coordinate bug; root-cause THAT
  before merging (no blind retry).

## Non-goals

- tmux copy-mode / server-side scrollback selection.
- Multi-page selection that grows across scroll.
- Drag-to-extend / selection handles (stays deferred in TODO).
- Any change to tap-to-focus (#112), long-press-zoom, single-tap cursor
  placement, or the working normal-screen selection.
- No settings toggle or auto-disable fallback.

## Files touched

- `App/TerminalGestureController.swift` (remove the two guards; add the two
  diagnostic log lines; possibly call an extracted pure `wordBounds` helper)
- `Sources/SemicolynKit/Terminal/WordBounds.swift` (new, IF extraction is done)
- `Tests/SemicolynKitTests/WordBoundsTests.swift` (new, IF extraction is done)

Small, subtractive; the risk is concentrated in the device-verification step.
