<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Raw-terminal container-wrap: design

**Date:** 2026-08-08
**Status:** approved, ready for implementation plan
**Scope:** App-tier only (macOS-CI + device verified; Linux-invisible). No Kit/Rust changes.
**Closes the loop on:** PR #121 (raw-terminal keybar/scroll/exit fixes), whose fixes are workarounds for the root cause this addresses.

## Problem

`TerminalScreen.makeUIView` returns `PaneTerminalView` (a `UIScrollView` subclass) **directly** as the SwiftUI `UIViewRepresentable` leaf. Consequences:

- SwiftUI sizes the view against the full window / safe-area (~1001pt), while `PaneTerminalView.layoutSubviews` **self-mutates `frame.height`** down to the visible slot (~499pt). Two owners fight over the same view's geometry every layout pass.
- The number **1001** appears in BOTH `contentSize` AND `keyboardLayoutGuide.layoutFrame.minY` (`guideTop`) while the visible frame is 499. The keyboard-layout guide resolves in the wrong (window) coordinate space because the scroll view's own space extends into the full window.
- This one coordinate-space mismatch produced BOTH #121 surface bugs:
  - **scroll dead**, unstable bounds mid-touch, `UIScrollViewDelayedTouchesBeganGestureRecognizer` fails, native pan never begins;
  - **keybar hides rows**, `guideTop` in window space (1001) tripped `usableHeightFromKeyboardTop`'s fail-open guard (1001 > 499), so the inset was skipped and ~5 rows rendered behind the floating keybar.

PR #121 shipped targeted, device-confirmed workarounds for each symptom. This spec fixes the **source**: the raw path should never mount a self-sizing scroll view as the representable leaf.

## Why the tmux `-CC` path never had this

`TmuxPaneContainer.makeUIView` returns a plain `UIView` (`ContainerView`) as the SwiftUI leaf; the `TerminalView` panes are **absolutely-framed subviews** (`apply` / `relayoutExistingPaneFrames` set `view.frame = CGRect(...)`). SwiftUI never sizes a scroll view to its content; the pane frame is app-controlled; `contentSize`/`frame` stay consistent; and the keybar math reads `keyboardTopInContainer()` in the CONTAINER's own coordinate space (the real slot). We mirror that structure for the raw path.

## Design

Introduce a plain-`UIView` **`RawTerminalContainer`** as the SwiftUI representable leaf. The existing `PaneTerminalView` becomes an absolutely-framed **subview** of it. SwiftUI sizes the container; the container frames the child to the keybar-reduced usable height, reading `keyboardLayoutGuide` in its OWN (correct, ~499pt) space. The child never mutates its own frame again.

```
BEFORE:  SwiftUI ── sizes ──▶ PaneTerminalView (leaf; self-insets → fights SwiftUI)
AFTER:   SwiftUI ── sizes ──▶ RawTerminalContainer (leaf)
                                   └─ frames ──▶ PaneTerminalView (child; passive)
```

### Component: `RawTerminalContainer` (new file `App/RawTerminalContainer.swift`)

A `final class RawTerminalContainer: UIView` mirroring `TmuxPaneContainer.ContainerView`, holding the single `PaneTerminalView` child and owning its geometry:

```swift
final class RawTerminalContainer: UIView {
    let terminal: PaneTerminalView                 // the one child, framed to usable height
    weak var coordinator: TerminalScreen.Coordinator?

    init(terminal: PaneTerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        addSubview(terminal)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let raw = Double(bounds.height)
        let usableH: Double = {
            if let top = keyboardTopInContainer() {            // guide, now in CONTAINER space
                return usableHeightFromKeyboardTop(rawHeight: raw, keyboardTopY: top)
            }
            return visibleTerminalHeight(rawHeight: raw,        // measured-kbH fallback
                                         keybarHeight: Double(firstResponderKeybarHeight()))
        }()
        terminal.frame = CGRect(x: 0, y: 0, width: bounds.width, height: usableH)
        // + a `geo:raw-container` .geometry diagnostic exposing bounds / guideTop /
        //   usableH / child frame so device traces prove the guide now resolves in
        //   container space (~499, not 1001).
    }
}
```

- **`keyboardTopInContainer()` and `firstResponderKeybarHeight()`** are copied verbatim from `TmuxPaneContainer.ContainerView` (both are `private` there; the raw container is a sibling type, not a subclass, so it gets its own copies). Same Kit-tested helpers `usableHeightFromKeyboardTop` / `visibleTerminalHeight` already shipped.
- The container is the coordinate anchor: as the SwiftUI leaf that never self-mutates, its `bounds` and `keyboardLayoutGuide` resolve in the true slot. That is the whole fix.
- **No render-storm early-out** (unlike `TmuxPaneContainer`): the raw path has one child and no `noteClientSize` fan-out, so a single-frame set each pass is cheap; keep it simple.
- The child's existing `geo:pane` diagnostic in `PaneTerminalView.layoutSubviews` continues to fire (still useful for the child-space view); the container's `geo:raw-container` line adds the container-space numbers.

### Component: `TerminalScreen` wiring changes

`makeUIView` builds the child exactly as today, sets `appliesOwnKeybarInset = false`, wraps it in the container, and returns the container:

```swift
func makeUIView(context: Context) -> RawTerminalContainer {
    let terminal = PaneTerminalView(frame: .zero)
    terminal.appliesOwnKeybarInset = false        // container owns height now (was true)
    // ... ALL existing wiring stays, attached to `terminal`:
    //     terminalDelegate, onModeRelevantChange, modeTracker.onChange,
    //     inputAccessoryView, font/palette/cursor, halo, mouseDot, pinch,
    //     restoreTap, gestureController, output.onBytes
    let container = RawTerminalContainer(terminal: terminal)
    container.coordinator = context.coordinator
    return container
}
```

- **`appliesOwnKeybarInset = false`** (was `true`), the single workaround-touch. The child's self-inset guard no-ops so the container and child do not double-fight over height. The self-inset code block stays resident in `PaneTerminalView` (deletable in the follow-up cleanup PR); flipping this one bool back fully reverts the behavior.
- The child is framed explicitly by the container's `layoutSubviews` (mirrors `TmuxPaneContainer`), so **no autoresizing mask and no Auto Layout constraints** on the child. Keep the UIKit default `translatesAutoresizingMaskIntoConstraints = true` so the manual `frame` set in `layoutSubviews` is authoritative (same implicit reliance as `TmuxPaneContainer`); do not add constraints by reflex.
- **Halo** stays a subview of `terminal` with `halo.frame = terminal.bounds` + `autoresizingMask` (unchanged), so it auto-tracks the child's bounds.

`updateUIView(_ uiView: RawTerminalContainer, context:)` redirects the terminal-touching lines through `uiView.terminal`:
- initial-focus claim: `uiView.terminal.window != nil` / `uiView.terminal.becomeFirstResponder()`,
- `applyPalette(theme.terminalPalette(), to: uiView.terminal)`, `uiView.terminal.font = ...`,
- `context.coordinator.updateMouseDot(from: uiView.terminal)`.

**Coordinator, delegate callbacks, and every Kit decider are unchanged.** `sizeChanged` still fires from the child's `TerminalView` delegate; the resize-debounce path is untouched. The `pinch` / `restoreTap` `recognizer.view as? TerminalView` casts still resolve (attached to the child).

## Data flow (unchanged end-to-end)

- **PTY bytes:** `output.onBytes` → `terminal.feed` (child).
- **Keystrokes:** child `TerminalView` delegate `send` → `onSend` → tmux/raw write.
- **Resize:** child `sizeChanged` → `resizeDebounce` → `session?.resize` / `onResize`. SwiftTerm still derives its grid from the child's `frame.height / cellHeight`; the child's frame is now set by the container to `usableH`, so the grid excludes the keybar region correctly (same net result as the old self-inset, driven from the correct coordinate space).
- **Geometry (now one-directional, no self-mutation loop):** SwiftUI sizes container → `container.layoutSubviews` → frames child → child `processSizeChange` → `sizeChanged`.

## Error handling

None new. The `usableH <= 0` edge (keyboard mid-animation) is already guarded by the Kit helpers returning `raw` when `kbH <= 0`; the container then frames the child to full `raw` height, exactly as `TmuxPaneContainer` does.

## Testing

App-tier, Linux-invisible: `App/` does not compile under `swift test`; validated only by the macOS CI job (the only Apple build signal) + on-device TestFlight.

- **Kit helpers** (`usableHeightFromKeyboardTop`, `visibleTerminalHeight`) are already XCTest-covered, reused, not rewritten.
- **No new Kit logic** is introduced (the container is pure wiring/geometry glue), so there is no new pure decider to unit-test. If implementation or review surfaces an extractable decision, it moves to Kit with a real EP/BVA test.
- **Verification gate:** macOS CI compile + a TestFlight device pass with all log categories on. Device success criteria:
  - swipe scrolls: `scroll-trace pan=nativePan state=2` (native pan owns the drag);
  - keybar hides no rows: `geo:raw-container` shows child `frame.height == usableH` and the pane bottom meets the keybar top (`gapToKeybar ≈ 0`);
  - clean exit to connection list (no regression of the #121 exit-flash);
  - **direct root-cause proof:** `keyboardLayoutGuide` now resolves in container space (`guideTop ≈ 499`, not 1001).

## Scope and reversibility

Structural App-tier change to the **primary terminal render path**, raw SSH, Mosh, and ET all mount `TerminalScreen`. Contained to **2 edited files + 1 new file**, no Kit/Rust changes. Every #121 workaround stays resident, so the change is reversible (flip `appliesOwnKeybarInset` back to `true` and drop the container). Because it touches the hot path for every non-tmux session, device verification is mandatory before the follow-up cleanup PR.

## Out of scope (explicit, a separate follow-up PR after device-verify)

Per the locked "structure-only, keep all workarounds" decision, this PR does NOT remove any #121 workaround beyond flipping `appliesOwnKeybarInset` to `false`. Deferred to the cleanup PR, once the new geometry is device-verified:

- delete the `appliesOwnKeybarInset` property + its `layoutSubviews` self-inset block in `PaneTerminalView`;
- revisit `TerminalGestureController.handlePan`'s `hasActiveSelection` gate and the `isScrollViewInternal` sweep-preserve (belt-and-suspenders once geometry is stable);
- trim the `keybar-inset` / `scroll-trace` diagnostics as confidence allows.

## Files

- `App/RawTerminalContainer.swift`, **new**: the plain-UIView container leaf.
- `App/TerminalScreen.swift`, `makeUIView` / `updateUIView` signatures + wiring redirect; `appliesOwnKeybarInset = false`.
- `App/PaneTerminalView.swift`, no change this PR (self-inset stays resident, no-ops via the flag).
- `App/TmuxPaneContainer.swift`, reference pattern only; not modified.

## Decisions (locked with user, 2026-08-08)

1. **Workaround cleanup: structure-only, keep all workarounds.** Land the container wrap; device-verify first; strip workarounds in a follow-up PR.
2. **Inset source: mirror `TmuxPaneContainer` exactly.** `keyboardTopInContainer()` (now in container space) with the `visibleTerminalHeight(bounds, kbH)` measured-height fallback.
3. **Self-inset handling: set `appliesOwnKeybarInset = false`, keep the code.** Container owns height; child's self-inset no-ops but stays resident and deletable in the follow-up.
