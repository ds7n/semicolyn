<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Terminal interaction-mode redesign — design

**Status:** design approved 2026-07-12, ready for implementation planning.
**Supersedes the *how*, keeps the *what*:** the usability intent (tap=place, vertical
drag=scroll, clear-horizontal swipe=switch window, double/triple-tap=select, long-press=zoom)
is unchanged. This spec replaces the *implementation* of the terminal touch layer, which has
failed 4 times by accidentally straddling SwiftTerm's own recognizers.

**Inputs that produced this design:**
- `docs/superpowers/topics/2026-07-12-gesture-scroll-redesign-findings.md` (the stock-take:
  defect A = one boolean expressing 3+ modes; defect B = per-gesture re-sampling; the 4-reversal
  timeline; "decide the SwiftTerm relationship deliberately").
- `docs/superpowers/topics/2026-07-12-alt-screen-interaction-model.md` (the alt-screen
  two-mode model + drag→arrows reference — xterm Alternate-Scroll `DECSET ?1007`, xterm.js #1007).
- Project memory `tmux-cc-scrollback-architecture` (capture-pane seed → local SwiftTerm scroll →
  re-seed on `%pause`; alt-screen-gated forwarding — the scrollback model this connects to).

## 1. Problem & guiding rules

The terminal touch layer has oscillated between "own the gesture with a custom controller" and
"delegate to SwiftTerm's native recognizers," reverting 4 times. Root cause: a single boolean
(`allowMouseReporting = mouseMode != .off && isCurrentBufferAlternate`), **re-sampled per
gesture**, tries to express at least three distinct interaction modes, and a custom pan rides as
a passenger on SwiftTerm's inherited `UIScrollView` pan (whose scrollback-sync only fires while
*its own* pan is tracking). The straddle is the bug.

Three rules govern the redesign (from the user, 2026-07-12):

1. **Use native/built-in behavior as much as possible.** Do not reinvent scroll, inertia,
   selection. On the alternate screen the *native/standard* behavior is to translate the gesture
   into arrow keys sent to the app (xterm Alternate-Scroll) — so honoring rule 1 there *requires*
   drag→arrows; forwarding the raw drag as mouse (today's behavior) is the non-standard thing.
2. **Preserve the status quo.** Do not make the user learn behavior counter to what they expect.
   The normal-screen experience is unchanged; the alt-screen change (drag→arrows) *restores*
   expected/standard behavior (Blink already does this), it does not invent novel behavior.
3. **Generic, not per-app.** The design keys off *terminal state* (`isCurrentBufferAlternate`,
   `mouseMode`), never off "this is Claude Code." Claude Code is one member of the
   alt-screen-with-mouse class; the design handles the class automatically.

## 2. Decision: mode-switched hybrid (SwiftTerm relationship)

Three candidates were weighed (from the findings doc). **Chosen: mode-switched hybrid.**

- **Fully delegate to SwiftTerm + add-ons** — REJECTED. Gives no seam to translate an alt-screen
  drag into arrows, so Claude/vim panes stay dead (the current bug). Fails rule 3.
- **Fully own the touch layer** — REJECTED. Reinvents SwiftTerm's scroll inertia + internal
  scrollback-sync (`syncYDispFromContentOffset`, gated on `isTracking`). Violates rule 1 and is
  the approach that already lost in `#62` and `#76`.
- **Mode-switched hybrid** — CHOSEN. The *right native mechanism owns the drag, chosen by
  terminal state.* Normal-screen keeps SwiftTerm's native scroll (status quo, rule 2); alt-screen
  we translate the drag to the app's native scroll = arrow keys (rules 1 + 3). **Exactly one
  recognizer is live on the drag per mode** — the straddle is eliminated by construction, not by
  tuning.

### Why the hybrid's foundation is sound (an adversarial critique was run and refuted)

A fresh-context adversarial review claimed the hybrid's core premise ("track mode as state,
updated on transition, not re-sampled") was unachievable because `isCurrentBufferAlternate` /
`mouseMode` are pollable-only. **This is false**, verified against SwiftTerm source:

- `TerminalDelegate.bufferActivated(source:)` — *"invoked when the buffer changes from Normal to
  Alternate, or Alternate to Normal"* (fires on `?1049h/l`).
- `TerminalDelegate.mouseModeChanged(source:)` — *"invoked when the mouseMode property has
  changed."*

Both are real emulator-delegate **events** — the fix for defect B is event-driven, not polling.

**Where we hook them (corrected 2026-07-12 by the Task 4 foundation gate).** These two methods
belong to the *emulator* protocol `TerminalDelegate` (`Terminal.swift`), NOT the app-facing
`TerminalViewDelegate` our mount coordinators conform to. SwiftTerm wires the emulator's delegate
slot (`tdel`) to the `TerminalView` **instance itself** (`Terminal(delegate: self, …)`), and it is
not reassignable from app code — so implementing these methods on the coordinator would be dead
code (verified against SwiftTerm `main` + v1.14.0: `TerminalViewDelegate` does not declare either
method; `TerminalView` provides `open func bufferActivated`/`mouseModeChanged` doing internal-only
work with no forwarding). **SwiftTerm's intended extension point is to subclass `TerminalView` and
override those `open` methods.** So the hook is a thin `final class PaneTerminalView: TerminalView`
that overrides both, calls `super` first (preserving SwiftTerm's own scroller / mouse-pan side
effects), then forwards to the pane's `PaneModeTracker.recompute(...)`. Both mounts already
construct `TerminalView(frame:)` at a single site each and type their pane registries as
`TerminalView`, so substituting the subclass is a contained change.

The critique's remaining findings were valid and are folded into this design (see §6).

## 3. The interaction-mode model (foundation)

Replace the single `allowMouseReporting` boolean with a first-class, named mode, **tracked as
state and updated by delegate events, never re-sampled per gesture.**

Pure, Kit, Linux-tested (`Sources/SemicolynKit/Terminal/InteractionMode.swift`):

```swift
public enum InteractionMode: Equatable, Sendable {
    case localScroll     // normal screen, no mouse — SwiftTerm owns the drag
    case appOwnsInput    // alternate screen — we translate drag→arrows, tap→mouse
    case mouseReporting  // normal screen + app enabled mouse — forward to app
}

/// Alt-screen takes precedence over mouse-mode: an alt-screen app with mouse on
/// (Claude, vim+mouse, htop) resolves to `.appOwnsInput`, where drag→arrows and
/// tap→mouse both apply.
public func resolveMode(isAltScreen: Bool, mouseReporting: Bool) -> InteractionMode {
    if isAltScreen { return .appOwnsInput }
    if mouseReporting { return .mouseReporting }
    return .localScroll
}
```

This one pure function is the **single source of truth**, called from both mount sites and the
controller — killing the duplicated derivation and satisfying rule 3.

**Mode updates via events, not polling (fixes defect B):** the `PaneTerminalView` subclass (see
§2.1) overrides `bufferActivated(source:)` and `mouseModeChanged(source:)`; each override
`super`-calls, then invokes `PaneModeTracker.recompute(...)` for that pane. The tracker recomputes
`resolveMode(...)`, stores it, and (on a real transition) pushes it to that pane's gesture
controller and mouse-dot. The render-time polling in `updateMouseDots` / `updateMouseDot` is
deleted.

**Per-pane storage:** the tmux path holds mode keyed by pane (it already keys views by pane); the
raw-SSH path holds a single mode. The controller reads the *stored* mode for its pane and
**snapshots mode + DECCKM at gesture `.began`**, so a mode flip mid-drag cannot corrupt an
in-flight gesture.

## 4. Per-mode gesture routing (one unambiguous drag-owner per mode)

### Drag ownership

| Mode | Vertical drag | Horizontal swipe (multi-win tmux) | `isScrollEnabled` |
|---|---|---|---|
| `localScroll` | SwiftTerm native pan scrolls (inertia + `syncYDispFromContentOffset` intact) | our window-switch, once on release, via `GestureClassifier` | `true` |
| `appOwnsInput` (alt) | **we own it** → live 1:1 arrows to the app (Δy÷cellH, clamped/frame) | our window-switch (classifier axis-locks it) | `false` |
| `mouseReporting` | SwiftTerm forwards as mouse | our window-switch | `true` |

**Ownership mechanism (fixes the `.isEnabled`-toggle hazard):** flip **`view.isScrollEnabled`** — a
documented `UIScrollView` API — never the inherited `panGestureRecognizer.isEnabled`. In
`appOwnsInput`, `isScrollEnabled = false` makes SwiftTerm's pan inert (no dirty `isTracking`/sync
state); our pan target reads the live drag and emits arrows. On return to `localScroll`,
`isScrollEnabled = true` and native scroll resumes cleanly. **The flip happens in the
mode-transition handler (`bufferActivated`), not per-gesture.**

### Tap / selection routing

| Gesture | `localScroll` | `appOwnsInput` (alt) | `mouseReporting` |
|---|---|---|---|
| single-tap | place cursor / clear selection | **forward as mouse** if app requested; else no-op | forward as mouse |
| double/triple-tap | word/line select (local) | **word/line select (local)** — Blink/iTerm2 parity | select (local) |
| long-press | zoom pane | zoom pane | zoom pane |
| two-finger tap | edit menu | edit menu | edit menu |

Today's controller gates *everything* on one `mouseReportingActive()` bool — which is why
alt-screen taps silently die. The redesign routes drag / tap / selection **independently** via a
`switch mode` in each handler. Alt-screen single-tap→mouse and vertical-drag→arrows are now
separate decisions.

### Live arrows during drag

The alt-screen arrow path handles `.began/.changed/.ended` (unlike the window-switch, which
resolves once on `.ended`):
- `.began` → snapshot mode + DECCKM (`applicationCursor`) for the focused pane.
- `.changed` → compute the *incremental* cells crossed since the last emit; send that many arrows
  (DECCKM-honoring via the existing `arrowEvents`/`encodeKey`), **clamped per emit** to prevent
  flooding. No momentum/coasting (deferred).
- `.ended` → stop.

The horizontal window-switch still resolves once on `.ended` from cumulative translation;
`GestureClassifier`'s axis-lock (|dx| ≥ 1.7·|dy| ⇒ switch) keeps the two axes from colliding, on
both normal and alt-screen panes.

## 5. Tier split & components

Per the repo's core rule (pure logic in Kit, Linux-tested; App = thin wiring).

### New / changed Kit units (Linux `swift test`)

| Unit | Responsibility |
|---|---|
| `InteractionMode.swift` *(new)* | The enum + `resolveMode(isAltScreen:mouseReporting:)`. |
| `AltScreenScroll.swift` *(new)* | Pure decider: given cumulative Δy, cellHeight, and last-emitted offset → **incremental arrow count + direction**, clamped to a per-emit max. Owns the "1:1, no momentum, clamped" math *and the clamp constant itself* (a named `static let`, not a magic number in the App tier), so the anti-flood cap is Kit-testable. App does zero arithmetic. |
| `GestureClassifier.swift` *(keep, unchanged)* | Swipe-vs-scroll axis-lock. |
| `CursorTapTarget.swift` / `arrowEvents` *(reuse)* | DECCKM-aware arrow byte encoding — the count from `AltScreenScroll` feeds this encoder. |

### Changed App units (macOS-CI / device only)

| Unit | Change |
|---|---|
| `PaneTerminalView.swift` *(new)* | `final class PaneTerminalView: TerminalView` overriding `open func bufferActivated`/`mouseModeChanged`: `super`-call, then a `onModeRelevantChange: (Terminal) -> Void` closure the mount wires to `PaneModeTracker.recompute`. The event seam SwiftTerm actually delivers to (see §2.1). |
| `TerminalGestureController.swift` | Replace the single `mouseReportingActive()` guard with a `mode: () -> InteractionMode` provider + begin-time snapshot. Handlers `switch` on mode. Add `.changed`-phase arrow emission for `appOwnsInput`. Flip `isScrollEnabled` on transition. Add a byte-send callback for arrows/mouse. |
| `TmuxPaneContainer.swift` | Construct panes as `PaneTerminalView`; wire each view's `onModeRelevantChange` → `modeTracker.recompute(for:terminal:)`; prime once at mount. Delete the render-time mode-polling in `updateMouseDots` (keep only the mouse-dot *visual*, now sourced from the stored mode). |
| `TerminalScreen.swift` | Same, single-pane (`PaneTerminalView` + prime + delete `updateMouseDot` poll). |

### Shared helper (prevents mount-site divergence)

A small App-tier `PaneModeTracker` embedded by both coordinators: holds the per-pane mode,
recomputes via the Kit `resolveMode`, and notifies the controller + mouse-dot. Both mounts call
the same helper; neither reimplements the derivation. The *decision* is Kit-pure; the tracker is
thin state.

**Mouse-dot indicator:** becomes a pure function of the stored mode (show when `appOwnsInput`, or
`mouseReporting` with mouse-on), updated on transition — no user-visible change, just sourced from
the mode instead of a render poll.

## 6. Adversarial-critique findings folded in

| Finding | Resolution in this design |
|---|---|
| Toggling inherited `panGestureRecognizer.isEnabled` leaves scroll-view state dirty | Use `isScrollEnabled` (documented API) instead (§4). |
| DECCKM must come from the right pane at the right time | Snapshot mode + DECCKM at `.began`, focused pane only (§3, §4). |
| Alt-screen single-tap silently no-ops | Split tap from drag; alt-screen tap → mouse-if-requested (§4). |
| Selection on a repainting alt-screen buffer | Kept (Blink/iTerm2 parity), documented as best-effort for a live buffer (§4, §7). |
| Mode derivation duplicated across mounts | One Kit `resolveMode` + one `PaneModeTracker` (§5). |
| Momentum lost / over-send on fast flick | 1:1 no-momentum accepted; per-emit clamp prevents flooding (§4). |

## 7. Edge cases

- **Mode flip mid-drag** → the `.began` snapshot governs the whole gesture; the flip applies to the
  *next* gesture. No mid-gesture corruption.
- **Fast flick** → per-emit clamp bounds arrows/frame (no 40-arrow flood).
- **Single-window tmux on alt-screen** → horizontal swipe has no window to switch, classifies as
  scroll, falls through to arrows. Documented, not a bug.
- **DECCKM toggled during a long drag** → begin-time snapshot wins; encoding stays consistent for
  that gesture (accepted tradeoff).
- **Selection on a live-repainting alt-screen buffer** → best-effort: a quick copy of *visible*
  text works; if the app repaints mid-selection the range can land on stale content (same caveat
  Blink/iTerm2 carry).
- **tmux `%pause`/re-seed** → orthogonal; the mode model does not touch scrollback seeding.
  `localScroll` scrolls whatever SwiftTerm has buffered (seeded per the tmux-cc-scrollback
  architecture); that seeding path is unchanged here.

## 8. Testing

Per `docs/superpowers/specs/2026-06-18-testing-standards-design.md` (EP + BVA, assert observable
values, negative tests assert the *specific* failure).

**Kit (real unit tests, Linux `swift test`):**
- `resolveMode` — EP over all 4 `(isAltScreen, mouseReporting)` combos; assert the exact mode,
  including alt-wins-over-mouse: `(true, true) → .appOwnsInput`.
- `AltScreenScroll` — BVA: Δy = 0 → 0 arrows; sub-cellHeight → 0; exactly 1 cell → 1; N cells → N;
  over the per-emit clamp → clamped (assert the exact cap, not "some"); negative Δy → up not down;
  incremental accounting across successive `.changed` samples (cumulative Δy grows, each emit sends
  only the new delta — no double-count). Adversarial: a huge flick asserts the clamp *caps* output
  (the anti-flood guarantee).
- `GestureClassifier` — already covered; unchanged.

**App (macOS CI + device):**
- Mode transitions fire on `bufferActivated` / `mouseModeChanged` (temp `.gesture` log in a device
  trace: enter Claude → `appOwnsInput`, exit → `localScroll`).
- `isScrollEnabled` flips with mode; native scroll recovers after an alt-screen round-trip.
- `.gesture` diagnostics (Spec B) log `mode` + emitted arrows per drag for the device pass.

## 9. Out of scope (YAGNI / deferred)

- **Momentum / coasting** on alt-screen arrows — ship 1:1; revisit if sluggish on device.
- **tmux capture-pane scrollback seeding redesign** — the separate tmux-cc-scrollback work; this
  spec assumes and connects to it but does not implement it.
- **Inactive-pane gestures** — you gesture on the focused pane; the begin-time snapshot reads it.
- **Arrow-walk cursor placement on alt-screen** — rejected; single-tap → mouse instead.

## 10. Binding prior decisions (unchanged)

- Window-list navigation clamps at the ends (`clampedStepIndex`); `stepIndex` (⌘] / horizontal
  swipe) still wraps.
- Drag-based window switching fires **once per drag, on release**.
- The legacy `CursorDragEngine` stays retired.
