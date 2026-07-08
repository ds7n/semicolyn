<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Keybar as inputAccessoryView — fix keyboard-feedback haptics/sound

**Date:** 2026-07-08
**Status:** Approved (brainstorming), pending implementation plan
**Related:** the keyboard-feedback haptics feature (PR #64, `App/InputClickFeedback.swift`);
keybar mount in `App/SessionView.swift`; `App/Keybar/*`.

## Problem

The keyboard-feedback feature (`InputClickFeedback.play()` → `UIDevice.current.playInputClick()`)
is a **silent no-op on device**. `playInputClick()` only produces sound/haptic when it fires
inside a live `UIInputView` audio-feedback context. Today:

- The keybar + predictor strip mount as a SwiftUI `.safeAreaInset(edge: .bottom)` in
  `SessionView` (both the tmux and raw branches) — **not** a `UIInputView`.
- `InputClickHost` is a **0×0, `isUserInteractionEnabled = false`** view in `.background()`,
  so it never enters the responder chain and provides no real context.

Result: `playInputClick()` is called on every tap but plays nothing.

## Goal

Make tap feedback on the keybar keys, predictor chips, and (transitively) any control under
the keybar actually fire and **mirror the user's iOS keyboard sound + haptic settings**
(the one behavior iOS exposes only through `playInputClick()`).

## Decisions (locked during brainstorming)

- **Keep `playInputClick()`** — faithful to the user's exact iOS keyboard-feedback setting.
  Do NOT switch to `UIImpactFeedbackGenerator`/manual sound (those ignore the keyboard-click
  preference).
- **Host the keybar as the terminal's real `inputAccessoryView`** — the canonical
  `UIInputView` audio-feedback context Apple designed for accessory bars above the keyboard.
- **Accept "keybar rides with the keyboard."** The keybar is no longer always-visible via
  `.safeAreaInset`; when the soft keyboard hides, the keybar hides with it. The user brings
  it back by tapping the terminal (which re-raises the keyboard + keybar). This behavior
  change is intentional and accepted.
- **Accept keybar hidden under a hardware keyboard.** When a hardware keyboard is connected
  (iOS suppresses the soft keyboard and its accessory), the keybar is not shown. No fallback
  mount is built. (`HardwareKeyboardMonitor` already exists but drives no special path here.)

## Non-goals (YAGNI)

- An in-app sound/haptic on/off toggle (we defer entirely to the iOS keyboard setting).
- A `.safeAreaInset` fallback for the hardware-keyboard case (explicitly declined).
- Changing predictor-strip or keybar visuals/behavior beyond where they mount.
- Any change to `InputClickFeedback.play()` itself (it is already correct).

## Architecture

Three units, each with one responsibility:

### 1. `KeybarInputAccessory` (new) — the audio-feedback host
A `UIInputView` subclass conforming to `UIInputViewAudioFeedback`
(`enableInputClicksWhenVisible = true`). It hosts the existing SwiftUI keybar UI
(`PredictorStripView` + `KeybarView`, the same `VStack` that lives in the `.safeAreaInset`
today) inside a child `UIHostingController`. Because it IS a `UIInputView` in the live
responder chain (as the first responder's accessory), `playInputClick()` fires for every
descendant tap. This replaces the dead `InputClickHost`/`InputClickAudioView` responder role.

- **Sizing:** input accessory views do not auto-size from SwiftUI intrinsic content the way
  `.safeAreaInset` does. `KeybarInputAccessory` sets an explicit height via
  `intrinsicContentSize` (and `translatesAutoresizingMaskIntoConstraints`/frame as needed),
  computed from the keybar's known row height + the predictor strip height + safe-area
  bottom inset. The hosting controller's view pins to the accessory's edges.
- **Width:** full screen width (the accessory spans the input area).

### 2. `TerminalView.inputAccessoryView` wiring
SwiftTerm's `TerminalView` is the first responder for keyboard input. Today
`TerminalScreen.makeUIView` sets `terminal.inputAccessoryView = nil` (line ~50) to suppress
SwiftTerm's own bar. We instead assign our `KeybarInputAccessory` instance there. The same
wiring is applied on the tmux path's `TerminalView`s (`TmuxPaneContainer`), so each pane's
active terminal shows the keybar accessory.

- The accessory is handed the same `vm`/`keybarSettings`/`predictorVM` the `.safeAreaInset`
  version received.
- **tmux panes (grounded in current code):** each pane's `TerminalView` already sets its own
  `inputAccessoryView` (currently `= nil`, `TmuxPaneContainer.swift:413`) at creation, and the
  code already drives per-pane `becomeFirstResponder`/`resignFirstResponder` around the
  `activePane` (lines ~399/433). So iOS automatically shows the accessory of whichever pane is
  first responder — we simply assign a `KeybarInputAccessory` per pane's `TerminalView` at
  creation instead of `nil`. No separate "move the accessory on focus change" machinery is
  needed; the existing first-responder handling already produces the correct behavior. (Each
  pane gets its own accessory instance sharing the same `vm`; the single-terminal raw path gets
  one instance.)

### 3. Remove the `.safeAreaInset` keybar mount
Delete the `.safeAreaInset(edge: .bottom) { VStack { PredictorStripView; KeybarView } }`
block from BOTH branches of `SessionView.body`. The keybar UI now lives only inside
`KeybarInputAccessory`. The bottom-safe-area / home-indicator background handling that the
inset performed is no longer needed (the accessory sits above the keyboard, which owns that
region).

## Data flow

User taps a keybar key (inside the accessory) → `.onInputClickTap` runs
`InputClickFeedback.play()` → `UIDevice.current.playInputClick()` → because the tap is inside
a live `UIInputView` (`enableInputClicksWhenVisible == true`) attached to the first responder,
iOS plays the click **honoring the user's keyboard sound + haptic settings** → then the tap's
action runs. No change to `InputClickFeedback` or any call site.

## What is removed / simplified

- `InputClickHost` and its 0×0 `InputClickAudioView` usage in `KeybarView` become dead — the
  real `UIInputView` context is now `KeybarInputAccessory`. Remove the `.background(InputClickHost()…)`
  from `KeybarView` and delete `InputClickHost` if nothing else uses it. `InputClickAudioView`'s
  `UIInputViewAudioFeedback` conformance moves into `KeybarInputAccessory` (or is reused).
- `InputClickFeedback.play()` and the `.onInputClickTap`/`inputClick`/`InputClickButton`
  helpers are UNCHANGED — they already do the right thing; they just finally have a valid
  context.

## Error handling / edge cases

- **Keyboard hidden:** keybar hidden (accepted). Tapping the terminal re-raises both.
- **Hardware keyboard:** keybar hidden (accepted). No fallback.
- **tmux pane switch:** each pane's `TerminalView` carries its own accessory, and the existing
  per-pane first-responder handling makes iOS show the active pane's accessory — the keybar
  never disappears mid-session while the keyboard is up.
- **Rotation / keyboard frame changes:** the accessory re-lays out via its
  `intrinsicContentSize`; height recomputed from the current safe-area bottom inset.

## Testing

**Two-tier rule:** this is entirely App-tier (UIKit `UIInputView`, SwiftTerm, SwiftUI hosting) —
it does NOT compile on Linux and has no `SemicolynKit` logic to unit-test. Validation is:

- **macOS CI:** the app target compiles with the new `KeybarInputAccessory` +
  `inputAccessoryView` wiring and the removed `.safeAreaInset`.
- **Device pass (the real gate — this is the whole point):**
  1. Turn ON iOS Settings → Sounds & Haptics → Keyboard Feedback (Sound + Haptic). Tap keybar
     keys / predictor chips → **click sound + haptic fire**.
  2. Turn them OFF → taps are silent (honoring the setting).
  3. Keybar shows above the soft keyboard; dismissing the keyboard hides the keybar; tapping
     the terminal brings both back.
  4. tmux multi-pane: switching panes keeps the keybar present (follows first responder).
  5. Hardware keyboard attached (iPad): keybar hidden, no crash, terminal input still works.
  6. Layout: keybar not clipped/overlapped; correct height in portrait + landscape.

## Risks

- **SwiftUI-in-`UIInputView` sizing** is the main subtlety (explicit height required). Mitigated
  by computing height from the known keybar + predictor + safe-area values.
- **First-responder across tmux panes** — LOW risk: each pane's `TerminalView` already owns its
  own `inputAccessoryView` slot and the existing per-pane `becomeFirstResponder` logic already
  switches focus, so iOS shows the right pane's accessory automatically. We assign a per-pane
  accessory instead of `nil`; no new focus-follow logic.
- All risks are device-observable; macOS CI catches compile issues, device catches behavior.

## Files touched (anticipated)

- `App/KeybarInputAccessory.swift` — new (`UIInputView` + `UIInputViewAudioFeedback` + hosting
  controller).
- `App/TerminalScreen.swift` — assign `terminal.inputAccessoryView = <accessory>` instead of
  `nil`; coordinator owns/creates the accessory.
- `App/TmuxPaneContainer.swift` — same accessory wiring per pane; carry accessory to the
  first-responder pane on focus change.
- `App/SessionView.swift` — remove the `.safeAreaInset` keybar/predictor mount (both branches).
- `App/Keybar/KeybarView.swift` — remove the dead `.background(InputClickHost()…)`.
- `App/InputClickFeedback.swift` — possibly relocate/rename `InputClickAudioView`'s conformance
  into `KeybarInputAccessory`; delete `InputClickHost` if now unused. `play()` unchanged.
