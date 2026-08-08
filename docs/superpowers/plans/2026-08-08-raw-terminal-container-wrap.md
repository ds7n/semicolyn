<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Raw-terminal container-wrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wrap the raw `PaneTerminalView` in a plain-UIView `RawTerminalContainer` so it stops being the SwiftUI representable leaf, removing the 1001-vs-499 coordinate-space mismatch that is the shared root cause behind the PR #121 scroll/keybar workarounds.

**Architecture:** Mirror the working tmux `-CC` structure (`TmuxPaneContainer.ContainerView`): a plain `UIView` is the SwiftUI leaf; the `TerminalView` is an absolutely-framed subview. The container owns the child's frame height, reading `keyboardLayoutGuide` in its own (correct) coordinate space. The child never self-mutates its frame again.

**Tech Stack:** Swift 6 (strict concurrency), UIKit, SwiftUI (`UIViewRepresentable`), SwiftTerm. App-tier only.

## Global Constraints

- **App-tier is Linux-invisible.** `App/` does NOT compile under `swift test`. The ONLY build signal is the **macOS CI job** (push to `main` or any PR). Do not expect a local Swift build; there is no Swift toolchain on the host.
- **Every source file carries an SPDX header:** `// SPDX-FileCopyrightText: 2026 True Positive LLC` then `// SPDX-License-Identifier: GPL-3.0-only` (REUSE-compliant).
- **No em-dash (U+2014) or en-dash (U+2013)** anywhere (prose, code, comments, commit messages). Use a colon, comma, parentheses, or two sentences.
- **Swift 6 strict concurrency / Sendable.** `App/` may `import UIKit`/`SwiftUI` (Apple-only tier). Match the `@MainActor` / `MainActor.assumeIsolated {}` idioms already in `TerminalScreen.swift` and `TmuxPaneContainer.swift`.
- **Conventional commits** (`feat:` / `fix:` / `refactor:` / `docs:`). Feature branch: `refactor/raw-terminal-container-wrap` (already created). Squash-merge to `main`.
- **Structure-only (locked decision):** keep ALL #121 workarounds resident. The ONLY workaround-touch permitted this PR is flipping `appliesOwnKeybarInset` to `false`. Do NOT delete the `PaneTerminalView` self-inset block, the `handlePan` `hasActiveSelection` gate, or the `isScrollViewInternal` sweep. Those are a follow-up PR after device-verify.
- **Reference (do not modify):** `App/TmuxPaneContainer.swift` is the pattern to mirror. Copy `keyboardTopInContainer()` and `firstResponderKeybarHeight()` verbatim; reuse Kit helpers `usableHeightFromKeyboardTop` / `visibleTerminalHeight` (already shipped + XCTest-covered).
- **Spec:** `docs/superpowers/specs/2026-08-08-raw-terminal-container-wrap-design.md`.

---

## File Structure

- **Create** `App/RawTerminalContainer.swift` (~70 lines): the plain-UIView container leaf. One responsibility: own the single `PaneTerminalView` child's frame from the correct coordinate space.
- **Modify** `App/TerminalScreen.swift`: `makeUIView` returns the container (not the terminal); `updateUIView` signature + terminal-touching lines redirect through `uiView.terminal`; `appliesOwnKeybarInset = false`.
- **Unchanged** `App/PaneTerminalView.swift`: self-inset stays resident, no-ops via the flag.
- **Unchanged / reference only** `App/TmuxPaneContainer.swift`.

## Testing note (read before Task 1)

App-tier code is invisible to `swift test`, so the per-task "test" is NOT a local XCTest run. There is **no new Kit decider** in this change (pure UIKit wiring/geometry glue; the spec confirms this), so there is nothing new to unit-test. The verification gate per task is:

1. **Static self-check** (read the diff; confirm the specific assertions listed in each task's verify step), then
2. **macOS CI compile** (the real Apple build signal), then
3. **On-device TestFlight** verification at the end (Task 4).

Commits are frequent and small so a CI failure bisects cleanly.

---

### Task 1: Create `RawTerminalContainer`

**Files:**
- Create: `App/RawTerminalContainer.swift`

**Interfaces:**
- Consumes: `PaneTerminalView` (existing, `App/PaneTerminalView.swift`); Kit helpers `usableHeightFromKeyboardTop(rawHeight:keyboardTopY:) -> Double` and `visibleTerminalHeight(rawHeight:keybarHeight:) -> Double` (existing, `SemicolynKit`); `KeybarInputAccessory.intrinsicContentSize` (existing).
- Produces: `final class RawTerminalContainer: UIView` with `let terminal: PaneTerminalView`, `weak var coordinator: TerminalScreen.Coordinator?`, and `init(terminal: PaneTerminalView)`. Task 2 consumes these exact names.

- [ ] **Step 1: Write the file**

Create `App/RawTerminalContainer.swift` with exactly this content. `keyboardTopInContainer()` and `firstResponderKeybarHeight()` are copied verbatim from `TmuxPaneContainer.ContainerView` (lines ~899-917 there). `RawTerminalContainer` is a sibling type, not a subclass, so it needs its own copies; the copies read `self.keyboardLayoutGuide` / `self.inputAccessoryView`, which now resolve in the CONTAINER's coordinate space (the fix).

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SemicolynKit

/// Plain-UIView leaf for the raw single-terminal path (`TerminalScreen`), mirroring
/// `TmuxPaneContainer.ContainerView`. The `PaneTerminalView` (a `UIScrollView`) is an
/// absolutely-framed SUBVIEW; this container is what SwiftUI sizes. Because the container
/// is the representable leaf and never self-mutates its own frame, its `bounds` and
/// `keyboardLayoutGuide` resolve in the TRUE slot (~499pt), not the full window (~1001pt).
///
/// This removes the coordinate-space mismatch at its source: previously `TerminalScreen`
/// returned the `PaneTerminalView` directly, so SwiftUI sized the scroll view to ~1001pt
/// while `layoutSubviews` self-mutated it to 499, and `keyboardLayoutGuide.layoutFrame.minY`
/// came back in window space (1001). That drove the PR #121 scroll-dead + keybar-hidden bugs.
/// See `docs/superpowers/specs/2026-08-08-raw-terminal-container-wrap-design.md`.
final class RawTerminalContainer: UIView {
    /// The single terminal child, framed to the keybar-reduced usable height each layout.
    let terminal: PaneTerminalView
    /// The SwiftUI coordinator, retained weakly (mirrors `TmuxPaneContainer.ContainerView`).
    weak var coordinator: TerminalScreen.Coordinator?

    init(terminal: PaneTerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        // Manual framing in layoutSubviews owns the child's frame; keep the UIKit
        // default translatesAutoresizingMaskIntoConstraints = true (no Auto Layout).
        addSubview(terminal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Frame the child to the container width and the keybar-REDUCED usable height. Prefer the
    /// real keyboard/keybar top from `keyboardLayoutGuide` (re-lays-out correctly post-app-switch);
    /// fall back to the measured-keybar-height reduction when the guide has no usable frame. This
    /// is the SAME usable-height source `TmuxPaneContainer` uses, now read from the correct space.
    override func layoutSubviews() {
        super.layoutSubviews()
        let raw = Double(bounds.height)
        let usableH: Double = {
            if let top = keyboardTopInContainer() {
                return usableHeightFromKeyboardTop(rawHeight: raw, keyboardTopY: top)
            }
            return visibleTerminalHeight(rawHeight: raw,
                                         keybarHeight: Double(firstResponderKeybarHeight()))
        }()
        terminal.frame = CGRect(x: 0, y: 0, width: bounds.width, height: usableH)

        // Container-space geometry diagnostic. The direct proof the root cause is gone:
        // `guideTop` should now read ~499 (the slot), not ~1001 (the window).
        guard DebugLog.shared.isEnabled(.geometry) else { return }
        let guideTop = keyboardTopInContainer()
        let accH = (terminal.inputAccessoryView as? KeybarInputAccessory)?.intrinsicContentSize.height ?? -1
        let cf = terminal.frame
        DebugLog.shared.log(.geometry,
            "geo:raw-container bounds=\(Int(bounds.width))x\(Int(bounds.height)) "
            + "guideTop=\(guideTop.map { String(format: "%.0f", $0) } ?? "nil") "
            + "fr=\(terminal.isFirstResponder) accH=\(String(format: "%.0f", accH)) "
            + "usableH=\(String(format: "%.0f", usableH)) "
            + "childFrame=\(Int(cf.minX)),\(Int(cf.minY)),\(Int(cf.width))x\(Int(cf.height))")
    }

    /// The keyboard/keybar top edge in THIS view's coordinate space, via `keyboardLayoutGuide`
    /// (iOS 15+, auto-tracks the keyboard + its inputAccessoryView across show/hide/animation
    /// and the post-app-switch re-layout a measured keybar height missed). Returns nil when the
    /// keyboard is down / the guide has no usable frame, so the caller falls back to full height.
    /// Copied verbatim from `TmuxPaneContainer.ContainerView.keyboardTopInContainer()`.
    private func keyboardTopInContainer() -> Double? {
        let f = keyboardLayoutGuide.layoutFrame
        guard f.height > 0, f.width > 0, f.minY.isFinite, f.minY > 0 else { return nil }
        return Double(f.minY)
    }

    /// The keybar (`inputAccessoryView`) height of the child terminal when it is first responder
    /// (iOS shows exactly that view's accessory). Returns -1 when the terminal is not first
    /// responder (keyboard down, no accessory). Copied from
    /// `TmuxPaneContainer.ContainerView.firstResponderKeybarHeight()` (single-child variant).
    private func firstResponderKeybarHeight() -> CGFloat {
        guard terminal.isFirstResponder,
              let acc = terminal.inputAccessoryView as? KeybarInputAccessory else { return -1 }
        return acc.intrinsicContentSize.height
    }
}
```

- [ ] **Step 2: Static self-check**

Read the new file. Confirm:
- SPDX header present (2 lines, exact text).
- No em-dash / en-dash anywhere.
- `keyboardTopInContainer()` body is byte-identical to `TmuxPaneContainer.swift`'s copy (guard clause `f.height > 0, f.width > 0, f.minY.isFinite, f.minY > 0`).
- `usableHeightFromKeyboardTop` / `visibleTerminalHeight` are called with the SAME argument labels as in `TmuxPaneContainer.layoutSubviews` (`rawHeight:`, `keyboardTopY:`, `keybarHeight:`). Grep to confirm the labels:

Run: `grep -n "usableHeightFromKeyboardTop\|visibleTerminalHeight" App/TmuxPaneContainer.swift`
Expected: the labels match those used in the new file.

- [ ] **Step 3: Confirm the type is not yet referenced (compiles as an island)**

Run: `grep -rn "RawTerminalContainer" App/`
Expected: only matches inside `App/RawTerminalContainer.swift` (Task 2 wires it into `TerminalScreen`). This task adds the type without consumers, so a CI compile here builds it standalone.

- [ ] **Step 4: Commit**

```bash
git add App/RawTerminalContainer.swift
git commit -m "feat(terminal): add RawTerminalContainer plain-UIView leaf

Mirrors TmuxPaneContainer.ContainerView: owns a single PaneTerminalView child
framed to the keybar-reduced usable height, reading keyboardLayoutGuide in the
container's own coordinate space. Not yet wired into TerminalScreen (Task 2).

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 2: Wire `RawTerminalContainer` into `TerminalScreen`

**Files:**
- Modify: `App/TerminalScreen.swift` (`makeUIView` return type + body tail; `updateUIView` signature + terminal-touching lines; `appliesOwnKeybarInset`)

**Interfaces:**
- Consumes: `RawTerminalContainer(terminal:)`, `RawTerminalContainer.terminal` (from Task 1).
- Produces: `TerminalScreen` now vends a `RawTerminalContainer` as its `UIViewRepresentable` view type. No downstream task depends on this beyond device verification.

- [ ] **Step 1: Change `appliesOwnKeybarInset` to false**

In `makeUIView` (currently `App/TerminalScreen.swift:60`), change:

```swift
        terminal.appliesOwnKeybarInset = true
```
to:
```swift
        // Container-wrap (2026-08-08): RawTerminalContainer now owns the child's frame
        // height, so the child must NOT also self-inset (double-fight). Left false; the
        // self-inset code stays resident in PaneTerminalView (deletable in the follow-up
        // cleanup PR). Flip back to true + drop the container to fully revert.
        terminal.appliesOwnKeybarInset = false
```

- [ ] **Step 2: Change the `makeUIView` return type and wrap at the tail**

Change the signature (currently `App/TerminalScreen.swift:55`):

```swift
    func makeUIView(context: Context) -> TerminalView {
```
to:
```swift
    func makeUIView(context: Context) -> RawTerminalContainer {
```

Then change the tail of `makeUIView`. The current tail is:

```swift
        // Render PTY output as it arrives (already hopped to main in the bridge).
        output.onBytes = { [weak terminal] bytes in
            terminal?.feed(byteArray: bytes[...])
        }
        return terminal
    }
```
to:
```swift
        // Render PTY output as it arrives (already hopped to main in the bridge).
        output.onBytes = { [weak terminal] bytes in
            terminal?.feed(byteArray: bytes[...])
        }
        // Wrap the terminal in a plain-UIView container so IT (not the scroll view) is the
        // SwiftUI representable leaf. The container owns the child's frame from the correct
        // coordinate space; see RawTerminalContainer + the 2026-08-08 design spec. All the
        // wiring above stays attached to `terminal` (the child); only the returned leaf changes.
        let container = RawTerminalContainer(terminal: terminal)
        container.coordinator = context.coordinator
        return container
    }
```

- [ ] **Step 3: Change the `updateUIView` signature and redirect terminal-touching lines**

The current `updateUIView` (starts `App/TerminalScreen.swift:199`) takes `_ uiView: TerminalView` and calls terminal methods directly on `uiView`. Change the signature and every `uiView` reference that touches the terminal to `uiView.terminal`. Replace the whole method body with:

```swift
    func updateUIView(_ uiView: RawTerminalContainer, context: Context) {
        let terminal = uiView.terminal
        // Claim keyboard focus ONCE when the view first lands in a window (so the
        // on-screen keyboard + keybar accessory appear). We don't re-claim on later
        // passes; a user who dismisses the keyboard is not fought here. Re-showing it
        // after dismissal is the job of `handleRestoreTap` (tap the terminal).
        if !context.coordinator.didInitialFocus, terminal.window != nil {
            context.coordinator.didInitialFocus = true
            terminal.becomeFirstResponder()
        }
        // Refresh halo color when theme changes.
        context.coordinator.halo.configure(color: UIColor(Color(theme.bell.edge)))
        // Recolor the live terminal when the theme changes.
        applyPalette(theme.terminalPalette(), to: terminal)
        // Re-apply the font live when the user changes face/size in the settings
        // picker. Compare against the last SETTINGS-applied values (not the pinch
        // baseSize) so an in-progress pinch isn't clobbered on every SwiftUI pass;
        // a deliberate settings change resets the pinch baseline to the new size.
        let coord = context.coordinator
        if settings.fontFace != coord.lastAppliedFace || settings.fontSize != coord.lastAppliedFontSize {
            terminal.font = TerminalFontProvider.shared.font(for: settings.fontFace, size: CGFloat(settings.fontSize))
            coord.lastAppliedFace = settings.fontFace
            coord.lastAppliedFontSize = settings.fontSize
            coord.baseSize = settings.fontSize
        }
        // Update mouse-active dot visibility and selection gesture state.
        context.coordinator.updateMouseDot(from: terminal)
    }
```

- [ ] **Step 4: Static self-check**

Read the full `makeUIView` / `updateUIView` diff. Confirm:
- No em-dash / en-dash introduced.
- `makeUIView` still attaches EVERY piece of wiring to `terminal` (the child), not the container: `terminalDelegate`, `onModeRelevantChange`, `modeTracker.onChange`, `inputAccessoryView`, font/palette/cursor, `halo` subview, `mouseDot` subview, `pinch`, `restoreTap`, `gestureController`, `output.onBytes`. The ONLY new lines are the two-line container wrap + return.
- `updateUIView` touches the terminal exclusively via the local `let terminal = uiView.terminal`; no `uiView.font` / `uiView.becomeFirstResponder()` / `applyPalette(..., to: uiView)` remain.

Run: `grep -n "uiView\." App/TerminalScreen.swift`
Expected: the ONLY `uiView.` references are `uiView.terminal` (one binding). No `uiView.font`, `uiView.window`, `uiView.becomeFirstResponder`, or `applyPalette(..., to: uiView)`.

- [ ] **Step 5: Confirm no other file references the old return type**

`TerminalScreen` is a `UIViewRepresentable`; SwiftUI infers `UIViewType` from `makeUIView`, so callers that just place `TerminalScreen(...)` in a view tree need no change. Confirm no code force-casts the representable's view to `TerminalView`:

Run: `grep -rn "TerminalScreen" App/ | grep -iv "TerminalScreen(" | grep -i "TerminalView"`
Expected: no matches (nothing depends on `TerminalScreen` producing a bare `TerminalView`).

- [ ] **Step 6: Commit**

```bash
git add App/TerminalScreen.swift
git commit -m "refactor(terminal): return RawTerminalContainer from TerminalScreen

makeUIView now wraps the PaneTerminalView in RawTerminalContainer (the new
SwiftUI leaf) and returns it; updateUIView redirects terminal-touching lines
through uiView.terminal. appliesOwnKeybarInset flipped to false so the container
owns the child's frame height (no double-inset). All child wiring unchanged.

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

---

### Task 3: macOS CI compile gate

**Files:** none (verification task).

**Interfaces:**
- Consumes: the pushed branch `refactor/raw-terminal-container-wrap`.
- Produces: a green macOS CI job = the Apple-tier compile signal for Tasks 1-2.

- [ ] **Step 1: Push the branch and open the PR (draft)**

```bash
git push -u github refactor/raw-terminal-container-wrap
gh pr create --repo ds7n/semicolyn --draft \
  --title "refactor(terminal): container-wrap the raw terminal path" \
  --body "Structural fix for the raw TerminalScreen path: wrap PaneTerminalView in a plain-UIView RawTerminalContainer so it stops being the SwiftUI representable leaf, removing the 1001-vs-499 coordinate-space mismatch behind the PR #121 scroll/keybar workarounds. Structure-only: all #121 workarounds stay resident; device-verify first, cleanup in a follow-up.

Spec: docs/superpowers/specs/2026-08-08-raw-terminal-container-wrap-design.md
Plan: docs/superpowers/plans/2026-08-08-raw-terminal-container-wrap.md

https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
```

- [ ] **Step 2: Watch the macOS job**

Run: `gh run list --repo ds7n/semicolyn --branch refactor/raw-terminal-container-wrap --limit 1`
Then watch the run. The `macos` job (~15-18 min) is the only Apple build/test signal; `linux-swift`/`linux-rust`/`lint` are the fast loop. If `linux-rust` flakes with "sshd fixtures not reachable after 30s", rerun that job (`gh run rerun <id> --failed`) - it is not a real failure on a non-Rust change.
Expected: `macos` job green (the new file + wiring compile on Apple).

- [ ] **Step 3: If the macOS job fails**

Read the compile error from the run log. Common failure classes for this change:
- `@MainActor` isolation on a delegate/callback read - wrap in `MainActor.assumeIsolated {}` (see the `mainactor-delegate-callback-trap` pattern; `UIView` overrides + `@objc` selectors do NOT need it).
- A missing `import` (the container needs `import UIKit` + `import SemicolynKit`; `TerminalScreen` already imports `SwiftUI`/`SwiftTerm`).
- Argument-label mismatch on the Kit helpers - re-check against `TmuxPaneContainer`.

Fix inline, commit with `fix(terminal): <specific>`, push, re-watch. Do not proceed to Task 4 until the macOS job is green.

---

### Task 4: On-device verification (TestFlight)

**Files:** none (verification task). This is the real gate for the fix; App geometry cannot be validated in CI.

**Interfaces:**
- Consumes: green macOS CI from Task 3.
- Produces: device confirmation that the root cause is gone, unblocking the follow-up cleanup PR.

- [ ] **Step 1: Trigger a TestFlight build**

Gate on the macOS job passing first, then:

```bash
gh workflow run "Release to TestFlight" --repo ds7n/semicolyn --ref refactor/raw-terminal-container-wrap
```

Watch the run; confirm the log shows `UPLOAD SUCCEEDED` (the lane reports green even on a failed upload, so check the log explicitly). Note the new build number (after 119).

- [ ] **Step 2: Start the syslog sink (if not already running)**

```bash
docker compose -f tools/syslog-sink/docker-compose.yml up -d
```

On device: Settings -> Diagnostics -> Stream logs to a server (TLS 6514 / TCP, not UDP). Enable all log categories (lifecycle/connect/tmux/seed/geometry/gesture/input).

- [ ] **Step 3: Device test matrix (raw SSH first, then Mosh, then ET)**

Connect a raw-SSH session and verify each:

1. **Root-cause proof (the headline):** the `geo:raw-container` line reports `guideTop` in the ~499 range (the slot), NOT ~1001 (the window). This is the direct evidence the coordinate-space mismatch is gone.
2. **Scroll works:** swipe up/down on shell output scrolls. The `scroll-trace` line shows `pan=nativePan state=2` (the native scroll pan owns the drag), not a dead touch.
3. **Keybar hides no rows:** `geo:raw-container` shows child `childFrame` height == `usableH`; the bottom prompt row is fully visible above the keybar (no rows behind it). Cross-check `geo:pane` (child-space) agrees.
4. **Clean exit:** `exit` in the shell dismisses to the connection list with no flash (no #121 exit-flash regression).
5. **Keyboard focus / typing / pinch-zoom / theme:** keyboard appears on connect, typing echoes, pinch resizes the font, theme change recolors. (Regression sweep for the wiring redirect.)

Repeat 1-5 for a **Mosh** session and an **ET** session (all three mount `TerminalScreen`).

- [ ] **Step 4: Read the device logs**

The sink writes root-owned `tools/syslog-sink/logs/semicolyn.log`. Read the relevant lines (long lines are TCP-safe with `flags(no-parse)` on tls/tcp):

```bash
docker exec syslog-sink-syslog-1 sh -c "tail -c 200000 /var/log/semicolyn/semicolyn.log" | tr '\r' '\n' | grep -E "geo:raw-container|scroll-trace|geo:pane"
```

Confirm the four assertions from Step 3 (guideTop ~499, nativePan state=2, childFrame height == usableH, clean exit). Capture the key lines into the PR description as device evidence.

- [ ] **Step 5: Mark the PR ready + update docs**

If all device checks pass:

```bash
gh pr ready --repo ds7n/semicolyn <PR-number>
```

Update `TODO.md`: mark the container-wrap done + device-confirmed on build <N>; queue the follow-up cleanup PR (strip the now-dead #121 workarounds: `PaneTerminalView` self-inset block, `handlePan` `hasActiveSelection` gate, `isScrollViewInternal` sweep, trim diagnostics). Commit:

```bash
git add TODO.md
git commit -m "docs(todo): container-wrap device-confirmed; queue workaround-cleanup PR

Claude-Session: https://claude.ai/code/session_01DzjcESNW7qzfnTpp698udt"
git push github refactor/raw-terminal-container-wrap
```

- [ ] **Step 6: If a device check fails**

Do NOT strip workarounds (they are still resident, so the app should be no worse than build 119 even if the container-wrap under-delivers). Capture the failing `geo:raw-container` / `scroll-trace` lines, use `superpowers:systematic-debugging`, and diagnose from the container-space numbers before changing code. The most likely failure is `usableH` coming back == `raw` (guide still not resolving in container space); if so, re-verify the container is truly the representable leaf (not re-parented) and that `firstResponderKeybarHeight()` sees the accessory.

---

## Self-Review

**1. Spec coverage:**
- Container component (spec "Component: RawTerminalContainer") -> Task 1. ✓
- TerminalScreen wiring (spec "Component: TerminalScreen wiring changes") -> Task 2. ✓
- `appliesOwnKeybarInset = false` (spec decision 3) -> Task 2 Step 1. ✓
- Mirror-exactly inset source (spec decision 2) -> Task 1 (`keyboardTopInContainer` + `visibleTerminalHeight` fallback). ✓
- Structure-only, workarounds resident (spec decision 1 + "Out of scope") -> Global Constraints + Task 4 Step 5 queues the follow-up; no task deletes a workaround. ✓
- Testing / verification gate (spec "Testing") -> Tasks 3 (CI) + 4 (device). ✓
- Data flow unchanged (spec "Data flow") -> Task 2 Step 4 confirms all child wiring stays. ✓

**2. Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to Task N". Every code step shows full content. Verification steps list explicit grep/log assertions, not "verify it works". ✓

**3. Type consistency:** `RawTerminalContainer` / `.terminal` / `init(terminal:)` / `.coordinator` used identically in Task 1 (defined) and Task 2 (consumed). Kit helper labels (`rawHeight:`, `keyboardTopY:`, `keybarHeight:`) match `TmuxPaneContainer`. `updateUIView` redirect names (`didInitialFocus`, `halo`, `lastAppliedFace`, `updateMouseDot`) match the existing `Coordinator` in `TerminalScreen.swift`. ✓
