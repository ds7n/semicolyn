<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Animated window-switch transition — design

**Date:** 2026-07-17
**Status:** approved (brainstorm), ready for implementation plan
**Ships with:** the double/triple-tap alt-screen yield fix (same branch `fix/altscreen-tap-yield`, same TF).

## Problem

Horizontal swipe switches tmux windows, but the switch is an **abrupt swap**: on release, the
current window's panes are torn down and the new window's panes appear with no visual
continuity. Device feedback (build 55): the switch works but "feels awkward / not smooth" and
gives no sense of direction or that a transition happened. The user wants to *see* the screen
move so the switch reads clearly.

## Constraint (shapes the whole design)

Under `tmux -CC` each window's panes are **native views that are destroyed on switch-away and
rebuilt on switch-to** (the `forget()` / re-create flow). The next window's content **does not
exist** until `select-window` completes and tmux streams it. So there is **no live off-screen
"next window" to reveal** during the drag: a finger-tracking reveal would drag against
emptiness. The feasible design is a **transition animation ON the switch** (slide out, then
slide in), not a live preview.

## Approach

A two-phase directional slide, responsive-first:

1. **On swipe release (immediate):** the current window's content slides **out** in the swipe
   direction. Fires the instant the finger lifts, independent of tmux, so the gesture feels
   responsive.
2. **`selectWindow` is sent** (unchanged) → tmux tears down old panes, streams the new window.
3. **On new-window-ready:** when `ContainerView.apply(state:)` runs with a **changed
   `activeWindow`** and a slide-out is pending, the freshly-built panes start translated
   off-screen (opposite edge) and animate **in** to zero.

On a fast link the two phases feel seamless; on a slow link a brief empty gap shows while tmux
delivers (honest "loading" feedback). A **timeout safety net** cancels a pending transition
and snaps to the final layout if the new window does not arrive within a bound, so a slow or
failed switch never leaves the screen stuck mid-slide.

## Section 1 — Trigger, direction, sequence

- **Trigger:** the existing swipe path. `GestureClassifier.classify(...)` already resolves
  `.switchWindow(delta)` on a horizontal-dominant drag; the mount's `onSwitchWindow(delta)`
  closure fires on release. No new gesture.
- **Direction:** derived from the swipe `delta` sign (already computed, already flipped to
  content-follows-finger). A swipe whose content moves left → current slides OUT to the left,
  new slides IN from the right; mirror for the other direction. This mapping is the one pure
  piece of logic (see §3, Kit-tested).
- **Sequence:**
  1. release → `onSwitchWindow(delta)` fires → App: begin transition (record pending
     direction, snapshot + slide current content OUT), THEN call the existing
     `vm.selectWindow`-driving closure.
  2. tmux round-trip → `onStateChanged(activeWindow=new)` → SwiftUI re-render →
     `ContainerView.apply(state:)`.
  3. `apply` sees `activeWindow` changed AND a pending transition → new panes start off-screen
     (opposite edge), animate IN to identity; clear the pending transition.

## Section 2 — Where it lives & mechanism (App-tier UIKit)

The `ContainerView` is a `UIView` inside `TmuxPaneContainer`, so this is UIKit
`transform`-animation, not SwiftUI.

- **`WindowTransition` helper** (App, on the `Coordinator` or as a small type owned by
  `ContainerView`): owns the two-phase animation and the pending-direction state.
  - `func slideOut(_ direction: SlideEdge, in view: UIView, width: CGFloat)` — sets
    `view.transform = CGAffineTransform(translationX: ±width, y: 0)` under `UIView.animate`.
  - `func slideIn(_ direction: SlideEdge, in view: UIView, width: CGFloat)` — starts the view
    at the opposite off-screen translation and animates `transform = .identity`.
  - Holds `pending: (out: SlideEdge, in: SlideEdge)?` and a `Timer`/`DispatchWorkItem`
    timeout that clears `pending` + resets any transform if the new window does not arrive.
- **Slide-OUT site:** the swipe-release wiring (where `onSwitchWindow(delta)` is invoked). It
  computes the direction from `delta` (via the Kit helper), tells `WindowTransition` to slide
  the current content out, records `pending`, arms the timeout, then performs the existing
  window-switch call.
- **Slide-IN site:** `ContainerView.apply(state:)`. After it rebuilds panes, if
  `state.activeWindow != previousActiveWindow` AND `WindowTransition.pending != nil`, it starts
  the new content at the pending `in` edge and animates to identity, then clears `pending` +
  cancels the timeout. `apply` already tracks enough state to know the active window changed
  (it positions the active pane); it gains a `previousActiveWindow` field for the compare.
- **What animates:** the whole pane-content container (the view holding all pane subviews), a
  single transform, so all panes of a window move together as one screen. Border/halo chrome
  rides along on the same view. The `WindowTabStrip` (separate view) does NOT slide (it already
  scroll-animates the active tab, shipped).

## Section 3 — The pure direction decision (Kit, tested)

```swift
/// Which screen edge the OUTgoing window exits toward and which edge the INcoming window
/// enters from, for a window switch of `delta`. Content-follows-finger: a swipe that moves
/// content left (delta ... per the classifier's flipped mapping) sends the current window OUT
/// to the left and brings the new one IN from the right. A zero delta yields no transition.
public enum SlideEdge: Sendable, Equatable { case left, right }
public func windowSlideDirection(delta: Int) -> (out: SlideEdge, in: SlideEdge)?
```

- `delta < 0` (previous window, the rightward swipe per the shipped flip) → `(out: .right, in: .left)`
  (current exits right, new enters from left) — i.e. the new window is "to the left" and slides in from that side.
- `delta > 0` (next window) → `(out: .left, in: .right)`.
- `delta == 0` → `nil` (no switch, no animation).

(The exact edge mapping is finalized against the shipped swipe-flip so the animation moves the
same way the finger did; the Kit test pins it.)

## Testing

Kit (Linux, real):

- **`windowSlideDirection(delta:)`** — EP: `delta = +1` → `(.left, .right)`; `delta = -1` →
  `(.right, .left)`; `delta = 0` → `nil`. BVA: large positive/negative deltas map by sign
  (same as ±1). Assert exact `SlideEdge` pairs (not just non-nil).

App tier (macOS-CI compile + device):

- `WindowTransition` slide-out/in, the `apply` slide-in trigger, the timeout safety net, and
  the direction wiring are UIKit animation — not Linux-buildable. Validated by macOS CI compile
  + device retest (swipe a window: current slides out in the swipe direction, new slides in
  from the other side; on a slow moment a brief gap is acceptable; a stuck switch snaps via the
  timeout).

## Deliverables

1. `SlideEdge` + `windowSlideDirection(delta:)` (Kit) + tests.
2. `WindowTransition` helper (App): `slideOut`/`slideIn`, `pending` state, timeout safety net.
3. `TmuxPaneContainer`: slide-out at the swipe-release wiring (direction via the Kit helper);
   slide-in + `previousActiveWindow` compare in `ContainerView.apply(state:)`; timeout cancel.
4. Device-retest note (TODO): swipe both directions, confirm the slide matches the swipe
   direction + the new window slides in; confirm no stuck-mid-slide on a slow/failed switch.

## Non-goals

- No finger-tracking / live off-screen preview (the `-CC` constraint makes the "next window"
  nonexistent mid-drag; §Constraint).
- No animation of the tab strip (it already scroll-animates the active tab).
- No change to the switch mechanism itself (`select-window` / delta / clamp) or the
  `GestureClassifier` (the swipe-flip + multi-step are separate, already shipped / separate).
- No cross-fade or 3D transition; a single-axis slide is the scope.
