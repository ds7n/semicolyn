<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Keybar inputAccessoryView Haptics — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `UIDevice.playInputClick()` actually fire (mirroring the user's iOS keyboard sound+haptic setting) by hosting the keybar as the terminal's real `inputAccessoryView`.

**Architecture:** A new `KeybarInputAccessory: UIInputView` conforming to `UIInputViewAudioFeedback` hosts the existing `PredictorStripView`+`KeybarView` SwiftUI via a `UIHostingController`. It is assigned as each SwiftTerm `TerminalView.inputAccessoryView` (replacing today's `= nil`). The `.safeAreaInset` keybar mount is removed from both `SessionView` branches. Existing per-pane first-responder handling makes iOS show the right pane's accessory automatically.

**Tech Stack:** UIKit (`UIInputView`, `UIInputViewAudioFeedback`, `UIHostingController`), SwiftUI, SwiftTerm, XcodeGen. Swift 5 language mode for the app target.

**Spec:** `docs/superpowers/specs/2026-07-08-keybar-input-accessory-haptics-design.md`

## Global Constraints

- **App-tier only.** These files do NOT compile on Linux and are NOT covered by `swift test`. The compile gate is the **macOS CI** job; behavior is verified on **device**. No `SemicolynKit`/XCTest changes.
- SPDX header (both lines) on every new source file: `// SPDX-FileCopyrightText: 2026 True Positive LLC` / `// SPDX-License-Identifier: GPL-3.0-only`.
- Swift 5 language mode (app target `SWIFT_VERSION: "5.0"`) — main-actor isolation violations from `nonisolated`/`@objc` contexts are still hard errors; UIKit view code runs on the main actor.
- Do NOT change `InputClickFeedback.play()` or any `.onInputClickTap`/`inputClick`/`InputClickButton` call site — they are already correct and just need a valid context.
- Conventional commits; branch `feat/keybar-input-accessory-haptics` (already has the spec commit, based on main); squash-merge.
- No local Swift toolchain — implementers self-review by eye; the macOS CI build in the final task is the compile signal.

## Accepted behavior changes (from the spec — not bugs)

- Keybar rides with the keyboard: when the soft keyboard hides, the keybar hides; tapping the terminal restores both.
- Keybar hidden when a hardware keyboard is connected (no fallback mount).

## File structure

- `App/KeybarInputAccessory.swift` — NEW. The `UIInputView` + `UIInputViewAudioFeedback` host + `UIHostingController` + explicit sizing. One responsibility: be the audio-feedback context that renders the keybar UI.
- `App/TerminalScreen.swift` — MODIFY. Raw/mosh path: create + retain the accessory in the Coordinator; assign `terminal.inputAccessoryView = accessory` (replace `= nil` at ~line 50).
- `App/TmuxPaneContainer.swift` — MODIFY. tmux path: assign a per-pane accessory to each `TerminalView` (replace `t.inputAccessoryView = nil` at ~line 413).
- `App/SessionView.swift` — MODIFY. Remove BOTH `.safeAreaInset` keybar/predictor mounts (~lines 107 and 170).
- `App/Keybar/KeybarView.swift` — MODIFY. Remove the dead `.background(InputClickHost()…)`.
- `App/InputClickFeedback.swift` — MODIFY. Reuse `InputClickAudioView`'s `UIInputViewAudioFeedback` conformance in the accessory; delete `InputClickHost` once unused. `play()` unchanged.

---

### Task 1: `KeybarInputAccessory` — the UIInputView audio-feedback host

**Files:**
- Create: `App/KeybarInputAccessory.swift`

**Interfaces:**
- Consumes: `KeybarSettingsStore`, `ConnectionViewModel`, `PredictorViewModel` (existing), `KeybarView`, `PredictorStripView` (existing SwiftUI), `Theme`.
- Produces:
  - `final class KeybarInputAccessory: UIInputView, UIInputViewAudioFeedback` with:
    - `init(vm: ConnectionViewModel, keybarSettings: KeybarSettingsStore, theme: Theme, hardwareKeyboardConnected: Bool)`
    - `var enableInputClicksWhenVisible: Bool { true }`
    - hosts a `UIHostingController` whose root view is `VStack(spacing:0){ PredictorStripView(vm:predictorVM:); KeybarView(keybarSettings:vm:hardwareKeyboardConnected:) }` inside the app's theme environment.
    - explicit height via `intrinsicContentSize`.

- [ ] **Step 1: Write `KeybarInputAccessory.swift`**

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SwiftUI
import SemicolynKit

/// The keybar's real audio-feedback host. A `UIInputView` conforming to
/// `UIInputViewAudioFeedback`, assigned as the terminal's `inputAccessoryView`, so
/// `UIDevice.playInputClick()` (fired by `.onInputClickTap` on the keybar/predictor)
/// actually plays the keyboard click — mirroring the user's iOS keyboard
/// sound+haptic setting. It renders the existing keybar + predictor SwiftUI via a
/// `UIHostingController`. Because an input accessory view does not auto-size from
/// SwiftUI intrinsic content, the height is set explicitly.
final class KeybarInputAccessory: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }

    private let host: UIHostingController<AnyView>

    /// Approximate keybar row + predictor strip heights. The hosting controller
    /// lays the SwiftUI out within this; refined on device if clipped.
    private static let contentHeight: CGFloat = 88

    init(vm: ConnectionViewModel,
         keybarSettings: KeybarSettingsStore,
         theme: Theme,
         hardwareKeyboardConnected: Bool) {
        let root = VStack(spacing: 0) {
            PredictorStripView(vm: vm, predictorVM: vm.predictorVM)
            KeybarView(keybarSettings: keybarSettings, vm: vm,
                       hardwareKeyboardConnected: hardwareKeyboardConnected)
        }
        .environment(\.theme, theme)
        .background(Color(theme.surface.panel))

        self.host = UIHostingController(rootView: AnyView(root))
        // inputView style gives the standard input-accessory backing.
        super.init(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width,
                                 height: Self.contentHeight),
                   inputViewStyle: .keyboard)
        allowsSelfSizing = true
        translatesAutoresizingMaskIntoConstraints = false

        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.contentHeight)
    }
}
```

- [ ] **Step 2: Self-review (no local compiler)**

Confirm: SPDX header present; `enableInputClicksWhenVisible` returns `true`; `PredictorStripView(vm:predictorVM:)` and `KeybarView(keybarSettings:vm:hardwareKeyboardConnected:)` initializer labels EXACTLY match the existing views (verify against `App/Keybar/PredictorStripView.swift` and `App/Keybar/KeybarView.swift`); `vm.predictorVM` is the correct accessor (verify in `ConnectionViewModel`); `theme.surface.panel` is a valid theme path (it's used in `SessionView`'s current `.safeAreaInset` background). Note macOS CI is the compile gate.

- [ ] **Step 3: Commit**

```bash
git add App/KeybarInputAccessory.swift
git commit -m "feat(app): add KeybarInputAccessory (UIInputView audio-feedback host for the keybar)"
```

---

### Task 2: Wire the accessory into the raw/mosh path + remove its safeAreaInset

**Files:**
- Modify: `App/TerminalScreen.swift` (Coordinator + `makeUIView` ~line 50)
- Modify: `App/SessionView.swift` (raw branch: remove the `.safeAreaInset` at ~line 170; pass what the accessory needs)

**Interfaces:**
- Consumes: `KeybarInputAccessory(vm:keybarSettings:theme:hardwareKeyboardConnected:)` (Task 1).
- Produces: the raw-SSH/mosh `TerminalView` shows the keybar as its `inputAccessoryView`; the `.safeAreaInset` keybar is gone from the raw branch.

- [ ] **Step 1: Give `TerminalScreen` the inputs the accessory needs**

`TerminalScreen` must receive `keybarSettings` + `hardwareKeyboardConnected` so its Coordinator can build the accessory. Add stored props to the `TerminalScreen` struct (near the existing `settings`/`theme` props):

```swift
    /// Keybar customization store — passed to the inputAccessory-hosted keybar.
    var keybarSettings: KeybarSettingsStore = AppStores.shared.keybarSettings
    /// Whether a hardware keyboard is connected (drives the keybar's compact/hidden mode).
    var hardwareKeyboardConnected: Bool = false
```

- [ ] **Step 2: Build + retain the accessory in the Coordinator; assign it in `makeUIView`**

In `TerminalScreen.Coordinator`, add a stored property (near the other `let`s):

```swift
        /// The keybar audio-feedback accessory, retained for this terminal's lifetime.
        var keybarAccessory: KeybarInputAccessory?
```

In `makeCoordinator()`, after constructing `c`, build the accessory:

```swift
        c.keybarAccessory = KeybarInputAccessory(vm: <vm>, keybarSettings: keybarSettings,
                                                 theme: theme,
                                                 hardwareKeyboardConnected: hardwareKeyboardConnected)
```

NOTE: `TerminalScreen` today does NOT hold the `vm`; it holds `send`/`output`/`session`. The accessory needs the `ConnectionViewModel`. Add a `var vm: ConnectionViewModel` stored prop to `TerminalScreen` and pass it from `SessionView` (the raw call-site already has `vm` in scope). Thread it to the Coordinator init and use it above.

In `makeUIView(context:)`, replace:
```swift
        terminal.inputAccessoryView = nil
```
with:
```swift
        terminal.inputAccessoryView = context.coordinator.keybarAccessory
```

- [ ] **Step 3: Pass `vm` + keybar inputs from `SessionView`'s raw call-site; remove that branch's `.safeAreaInset`**

In `App/SessionView.swift` raw branch (`else { TerminalScreen(... ) ... }`, ~line 118), add to the `TerminalScreen(...)` call:
```swift
                                   vm: vm,
                                   keybarSettings: AppStores.shared.keybarSettings,
                                   hardwareKeyboardConnected: hardwareKeyboard.isConnected,
```
(place alongside `theme:`/`osc52Allowed:`).

Then DELETE the entire raw-branch `.safeAreaInset(edge: .bottom, spacing: 0) { VStack(spacing: 0) { PredictorStripView(...); KeybarView(...) } .background(...) }` block (~lines 170–179).

- [ ] **Step 4: Self-review**

Confirm: the raw branch no longer references `KeybarView`/`PredictorStripView` in a `.safeAreaInset`; `TerminalScreen` now has `vm`, `keybarSettings`, `hardwareKeyboardConnected`; the Coordinator builds + retains the accessory and assigns it in `makeUIView`. `vm` is non-optional at the call-site (it's `@StateObject`). macOS CI is the compile gate.

- [ ] **Step 5: Commit**

```bash
git add App/TerminalScreen.swift App/SessionView.swift
git commit -m "feat(app): host keybar as inputAccessoryView on the raw/mosh terminal; drop its safeAreaInset"
```

---

### Task 3: Wire the accessory into the tmux path + remove its safeAreaInset

**Files:**
- Modify: `App/TmuxPaneContainer.swift` (Coordinator + pane creation ~line 413)
- Modify: `App/SessionView.swift` (tmux branch: remove the `.safeAreaInset` at ~line 107; pass keybar inputs)

**Interfaces:**
- Consumes: `KeybarInputAccessory(...)` (Task 1).
- Produces: each tmux pane `TerminalView` shows the keybar as its `inputAccessoryView`; the `.safeAreaInset` keybar is gone from the tmux branch.

- [ ] **Step 1: Give `TmuxPaneContainer` the keybar inputs**

Add stored props to the `TmuxPaneContainer` struct (near `settings`/`theme`):
```swift
    var keybarSettings: KeybarSettingsStore = AppStores.shared.keybarSettings
    var hardwareKeyboardConnected: Bool = false
```
The tmux Coordinator already holds `send`/`settings`/etc. and the container already has access to `vm` indirectly via callbacks; the accessory needs the `ConnectionViewModel`. Add `var vm: ConnectionViewModel` to `TmuxPaneContainer` and pass it from `SessionView`'s tmux call-site (where `vm` is in scope). Thread `vm`, `keybarSettings`, `hardwareKeyboardConnected`, and `theme` into the Coordinator init.

- [ ] **Step 2: Assign a per-pane accessory at pane creation**

In `TmuxPaneContainer.ContainerView.apply(...)`, at the pane-creation site (~line 413) replace:
```swift
                    t.inputAccessoryView = nil
```
with:
```swift
                    t.inputAccessoryView = coordinator?.makeKeybarAccessory()
```

Add a factory on the tmux Coordinator (each pane gets its own instance sharing the same `vm`):
```swift
        /// Build a keybar audio-feedback accessory for a pane's TerminalView. Each
        /// pane owns its own instance; iOS shows the accessory of the first-responder
        /// pane, so the keybar follows the active pane via existing focus handling.
        func makeKeybarAccessory() -> KeybarInputAccessory {
            KeybarInputAccessory(vm: vm, keybarSettings: keybarSettings,
                                 theme: theme, hardwareKeyboardConnected: hardwareKeyboardConnected)
        }
```
This requires the tmux Coordinator to store `vm`, `keybarSettings`, `theme`, `hardwareKeyboardConnected` (add them in Step 1's init threading).

- [ ] **Step 3: Pass keybar inputs from `SessionView`'s tmux call-site; remove that branch's `.safeAreaInset`**

In `App/SessionView.swift` tmux branch (`TmuxPaneContainer(...)`, ~line 57), add:
```swift
                            vm: vm,
                            keybarSettings: AppStores.shared.keybarSettings,
                            hardwareKeyboardConnected: hardwareKeyboard.isConnected,
```
Then DELETE the tmux-branch `.safeAreaInset(edge: .bottom, spacing: 0) { VStack(spacing: 0) { PredictorStripView(...); KeybarView(...) } .background(...) }` block (~lines 107–116).

- [ ] **Step 4: Self-review**

Confirm: tmux branch no longer mounts the keybar via `.safeAreaInset`; each pane's `TerminalView` gets an accessory via `coordinator?.makeKeybarAccessory()`; the Coordinator stores `vm`/`keybarSettings`/`theme`/`hardwareKeyboardConnected`. macOS CI is the compile gate.

- [ ] **Step 5: Commit**

```bash
git add App/TmuxPaneContainer.swift App/SessionView.swift
git commit -m "feat(app): host keybar as inputAccessoryView on tmux panes; drop its safeAreaInset"
```

---

### Task 4: Remove the dead InputClickHost

**Files:**
- Modify: `App/Keybar/KeybarView.swift` (remove `.background(InputClickHost()…)`)
- Modify: `App/InputClickFeedback.swift` (delete `InputClickHost`; keep `InputClickAudioView` only if still referenced, else remove; `play()` unchanged)

**Interfaces:**
- Consumes: nothing new.
- Produces: no dead responder-context view; the real context is `KeybarInputAccessory` (Tasks 1–3).

- [ ] **Step 1: Remove the dead host from `KeybarView`**

In `App/Keybar/KeybarView.swift`, delete this line (and its explanatory comment block just above it):
```swift
        .background(InputClickHost().frame(width: 0, height: 0))
```

- [ ] **Step 2: Delete `InputClickHost`; reconcile `InputClickAudioView`**

In `App/InputClickFeedback.swift`, delete the `InputClickHost` struct entirely. `KeybarInputAccessory` now provides the `UIInputViewAudioFeedback` conformance itself, so `InputClickAudioView` is unused — delete it too UNLESS `grep -rn "InputClickAudioView" App/` shows another reference (it should not). Keep `enum InputClickFeedback { play() }` and the `View` extension helpers (`inputClick`, `onInputClickTap`) and `InputClickButton` — all unchanged.

- [ ] **Step 3: Verify nothing references the deleted symbols**

Run: `rg -n "InputClickHost|InputClickAudioView" App/`
Expected: no matches (both deleted).

- [ ] **Step 4: Commit**

```bash
git add App/Keybar/KeybarView.swift App/InputClickFeedback.swift
git commit -m "refactor(app): remove dead InputClickHost/InputClickAudioView (real context is KeybarInputAccessory)"
```

---

### Task 5: CI green + device verification

**Files:** none (verification).

- [ ] **Step 1: Push branch, open PR, wait for macOS CI**

```bash
git push -u github feat/keybar-input-accessory-haptics
gh pr create --title "fix: keybar as inputAccessoryView so keyboard-feedback haptics fire" \
  --body "Implements docs/superpowers/specs/2026-07-08-keybar-input-accessory-haptics-design.md"
```
Expected: `linux-swift`, `linux-rust`, `lint`, **`macos`** all green. The `macos` job is the only signal for this App-tier work. (`linux-rust` flake → rerun.)

- [ ] **Step 2: Fix any macOS compile errors and re-push**

Likely suspects if red: an `@MainActor`/`nonisolated` isolation error (wrap the offending call in `MainActor.assumeIsolated { … }`, the idiom already used in `App/SwiftTermEchoOracle.swift`); a wrong initializer label on `PredictorStripView`/`KeybarView`; a missing `vm` thread-through. Fix, commit, re-push; re-check.

- [ ] **Step 3: Cut a TestFlight build; device-verify (the real gate)**

On green, dispatch "Release to TestFlight" off the merged main. On device:
  1. iOS Settings → Sounds & Haptics → Keyboard Feedback: **Sound ON + Haptic ON** → tap keybar keys / predictor chips → **click sound + haptic fire**.
  2. Turn both **OFF** → taps are silent (setting honored).
  3. Keybar shows above the soft keyboard; dismiss keyboard → keybar hides; tap terminal → both return.
  4. tmux multi-pane: switch panes → keybar stays present (follows the active pane).
  5. iPad + hardware keyboard: keybar hidden, no crash, typing still works.
  6. Layout: keybar not clipped; correct height in portrait + landscape. If clipped, adjust `KeybarInputAccessory.contentHeight` and re-verify.

- [ ] **Step 4: Record the device outcome** in the spec (does playInputClick fire from the accessory? final height value), then commit that doc change.

---

## Self-Review

- **Spec coverage:** `KeybarInputAccessory` (T1) ✓; raw-path wiring + inset removal (T2) ✓; tmux-path wiring + inset removal (T3) ✓; dead-host cleanup (T4) ✓; CI + device verify incl. all 6 spec device checks (T5) ✓; `playInputClick()`/call-sites unchanged (constraint, honored across all tasks) ✓; accepted behavior changes (rides-with-keyboard, HW-keyboard-hidden) verified in T5 ✓.
- **Placeholder scan:** no TBD/"handle errors"; every code step shows code; the one approximate value (`contentHeight = 88`) is explicitly flagged for device tuning in T1 and T5.6.
- **Type consistency:** `KeybarInputAccessory(vm:keybarSettings:theme:hardwareKeyboardConnected:)` used identically in T1 (def), T2 (raw Coordinator), T3 (tmux `makeKeybarAccessory`); `inputAccessoryView` assignment replaces `= nil` in both T2 and T3; `vm: ConnectionViewModel`, `keybarSettings: KeybarSettingsStore`, `hardwareKeyboardConnected: Bool` threaded consistently.

## Open implementation note (flag for the first task)

`TerminalScreen` and `TmuxPaneContainer` do not currently hold the `ConnectionViewModel` — they take closures (`send`, callbacks). The accessory needs `vm` (for `PredictorStripView(vm:predictorVM:)` and `KeybarView(vm:)`). Tasks 2 and 3 add a `var vm: ConnectionViewModel` to each representable and thread it from `SessionView` (where `vm` is in scope). If passing the whole `vm` is undesirable, an alternative is to pass the two things the keybar UI needs — but the existing `.safeAreaInset` keybar already takes the whole `vm`, so passing `vm` is consistent with current practice and is the chosen approach.
