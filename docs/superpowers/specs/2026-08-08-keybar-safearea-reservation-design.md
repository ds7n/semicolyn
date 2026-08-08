<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Keybar safe-area reservation: design (root-cause fix for the recurring "text behind keybar")

**Date:** 2026-08-08
**Status:** approved, ready for implementation plan
**Scope:** App-tier (macOS-CI + device verified) + one small pure Kit helper/test. No Rust.
**Supersedes:** the mid-flight "converted-frame / 4-prong" plan in the auto-memory. That was refuted by the build-121 diagnostic (see below).
**Extends:** `docs/superpowers/specs/2026-08-08-raw-terminal-container-wrap-design.md` (the container-wrap; scroll is fixed, this fixes the keybar regression it surfaced).

## Problem: the same bug fixed ~6 times

"Terminal rows render behind the floating keybar" has been fixed and has recurred at least six times (`cb3d917`, `db44646`, `471d88f`, `84b50d9`, `1fa0139`, `b05cbe0`). Every fix reconstructed "where is the keybar top" from a **proxy signal** and drove a **manual height computation + manual child framing** from it. Each proxy is wrong in a different state, so each fix traded one failure mode for another and the bug came back.

### The build-121 diagnostic (the decisive evidence)

Device build 121 logged all three candidate signals side by side on the raw path (first responder, keybar up):

| bounds | `guideTop` (keyboardLayoutGuide.layoutFrame.minY) | `kbTopViaFrame` (accessory frame converted to container space) | `accH` (KeybarInputAccessory.intrinsicContentSize.height) | correct keybar top (bounds − 56) |
|--------|------|------|------|------|
| 453 | 453 | **812** (> bounds, garbage) | 56 | 397 |
| 499 | 499 | 448 (~right, off by 5) | 56 | 443 |
| 431 | 431 | **431** (= bounds, lies) | 56 | 375 |

Conclusions:
- **`guideTop` is unreliable:** it equals `bounds.height` (zero keyboard reservation) whenever the on-screen keyboard is dismissed but our `inputAccessoryView` keybar is still shown. That is the build-120/121 break.
- **`kbTopViaFrame` is unreliable:** the accessory lives in a separate UIKit window; mid-animation its converted frame is garbage (812 on a 453 container) or reports bounds-bottom (431).
- **`accH` is reliable in every keybar-up sample (= 56).** It is a pure off-screen content measurement (`KeybarInputAccessory` sums two never-framed measuring hosts: strip 18 + bar 38), so it is immune to frame/window/animation state that corrupts the other two. `bounds − accH` = 397 / 443 / 375, all correct.

### Why `accH` "failed" historically (and why that does not apply here)

`84b50d9` switched away from `accH` to the guide because `bounds − accH` produced a *gap* after an app-switch. That was not `accH` being wrong: it was an artifact of **manually subtracting a fixed height from `bounds.height` while `bounds` itself re-grew** on the app-switch. The fix is not to distrust `accH`; it is to stop hand-computing a frame from `bounds` at all.

## Root cause

The layout tries to *compute* a reduced height and *manually frame* the terminal to it, from a signal that is unreliable in some state. Both halves are the problem:
1. every keybar-top signal is state-dependent and wrong somewhere, and
2. manual framing off `bounds.height` re-breaks whenever `bounds` changes meaning (app-switch, keyboard animation).

## Design: let UIKit reserve the keybar, using the one stable signal

Stop computing `usableH` and manually framing. Instead **reserve the keybar band as a bottom safe-area inset**, sized by the stable `accH`, and lay out into the safe area. UIKit then keeps the terminal above the reserved band automatically across every state (rotation, keyboard show/hide, app-switch) with no per-state signal to prefer.

The shared, transport-independent primitive is the **reservation policy**, not a "which signal wins" function:

```
reservation (bottom) = firstResponder && accH > 0 ? accH : 0
```

Both containers apply the SAME reservation (from the shared helper), then each consumes it in the way that fits its structure.

> **Mechanism correction (2026-08-08, caught by macOS CI):** the first draft applied the reservation via `additionalSafeAreaInsets.bottom`. That property is **`UIViewController`-only**; our containers are plain `UIView`s with no view controller we own between them and SwiftUI (`RawTerminalContainer.swift:57: error: cannot find 'additionalSafeAreaInsets' in scope`). The corrected, UIView-native mechanism keeps the exact same stable-signal reservation policy but consumes it via **Auto Layout on the raw path** and **the existing manual pane framing on the `-CC` path** (see Stage A / Stage B below). `safeAreaLayoutGuide` as a *reservation driver* is therefore also dropped; the raw child pins to the container's own edges with a reservation-driven bottom constant instead.

### Shared helper (Kit, pure, tested)

```swift
/// The bottom safe-area reservation for the keybar accessory. `accH` is the accessory's
/// measured content height (KeybarInputAccessory.intrinsicContentSize.height), the one signal
/// that is stable across frame/window/animation state. `-1`/`0` (keyboard down, no accessory)
/// reserves nothing. Floors at 0. Pure; unit-tested with the build-121 device numbers.
public func keybarSafeAreaReservation(accessoryHeight: Double, isFirstResponder: Bool) -> Double {
    guard isFirstResponder, accessoryHeight > 0 else { return 0 }
    return max(0, accessoryHeight)
}
```

(A deliberately thin function: the value it returns is the whole policy, and locking it in a Kit test with the exact device numbers is the regression guard that was missing every prior round.)

### Stage A: `RawTerminalContainer` (single child, Auto Layout, reservation-driven bottom constant)

- In `init`, set `terminal.translatesAutoresizingMaskIntoConstraints = false` and pin the child to the container's OWN edges: leading/trailing/top to `leadingAnchor`/`trailingAnchor`/`topAnchor`, and BOTTOM to `bottomAnchor` with a STORED constraint whose `constant` starts at 0. Keep a reference to that bottom constraint (`private var bottomConstraint: NSLayoutConstraint!`).
- In `layoutSubviews`, compute `accH` from `terminal.inputAccessoryView`, and set `bottomConstraint.constant = -CGFloat(keybarSafeAreaReservation(accessoryHeight: accH, isFirstResponder: terminal.isFirstResponder))` (negative: it lifts the child's bottom up by the reservation). Guard on change (compare against the last-set constant) so an unchanged value does not churn layout. Auto Layout re-solves the child frame; no manual `terminal.frame = ...`.
- The child's height is thus `containerHeight - reservation`, exactly the keybar-reduced area, driven only by the stable `accH`. No `safeAreaLayoutGuide`, no `additionalSafeAreaInsets`, no proxy.
- DELETE the old `usableH` computation, the `terminal.frame = CGRect(...)` manual frame, and the now-unused `keyboardTopInContainer()` / `keybarTopInContainerViaFrame()` diagnostic helpers. Keep a slimmed `geo:raw-container` line (bounds, reservation, accH, child frame) for device confirmation.
- Runtime invariant tripwire: `reservedTop = bounds.height - reservation`; if `terminal.frame.maxY > reservedTop + epsilon` on a settled pass (reservation unchanged this pass), log `keybar-inset VIOLATION`.

### Stage B: `TmuxPaneContainer` (grid of absolute-framed panes)

`-CC` tiles multiple panes as absolute frames (`view.frame = CGRect(...)` from `fittedPaneRects(usableHeight:)`), so it keeps manual framing and simply sources its `usableH` from the SAME reservation helper instead of the unreliable proxies:

- Compute `reservation = keybarSafeAreaReservation(accessoryHeight: Double(firstResponderKeybarHeight()), isFirstResponder: <any pane is first responder>)`.
- Replace the `usableH` computation (currently `keyboardTopInContainer()` guide, else `visibleTerminalHeight`) with `usableH = Double(bounds.height) - reservation`. This is the same stable-signal reduction the raw path uses; the existing `fittedPaneRects(usableHeight:)` grid math is unchanged, only its input source changes (from the guide proxy to the shared reservation helper).
- Remove the now-dead `keyboardTopInContainer()` proxy path from the layout computation (a diagnostic-only read may remain in `logGeometry`).
- Update the render-storm early-out `LayoutInputs` key: replace the `keyboardTop` field with `reservation` (or keep `keybarH`, whichever the code already threads) so a keybar show/hide still invalidates the early-out.

Stage B lands in the SAME PR but only AFTER Stage A is device-confirmed (the `-CC` path works today; changing it before the mechanism is proven risks regressing a working path).

### Belt-and-suspenders (both stages)

1. **Primary:** UIKit-owned safe-area reservation (above). No signal to prefer.
2. **Stable signal only:** the reservation is driven solely by `accH` (the frame/window-immune measurement); the guide and converted-frame proxies are no longer consulted for layout.
3. **Runtime invariant assertion:** after layout, compute the reserved keybar top from the reservation we applied: `reservedTop = bounds.height - reservation` (the `reservation` value we just set the bottom constraint from; NOT a recomputed proxy). Compare the terminal's on-screen bottom (`terminal.frame.maxY`) against `reservedTop`. If the terminal bottom extends past `reservedTop` by more than a small epsilon (rows would render in the reserved band), log `keybar-inset VIOLATION reservedTop=.. childBottom=.. over=..` at the terminal category (default-on), but ONLY on a pass where the reservation did not just change (the child frame is not re-solved against the new constant within the same pass, so a just-changed pass would false-positive for one frame). This is the tripwire that was missing every prior round; a silent hidden row becomes a loud log line.
4. **Kit regression test:** `keybarSafeAreaReservation` is unit-tested with the build-121 device numbers (accH 56 + firstResponder → 56; accH 56 + not-first-responder → 0; accH -1 → 0; accH 0 → 0), so this specific recurrence cannot pass CI again.

## Data flow

- **Reservation:** `layoutSubviews` → read `accH` → `keybarSafeAreaReservation` → the `reservation` value.
- **Raw child height:** `reservation` → `bottomConstraint.constant = -reservation` → Auto Layout re-solves the pinned child frame (`containerHeight - reservation`) → SwiftTerm grid (`frame.height / cellHeight`) excludes the reserved band. One-directional, Auto-Layout-driven.
- **-CC pane height:** `reservation` → `usableH = bounds.height - reservation` → `fittedPaneRects(usableHeight:)` → pane frames. Same reservation source, existing manual framing.

## Error handling

- `accH <= 0` (keyboard down / accessory not yet measured / seed transient) → reservation 0 → full height. Matches the `firstResponder` guard; identical to the current `-1` sentinel behavior.
- `accH` transiently reads the seed (51) before self-sizing corrects to 56 (documented `KeybarInputAccessory.contentHeight` width-0 fallback): the reservation updates on the next layout pass when `accH` settles; the bottom-constraint constant is idempotent and re-set each pass (guarded on change), so a one-frame-early seed self-corrects without a manual frame ratchet. The invariant assertion (prong 3) would catch it if it ever stuck.

## Testing

- **Kit:** `keybarSafeAreaReservation` gets an XCTest (EP: first-responder×accH-positive, not-first-responder, accH sentinel `-1`, accH `0`; BVA around 0). Real assertions on the exact returned Double.
- **App-tier:** macOS CI compile (only Apple build signal) + device. App layout is not unit-testable on Linux; the Kit helper carries the pure logic.
- **Device success criteria (Stage A, then re-checked Stage B):**
  - no rows behind the keybar in the failing state (keyboard dismissed, keybar up);
  - `geo:raw-container` shows `safeAreaInsets.bottom ≈ 56` and child bottom == reserved top;
  - no `keybar-inset VIOLATION` line;
  - app-switch away and back leaves no gap AND no hidden rows (the state that broke both historical directions);
  - scroll still works (no regression of the container-wrap fix);
  - Stage B: same checks on a tmux `-CC` multi-pane window.

## Scope and reversibility

Structural change to the layout core of `RawTerminalContainer` (Stage A) and `TmuxPaneContainer` (Stage B), plus one pure Kit helper + test. It DELETES manual-framing code rather than adding another branch, so it reduces surface area. Reversible by reverting the branch. Touches the hot path for every session; device verification gates each stage.

## Files

- `Sources/SemicolynKit/Terminal/TerminalGrid.swift` (or a sibling), **add** `keybarSafeAreaReservation`.
- `Tests/SemicolynKitTests/...`, **add** the Kit test.
- `App/RawTerminalContainer.swift`, Stage A: Auto Layout pin + reservation; delete manual framing + proxy helpers.
- `App/TmuxPaneContainer.swift`, Stage B: reservation + `usableH` from `safeAreaLayoutGuide`; delete the guide proxy path.
- `App/PaneTerminalView.swift`, unchanged (self-inset already no-ops; still resident, follow-up cleanup).

## Decisions (locked with user, 2026-08-08)

1. **Root approach:** stop manual framing; UIKit reserves the keybar via `additionalSafeAreaInsets`. (`keyboardLayoutGuide.topAnchor` pin was REJECTED: the anchor shares the same broken `layoutFrame`.)
2. **Signal:** reservation driven by `accH` only (the stable off-screen measurement); guide/converted-frame no longer drive layout.
3. **Locus:** shared Kit reservation helper; BOTH containers adopt it.
4. **Staging:** Stage A (raw) device-proven first, THEN Stage B (-CC) in the SAME PR.
5. **Belt-and-suspenders:** all four prongs (UIKit reservation + stable-signal-only + runtime invariant + Kit test) now.
