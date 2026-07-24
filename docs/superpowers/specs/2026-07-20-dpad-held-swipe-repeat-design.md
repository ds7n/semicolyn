<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Design: d-pad held-swipe arrow repeat (2026-07-20)

## Context

Device issue #4 (TF build 29709429181) had two parts:

1. The d-pad key's tap zoomed the active pane, so a press meant to arrow zoomed
   instead. **Fixed** in commit `08c9c7b`: the pad is now swipe-only, single-fire
   (`DragGesture(minimumDistance: 16).onEnded` → one `ArrowDirection`).
2. **This spec:** holding the swipe should auto-repeat the arrow, the way an iOS
   key held down repeats.

The user chose **iOS-standard held-time acceleration** over a distance-scaled rate:
distance selects only the direction; how long the swipe is *held* drives the repeat
speed (initial delay → slow → accelerates to fast). This matches iOS muscle memory
and keeps the thumb resting in one spot rather than reaching to the pad's edge to go
faster.

## Behavior

- Crossing the 16pt trigger fires the **first** arrow immediately (unchanged from
  the shipped single-fire).
- While the swipe is held past the trigger, after an **initial delay** the arrow
  begins repeating; the repeat interval eases from a slow start toward a fast floor
  the longer the swipe is held.
- Direction is recomputed from the current `dx/dy` on each fire, so sliding the
  thumb to a new dominant axis mid-hold changes the arrow direction (iOS-ish).
- Releasing (`.onEnded`) stops the repeat.

Timing constants (iOS-typical):

| Constant        | Value  | Meaning                                              |
|-----------------|--------|------------------------------------------------------|
| `initialDelay`  | 0.40s  | after the first fire, wait this long before repeating |
| `startInterval` | 0.25s  | first repeat interval once repeating begins           |
| `minInterval`   | 0.06s  | fastest repeat (clamp floor)                          |
| `rampDuration`  | 1.20s  | held-time over which the interval eases start → min   |

A quick swipe-and-release (held < `initialDelay`) sends exactly **one** arrow.

## Kit decider (pure, testable)

New file `Sources/SemicolynKit/Keybar/ArrowRepeat.swift`. Two pure pieces, mirroring
the `tmuxLaunchDecision` / `ResizeDebounce` tested-seam pattern (no UIKit/SwiftUI):

```swift
/// iOS-style key-repeat timing as a function of how long a swipe has been held.
public struct ArrowRepeat: Equatable, Sendable {
    public static let initialDelay: TimeInterval  = 0.40
    public static let startInterval: TimeInterval = 0.25
    public static let minInterval: TimeInterval   = 0.06
    public static let rampDuration: TimeInterval  = 1.20

    /// The repeat interval for a swipe held `heldFor` seconds, or nil while still
    /// inside the initial-delay window (no repeat yet). heldFor is measured from the
    /// first fire (the 16pt crossing). Linear ease from startInterval down to
    /// minInterval across rampDuration, then clamped at minInterval.
    public static func interval(heldFor: TimeInterval) -> TimeInterval?
}

/// The dominant-axis arrow for a drag translation. Ties (|dx| == |dy|) resolve to
/// the horizontal axis. Extracted from PadView so direction selection is tested.
public func dominantArrow(dx: Double, dy: Double) -> ArrowDirection
```

`interval(heldFor:)` contract:
- `heldFor < initialDelay` → `nil` (still in the delay window).
- `heldFor` in `[initialDelay, initialDelay + rampDuration)` → eased value strictly
  between `startInterval` and `minInterval` (linear on the ramp).
- `heldFor >= initialDelay + rampDuration` → `minInterval` (clamped).
- At exactly `initialDelay` → `startInterval`.

`dominantArrow` contract:
- `|dx| > |dy|` → `.right` if `dx > 0` else `.left`.
- `|dx| < |dy|` → `.down` if `dy > 0` else `.up`.
- `|dx| == |dy|` (tie, incl. 0,0) → horizontal (`.right` if `dx >= 0` else `.left`).

## View wiring (`PadView` in `App/Keybar/KeybarSlotViews.swift`)

Replace the `.onEnded`-only gesture with `.onChanged` + `.onEnded` and a `@State`
repeating timer:

```
@State private var heldSince: Date?           // set on first crossing; nil = not held
@State private var lastTranslation: CGSize = .zero  // latest dx/dy, updated every onChanged
@State private var repeatTimer: Timer?

.gesture(
  DragGesture(minimumDistance: 16)
    .onChanged { g in
      lastTranslation = g.translation         // always track the latest thumb position
      if heldSince == nil {                    // first crossing → fire once, start repeat
        fire(g.translation)                    // vm.keybar.arrow(dominantArrow(...)) + log
        heldSince = Date()
        armRepeat()                            // schedules the re-arming timer below
      }
    }
    .onEnded { _ in stopRepeat() }             // cancel timer, clear heldSince
)
```

Repeat loop (`armRepeat`): a `Timer` re-armed each tick. On each tick, compute
`heldFor = now - heldSince`, ask `ArrowRepeat.interval(heldFor:)`; if `nil`, keep
waiting (re-arm at a short poll, e.g. the time remaining until `initialDelay`);
otherwise read `lastTranslation` (kept current by every `onChanged`), fire the arrow
for its dominant axis, and re-arm the timer at the returned interval. Reading
`lastTranslation` rather than capturing one translation is what lets the repeat
direction track the thumb as it slides.

Logging: keep the existing `.keybar` `keybar:dpad swipe ... -> arrow=` line on the
**first** fire. Repeats are throttled — log at most a single
`keybar:dpad repeat start` line when repeating begins (respects the no-per-frame-log
carve-out); do **not** log every repeat tick.

`Timer` (main-run-loop) is used rather than Combine `Timer.publish` — simpler and
self-contained for one control. All timer callbacks run on the main actor (the view
is `@MainActor`); no `assumeIsolated` needed for UIView-style overrides, but the
`Timer` closure hops must land on MainActor — use `Timer.scheduledTimer` on the main
run loop so the closure is main-actor.

## Testing (TDD, `Tests/SemicolynKitTests/ArrowRepeatTests.swift`)

Boundary-value analysis on `ArrowRepeat.interval(heldFor:)`:

- `heldFor = 0` → nil (in delay).
- `heldFor = initialDelay - epsilon` → nil (just under boundary).
- `heldFor = initialDelay` → exactly `startInterval`.
- `heldFor` mid-ramp (e.g. `initialDelay + rampDuration/2`) → value strictly between
  `minInterval` and `startInterval`, and equal to the expected linear midpoint.
- `heldFor = initialDelay + rampDuration` → exactly `minInterval` (clamp boundary).
- `heldFor = initialDelay + rampDuration + 1` → `minInterval` (clamped past end).

Equivalence partitions on `dominantArrow(dx:dy:)`:

- One representative per direction: `(10,0)→.right`, `(-10,0)→.left`,
  `(0,10)→.down`, `(0,-10)→.up`.
- Diagonal dominance: `(10,4)→.right`, `(4,-10)→.up`.
- Tie `(5,5)` → horizontal `.right`; tie `(-5,5)` → `.left`; `(0,0)` → `.right`.

Assertions use exact expected values (anti-tautology): the interval tests compute the
expected eased number and assert equality with an accuracy tolerance; nil cases assert
`XCTAssertNil`. No test passes against a broken curve (a constant-interval impl fails
the ramp-midpoint and clamp cases; a no-delay impl fails the two nil cases).

The `PadView` timer wiring is App-tier (macOS-CI-only, not Linux-testable); its
correctness rests on the Kit decider being unit-tested plus device retest.

## Non-goals

- No distance-scaled rate (explicitly rejected in favor of iOS timing).
- No change to the single-fire trigger, the zoom-on-long-press gesture, or any other
  keybar slot.
