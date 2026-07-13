<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Terminal gesture / scroll / swipe — stock-take & redesign findings

**Written:** 2026-07-12, after TF39 device testing. **Purpose:** capture WHY the gesture/scroll
implementation has failed repeatedly, so a fresh-context brainstorm can design the *how*
correctly instead of patching symptoms again. **The WHAT (usability intent) is fine; the HOW has
been failure after failure.** Keep the usability spec; restart the implementation.

> **Decision (2026-07-12):** stop patching. Do a clean brainstorm → spec → reimplementation of
> the terminal interaction layer, built around an explicit interaction-MODE model that confronts
> the strong-control systems head-on. This doc is the input to that brainstorm.

## The symptom that triggered this (TF39)

- **Normal shell panes: scroll works well.** Swipe-to-switch-window is broken / so sporadic the
  user can't predict when it fires.
- **Claude Code panes: no scroll at all.** (Claude Code = full-screen TUI on the ALTERNATE
  screen with mouse tracking ON.)
- User's own diagnosis (correct): (1) we keep fighting systems with strong control over the
  gesture; (2) everything is "skew anchored to a single moment in time" — if the sampled state
  drifts, we're permanently off; (3) the WHAT is in a good space, the HOW keeps failing.

## Why Claude Code has no scroll (traced through the code)

`App/TmuxPaneContainer.swift:345` (and the twin at `App/TerminalScreen.swift:374`):
```
let forwardMouse = terminal.mouseMode != .off && terminal.isCurrentBufferAlternate
view.allowMouseReporting = forwardMouse
```
Claude Code is on the alternate screen (`isCurrentBufferAlternate == true`) with mouse mode on →
`forwardMouse == true` → `allowMouseReporting = true` → SwiftTerm forwards the finger drag to
Claude as SGR mouse events → our `handleScrollViewPan` yields via the `mouseReportingActive`
guard (`TerminalGestureController.swift:169`) → **no local scroll**, and Claude typically doesn't
scroll on those raw mouse-drag events either. The drag falls into a dead zone. This is
structural, not a tuning miss.

## The failure pattern: 4 reversals, oscillating between two dead-end poles

The same class of bug ("scroll / cursor doesn't work") has been "fixed" at least 4 distinct
times, ping-ponging between "own the gesture with a custom controller" and "delegate to
SwiftTerm's native recognizers." Neither pole works.

| Date | SHA | Approach | Broke because |
|---|---|---|---|
| 2026-07-07 | `97a5ac8` | Build custom `CursorDragController` (tap=place, pan=scrub) | Duplicated + FOUGHT SwiftTerm's own pan |
| 2026-07-07 | `f019765` | Patch: single-pane never set active; suspend on mouseMode | Own controller silently dead in raw path |
| 2026-07-07 | `53aaa69` (#62) | **REVERT** → use SwiftTerm native pan/tap/select, gate via `allowMouseReporting` | Native didn't give window-switch / zoom |
| 2026-07-10 | `1a26446` (#76) | **Build custom AGAIN** (`TerminalGestureController` + pure `GestureClassifier`) | Competing pan; cumulative-vs-delta translation reset stalled scroll |
| 2026-07-10 | `3f2dca3` (#78) | **REVERT AGAIN** → ride TerminalView's native inherited `panGestureRecognizer`, bolt window-switch on as an extra target | Custom `setContentOffset` no-op'd: `syncYDispFromContentOffset` is gated on `isTracking` (true only while the scroll view's OWN pan tracks) |
| 2026-07-12 | `0824642` (#83) | Gate mouse-forward on `isCurrentBufferAlternate` AND `mouseMode` | Binary gate still too coarse (this doc) |
| 2026-07-12 | `92db11c` (#84) | Spec B: `tapAction`, clear-selection-on-tap, RenderSignature dedup | Render storm + tap polish (not the core issue) |
| 2026-07-12 | `e93b769` (#85) | `switchDominanceRatio=1.7`; fix `cell(at:)` double-counting `contentOffset` | **Its own commit calls these "palliative"** |

**Net:** the app layer keeps re-litigating who owns the pan. Custom → fights native → revert →
native can't do what we need → custom again. This loop cannot converge because the actual problem
is elsewhere.

## The three strong-control systems fighting for the same finger-drag

The real issue: **three systems all claim the drag**, and the current design arbitrates them with
essentially one boolean (`allowMouseReporting`), re-sampled per gesture.

1. **SwiftTerm's native `UIScrollView`** — `TerminalView` IS a `UIScrollView`; it scrolls via its
   inherited `panGestureRecognizer`, and its scrollback sync (`syncYDispFromContentOffset`) only
   fires while `isTracking` is true — i.e. only when *its own* pan drives the gesture. Any custom
   pan silently no-ops. Its `calculateTapHit` is `internal`, so we reimplement cell-mapping and
   drift from it. **This beat every DIY attempt.**
2. **tmux mouse-mode / SGR reporting** — a mouse-mode app gets `ESC[?1000h?1002h?1003h?1006h`;
   then every drag becomes `ESC[<32;…M` mouse reports sent to tmux, not scroll (`0824642`).
3. **Alt-screen apps (Claude Code, vim, less, htop)** — switch to the alternate buffer AND enable
   mouse tracking, so they legitimately own the mouse. This is the "no scroll in Claude Code"
   bug, and it's the case the binary gate handles worst.

## The two structural defects (name them so the redesign fixes them)

**A. Binary mouse-gate instead of an explicit mode model.** One boolean
(`allowMouseReporting = mouseMode != .off && isCurrentBufferAlternate`) tries to express at least
three distinct interaction modes:
- **normal-screen, no mouse** → local scrollback scroll + tap-to-place + swipe-to-switch (we own it).
- **alt-screen app owns input** (Claude/vim) → the app wants the drag; local scroll is meaningless
  there, BUT the user still wants *some* way to scroll (xterm's answer: alt-screen drag →
  arrow-key / Alt-Scroll synthesis to the app — see the alt-screen topic doc).
- **normal-screen mouse-mode app** (a shell that turned mouse on) → must NOT steal the drag.
A single bool cannot encode "which mode + who owns the drag + what a scroll gesture should
translate to." The mode must be a first-class, named concept.

**B. State is re-sampled per gesture, never tracked ("skew anchored to one moment").** Every
gesture re-derives everything from whatever SwiftTerm reports at that instant:
`cell(at:)` reads the current grid; the gate reads `isCurrentBufferAlternate` at drag-time; the
window-switch reads cumulative pan translation. There is no continuous, owned model of "current
interaction mode + viewport position." During scroll, app-switches, and buffer flips these
signals are momentarily inconsistent, and nothing re-syncs — so a one-off bad sample becomes a
persistent skew (`cell(at:)`'s old `contentOffset` rounding residue that *grew with scroll
distance* is the canonical example — `e93b769`).

## What the redesign must do (inputs to the brainstorm — NOT the design)

The usability WHAT is settled (keep it): tap = place cursor; single-finger vertical drag = scroll
local scrollback; clear-horizontal drag (multi-window tmux) = switch window; double/triple-tap =
word/line select; long-press = zoom pane; alt-screen apps get their input. The redesign is about
the HOW. Constraints the new design must satisfy:

1. **An explicit interaction-mode model**, tracked (not re-sampled): the terminal is in exactly
   one named mode at a time (candidates: `localScroll` / `appOwnsInput` / `mouseReporting`),
   derived from buffer-alternate + mouse-mode but HELD as state and updated on transition, so
   every gesture consults one coherent source of truth.
2. **One unambiguous drag-owner per mode.** No more "custom pan as passenger on SwiftTerm's pan."
   Decide, per mode, whether SwiftTerm's UIScrollView owns the drag or we do — and don't have two
   recognizers fighting.
3. **Alt-screen scroll must DO something** (the Claude Code gap): per the alt-screen topic doc,
   an alt-screen drag should synthesize arrow-keys / Alt-Scroll to the app (xterm behavior,
   xterm.js #1007), not vanish. This is the single most-visible current failure.
4. **Stop reimplementing SwiftTerm internals we can't see.** `calculateTapHit`,
   `syncYDispFromContentOffset`/`isTracking`, the scroll-offset space — either use SwiftTerm's
   own paths or own the whole stack, but do not straddle. The straddle is what keeps breaking.
5. **Decide the SwiftTerm relationship deliberately.** Options to weigh in the brainstorm: (a)
   fully delegate to SwiftTerm + only add non-conflicting gestures; (b) fully own the touch layer
   (disable ALL SwiftTerm recognizers incl. the scroll pan, drive scrollback ourselves via public
   APIs); (c) a clean mode-switched hybrid where ownership flips WITH the mode. Prior attempts did
   an *accidental* straddle; pick one on purpose.

## Existing assets to reuse / reconcile

- **Usability spec / decisions:** the cursor-centric interaction design + the alt-screen topic
  doc `docs/superpowers/topics/2026-07-12-alt-screen-interaction-model.md` (the two-mode model +
  alt-screen drag→arrows is already half-sketched there — the redesign should absorb it).
- **Pure, Linux-tested logic worth keeping:** `Sources/SemicolynKit/Terminal/GestureClassifier.swift`
  (swipe-vs-scroll classify), `TapAction.swift`. The *decision* logic is fine; its *wiring* is the
  problem.
- **The tmux -CC scrollback architecture memory** (`tmux-cc-scrollback-architecture`): capture-pane
  seed → local SwiftTerm scroll → re-seed on %pause; alt-screen-gated mouse forwarding. That's the
  right scrollback model; it must connect cleanly to the new mode model.
- **Files that will be rewritten:** `App/TerminalGestureController.swift` (284 LOC),
  `App/TmuxPaneContainer.swift` (`updateMouseDots` + mount), `App/TerminalScreen.swift`
  (`updateMouseDot` + `cell(at:)` + mount).

## Known open items this redesign should also close

- **Window-tab switch bug** — Spec B (#84) only INSTRUMENTED it; the actual switch-to-wrong-window
  fix is still pending. Folds naturally into the new mode/gesture model.
- **Sporadic swipe** — a direct consequence of defect A+B; the mode model + single drag-owner
  should resolve it by construction.

## How to resume

Fresh context: start `superpowers:brainstorming` on "terminal interaction / gesture / scroll
redesign," feeding it THIS doc + the alt-screen topic doc + the tmux-cc-scrollback memory. Produce
a new spec (explicit mode model + per-mode drag ownership + alt-screen drag→input), then a plan,
then reimplement — replacing the current straddle rather than patching it.
