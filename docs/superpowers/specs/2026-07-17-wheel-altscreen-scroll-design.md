<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# SGR mouse-wheel alt-screen scroll (Blink-validated) — design

**Date:** 2026-07-17
**Status:** approved (brainstorm), ready for implementation plan
**Supersedes the scroll mechanism of:** `2026-07-15-app-aware-altscreen-scroll-design.md` (the
arrows/pageKeys per-app fork). That design's registry + decision plumbing is retained and
repurposed as the FALLBACK path here.

## Problem

Dragging to scroll a full-screen app on the alternate screen has never felt right:

- **AI-CLIs (Claude/Gemini/Codex/Qwen):** we send PgUp/PgDn. Device-measured, Claude scrolls
  ~HALF the visible screen per PgUp, and that amount is **Claude's own internal, non-configurable
  behavior** (Ink has no scroll primitive; Anthropic's docs confirm PgUp = half-viewport with no
  setting to change it). Sending more PgUps = jumpy multi-half-screen leaps.
- **True 1-line scroll for Claude via keys is documented-impossible in our setup:** Claude's
  line-scroll (mouse wheel / transcript j-k) requires its "fullscreen rendering" mode, which
  Anthropic explicitly documents as **incompatible with `tmux -CC`** (our architecture): *"the
  mouse wheel does nothing... Don't enable fullscreen rendering in `tmux -CC` sessions."*

## The Blink insight (what actually works)

A user scrolls Claude ONE LINE AT A TIME in Blink Shell. Investigation (device + hterm source +
tmux source) pinned the mechanism:

- Blink runs **plain tmux** (NOT `-CC`) with **`mouse on`**. Claude IS on the alt screen there
  (`tmux display-message -p '#{alternate_on}'` → `1`, device-confirmed).
- On a two-finger scroll, hterm/tmux forward **SGR mouse-wheel events** to the pane. tmux's
  default `WheelUpPane` binding, on the alt screen with mouse on, forwards the wheel event raw to
  the app (`key-bindings.c`: `if alternate_on … send -M`).
- **Claude honors mouse-wheel events and scrolls ~1 line per event.** hterm emits ~1 event per
  line-height of finger travel (`deltaToArrows`/`smartFloorDivide`: `cells = floor(pixels /
  charHeight)`), so a slow drag = crisp 1-line scroll.

The Anthropic "-CC incompatible" note is specifically about the **native-split-renderer** case
(iTerm2 / us). It does NOT mean Claude ignores wheel bytes: in plain tmux Claude scrolls fine on
wheel. So the lever is **SGR mouse-wheel events**, and Claude honors them ~1 line each.

## Approach

Replace the arrows/pageKeys fork with a single **universal wheel emitter**: on an alt-screen drag,
synthesize SGR mouse-wheel events, one per line-height of finger travel, for EVERY alt-screen app.
This is wholistic (no per-app registry for the scroll path), 1-line-granular, and is exactly the
mechanism Blink proved works for Claude. Keep the old arrows/pageKeys behavior as a user-selectable
**fallback**, in case our `tmux -CC` native-split rendering drops the synthetic wheel bytes before
they reach the app (the one unknown, confirmable only on device).

### The open risk (device-confirmable only)

We render tmux panes as native splits under `-CC`. Whether a synthetic SGR wheel event we send via
our byte path actually reaches the app and scrolls it under `-CC` is **unverified until we ship and
test**. The fallback toggle exists precisely so a failed wheel path is recoverable on-device without
a new build. The `drag-move` log line carries the emitted bytes/coords so the device trace confirms
what we sent.

## Section 1 — The wheel scroll mechanism (Kit)

Add to `Sources/SemicolynKit/Terminal/AltScreenScroll.swift`:

```swift
/// Turn an in-progress alt-screen vertical drag into SGR mouse-wheel event runs (the Blink
/// model). Mirrors `arrows(...)`: threads the running `emittedCells` so successive samples
/// emit only the NEW delta, clamps a fast flick to `maxCellsPerEmit`, gain 1.0 (one
/// line-height of travel = one wheel event ≈ one line in the app). Convention matches arrows:
/// finger DOWN (+Δy) = wheel-UP (scroll back). `col`/`row` are the 1-based cell coordinate the
/// event is stamped with (the drag point, clamped to the pane).
public static func wheelEvents(totalDy: Double,
                              cellHeight: Double,
                              emittedCells: Int,
                              col: Int,
                              row: Int) -> (runs: [WheelRun], newEmittedCells: Int)
```

- `WheelRun` (new): `struct WheelRun: Equatable, Sendable { let direction: WheelDirection; let count: Int; let col: Int; let row: Int }`, `enum WheelDirection { case up, down }`.
- Gain for wheel is a fixed **1.0** (position-tracking; NOT the `scrollGain` used by arrows). One
  line-height → one wheel event. Rationale: Claude/less/vim each scroll ~1 line per wheel event, so
  1 event per line-height makes content track the finger 1:1.
- Reuse the existing incremental-delta + `maxCellsPerEmit` accounting from `arrows(...)` (factor the
  shared "signed cell delta since last emit, clamped" math into a private helper so `arrows` and
  `wheelEvents` share it and can't drift).

Add the byte encoder (Kit, pure, tested like `encodePageKeyRun`):

```swift
/// SGR mouse-wheel bytes for a run: `ESC [ < Cb ; col ; row M` repeated `count` times, where
/// Cb = 64 (up) or 65 (down). Press-only (SGR wheel sends no release). col/row 1-based.
public func encodeWheelRun(_ run: WheelRun) -> [UInt8]
```

`AltScrollKeys` gains a case: `public enum AltScrollKeys: Sendable, Equatable { case arrows, pageKeys, wheel }`.

## Section 2 — Mode model & registry (Kit + App)

Collapse `AltScrollMode` from four cases to two:

```swift
public enum AltScrollMode: String, Sendable, CaseIterable, Codable {
    case wheel           // synthesize SGR mouse-wheel events for every alt-screen app [DEFAULT]
    case pageKeysArrows  // FALLBACK: per-app registry — arrows (less/vim) vs PgUp/PgDn (AI-CLIs)
}
```

- **`altScrollDecision(...)`** in `.wheel` mode returns `keys=.wheel, reason="wheel"` for ANY app
  (no registry lookup). In `.pageKeysArrows` mode it runs the OLD registry logic (this is the
  retained `2026-07-15` behavior: `registry.wantsPageKeys(command:)` → `.pageKeys` else `.arrows`).
  `AltScrollDecision.logLine` unchanged — a Claude drag in wheel mode logs
  `mode=wheel app=claude → keys=wheel reason=wheel`.
- **`AltScrollRegistry`** (`{claude,gemini,codex,qwen}`) is RETAINED, consulted ONLY in
  `.pageKeysArrows`. Not deleted — it is the fallback's brain.
- **Migration:** any legacy persisted `altScrollMode` raw string (`off`/`auto`/`alwaysPageKeys`/
  `autoPlusTitle`) decodes to `.wheel` (the new default). Pre-release (TestFlight only), so no
  back-compat burden; a clean remap to the new default is correct.

## Section 3 — App wiring (gesture controller + encoders)

`App/TerminalGestureController.swift`, `handleAltScreenPan` `.changed`:

- Compute the drag point in cell coords once: `col = clamp(1...cols, Int(loc.x / cellW) + 1)`,
  `row = clamp(1...rows, Int(loc.y / cellH) + 1)` (SGR coords 1-based), from the existing
  `view.bounds` / `term.cols`,`term.rows` metrics.
- Branch on `dragDecision.keys`:
  - `.wheel` → `AltScreenScroll.wheelEvents(totalDy:cellHeight:emittedCells:col:row:)`; encode each
    run via `encodeWheelRun`.
  - `.arrows` / `.pageKeys` → the EXISTING `arrows(...)` + `encodeArrowRun`/`encodePageKeyRun`
    (fallback path, unchanged).
- Emit via `callbacks.sendBytes(...)` (same path as arrows today — our own synthesis, NOT SwiftTerm
  mouse forwarding, so the `.appOwnsInput` mouse-gate does not block it).
- The self-contained `drag-move` line gains the encoding + coordinate for the device trace:
  `drag-move keys=wheel runs=N sent=n total=… coord=(col,row)`.

No mount changes (`TmuxPaneContainer`/`TerminalScreen` already supply `altScrollDecision`; the
decider's new default flows through).

## Section 4 — Experimental settings UI

`App/ExperimentalSettingsView.swift` alt-scroll `Picker` collapses to two rows (keeps the shipped
`.labelsHidden()` + label-not-tappable-header fix and the `user-action: mode-switch` `.lifecycle`
log):

- **"Line scroll (mouse wheel)"** → `.wheel` (default).
  Footer: *"Scrolls full-screen apps (Claude, vim, less) one line at a time by sending mouse-wheel
  events, like Blink. If an app doesn't respond, use the fallback."*
- **"Fallback (Page/arrow keys)"** → `.pageKeysArrows`.
  Footer: *"Older method: arrow keys for less/vim, PgUp/PgDn for AI CLIs. Use if wheel scrolling
  doesn't work in your setup."*

## Testing

Kit (Linux, real correctness):

- **`wheelEvents(...)`** — EP over {registered/unregistered/nil are N/A here — it's app-agnostic};
  BVA on drag distance: sub-line-height → no event; exactly one line-height → one event; N
  line-heights → N events; direction (finger down → wheel-up); incremental (second sample emits only
  the new delta, no double count); huge flick → clamped to `maxCellsPerEmit`; zero/negative
  `cellHeight` → no events (fail closed). Assert exact `WheelRun`s (direction, count, col, row).
- **`encodeWheelRun`** — exact bytes: up `ESC[<64;C;RM` = `1b 5b 3c 36 34 3b … 4d`; down `Cb=65`;
  `count` repetition; a swap-detecting assertion (up ≠ down bytes). Coordinate rendering (multi-digit
  col/row).
- **`altScrollDecision`** — in `.wheel`: any app (`claude`, `bash`, `nil`) → `keys=.wheel
  reason="wheel"`. In `.pageKeysArrows`: the retained registry cases (claude→pageKeys,
  bash→arrows, nil→arrows). Wrapper `altScrollKeys(...)` round-trip unchanged.
- **`altScrollKeys` wrapper** — still equals `altScrollDecision(...).keys` for every mode.
- **Migration** — a `TerminalSettings` JSON blob with `altScrollMode:"auto"` (legacy) decodes to
  `.wheel` AND preserves the other 5 fields at non-default values (mirrors the existing
  anti-regression test pattern). Mutation-guard: fails if the remap is dropped.

App tier (macOS-CI compile gate + device):

- Gesture-controller branch, coordinate math, `drag-move` logging — not Linux-buildable; validated
  by macOS CI compile + the device retest (which is the whole point: does wheel reach Claude under
  `-CC`).

## Deliverables

1. `AltScreenScroll.swift`: `WheelRun`/`WheelDirection`, `wheelEvents(...)`, shared delta helper (Kit).
2. `encodeWheelRun(_:)` byte encoder (Kit).
3. `AltScrollKeys.wheel` case; `AltScrollMode` → `{wheel, pageKeysArrows}`; `altScrollDecision`
   wheel-default + retained-registry-fallback (Kit).
4. `TerminalSettings` migration (legacy mode → `.wheel`) + anti-regression test (Kit).
5. `TerminalGestureController`: wheel branch + coord math + `drag-move coord=` logging (App).
6. `ExperimentalSettingsView`: two-row picker + footers (App).
7. Kit tests per the Testing section.
8. Retest note (TODO): enable Gesture logging; drag Claude → expect `drag-move keys=wheel`,
   transcript scrolls ~1 line per line-height; if it does NOT scroll, flip to Fallback and confirm
   PgUp still works (isolates whether `-CC` forwards wheel).

## Implementation note (for the plan)

Collapsing `AltScrollMode` from 4 cases to 2 is source-breaking for every exhaustive `switch`
over it (the decider, any settings mapping, tests). The plan must sweep all `AltScrollMode`
references (`grep -rn AltScrollMode`) and update each: the decider (rewritten per §2), the
settings picker (§4), and the existing `AltScrollDeciderTests`/`Settings` tests (rewritten to the
2-case model). The legacy `.off/.auto/.alwaysPageKeys/.autoPlusTitle` cases and any test asserting
them are removed; the retained per-app behavior now lives under `.pageKeysArrows`.

## Non-goals

- Local scrollback buffer (the iTerm2 `%output`-ring model). That remains the separate, larger
  `tmux-cc-scrollback-architecture` project; this wheel approach is the lighter fix that may fully
  solve it. If the device test shows `-CC` drops wheel bytes, the buffer project is the fallback plan.
- No velocity/momentum/inertia engine (the position-tracking wheel-per-line-height IS the "rate
  follows finger" feel, derived from distance, so it never floats).
- No change to the horizontal window-switch gesture (that's a separate follow-up).
