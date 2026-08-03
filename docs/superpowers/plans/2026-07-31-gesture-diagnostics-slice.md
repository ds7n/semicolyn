<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Gesture Redesign: Diagnostics Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Instrument the two "diagnose-don't-guess" items that gate the whole gesture redesign, so the next slices build on measured root causes instead of guesses: (1) WHY the selection highlight is invisible on the alt-screen, and (2) WHETHER `UIDevice.playInputClick()` actually produces feedback from the keybar's accessory-view mount.

**Architecture:** Both items are pure INSTRUMENTATION, not behavior changes. We add a dedicated `.selection` log category and structured diagnostic lines at the exact moments the spec's ranked root-cause candidates predict divergence (selection set -> forced redraw -> next repaint), plus a one-shot keybar-feedback probe that logs whether the input-click responder context is actually in the chain. No production logic changes; nothing is "fixed" here. The output is device-log evidence that tells the NEXT slice which candidate is real.

**Tech Stack:** Swift 6 (App tier, Apple-only, macOS-CI-verified), SwiftTerm `TerminalView`/`Terminal.buffer.selection`, `DebugLog`/`LogCategory` (App tier), RFC-5424 syslog stream to `tools/syslog-sink`.

## Global Constraints

- **Two tiers:** diagnostic code here is App-tier (`App/`), touches SwiftTerm + UIKit, so it is **invisible to `swift test`** and only compiles/validates on the **macOS CI job**. No Linux test covers it. (CLAUDE.md "two tiers.")
- **Every source file carries an SPDX header** (`GPL-3.0-only`, © True Positive LLC); repo is REUSE-compliant.
- **No em-dash (U+2014) / en-dash (U+2013)** in any output (code, comments, commit messages). A PostToolUse hook strips them from files as a backstop.
- **Conventional commits** (`feat:`/`fix:`/`docs:`/`chore:`); feature branch per slice; squash-merge to `main`.
- **Decision-point logging standard:** each diagnostic line logs inputs -> output -> reason on ONE line via the existing `DebugLog.shared.log(_ category:_ message:)` pattern. **No key CONTENT** (privacy): log selected-char COUNT and coordinates, never the selected text itself in the new lines (the existing `sel:double chars=...` line is pre-existing and out of scope; do not extend that pattern).
- **Log transport gotcha:** the `tools/syslog-sink` docker service must be UP, and the device must stream over **TLS 6514 / TCP** (UDP mangles long lines). Categories are toggleable; the new `.selection` category and existing `.gesture`/`.keybar` must be enabled on the device for capture.
- **Branch:** `feat/gesture-diagnostics` off `test/focus-plus-selection` (the branch holding the combined selection + tap-to-focus work this redesign supersedes).

**Spec reference:** `docs/superpowers/specs/2026-07-30-gesture-interaction-system-design.md`, sections 3g (invisible-highlight root cause, ranked candidates) and 8c (haptics + the `playInputClick` mount-context diagnostic).

---

## File structure

| File | Responsibility | Create/Modify |
|---|---|---|
| `App/LogCategory.swift` | Add a dedicated `.selection` category so highlight-diagnostic lines are independently toggleable and default-on. | Modify |
| `App/TerminalGestureController.swift` | Emit the 3-phase selection-state diagnostic (after-set / after-redraw / on-repaint) around the existing `setSelectionRange` + `setNeedsDisplay` calls, for double-tap and triple-tap, tagged with mode (normal vs alt-screen). | Modify |
| `App/SelectionDiagnostics.swift` | A small pure-ish helper that reads a `TerminalView`'s live selection state (active flag, start/end positions, selection color) into a `String` one-liner, so the same probe is reused at all three phases and both call sites (DRY). | Create |
| `App/PaneTerminalView.swift` | Hook the SwiftTerm repaint (`draw`/`drawRect` override already present as a subclass) to emit the "on next repaint" phase line ONCE per armed diagnostic, closing the set -> repaint race the spec's candidate #1 predicts. | Modify |
| `App/KeybarInputAccessory.swift` (or the file that hosts the keybar as `inputAccessoryView` + conforms `UIInputViewAudioFeedback`) | Add a one-shot `probeInputClickContext()` that logs whether the input-click responder context is actually reachable, and whether `playInputClick()` was invoked, on the first keybar key tap. | Modify |
| `App/InputClickFeedback.swift` | Add an opt-in diagnostic hook: when a debug flag is set, log each `play()` call (caller + whether the audio-feedback host is in the responder chain). | Modify |

Exact hosting file for the keybar accessory is confirmed in Task 4 Step 1 (grep), because the survey saw both `KeybarInputAccessory` (referenced in `InputClickFeedback.swift` comments) and `TerminalScreen.swift:49` wiring; the task pins it before editing.

---

## Task 1: Add the `.selection` log category

**Files:**
- Modify: `App/LogCategory.swift`

**Interfaces:**
- Consumes: the existing `LogCategory: String, CaseIterable, Sendable` enum.
- Produces: `LogCategory.selection` (a new case), usable as `DebugLog.shared.log(.selection, "...")`. Later tasks depend on this case existing.

- [ ] **Step 1: Read the current enum to match its exact style**

Run: `sed -n '1,40p' App/LogCategory.swift`
Note the case-with-trailing-comment format (e.g. `case gesture     // tap/pan/...`) and whether there is a default-on set defined elsewhere in the file (a `defaultEnabled` set or similar). Match it.

- [ ] **Step 2: Add the `.selection` case**

In `App/LogCategory.swift`, add alongside the existing cases (place it next to `.gesture` since they are sibling interaction categories):

```swift
    case selection   // selection set/redraw/repaint state: active flag, range, color (NO content)
```

If the file has a `defaultEnabled` / default-on collection (the `.geometry` category is noted default-on in project memory), ADD `.selection` to it so it captures without manual toggling. If categories are default-on by virtue of `allCases`, no further change is needed. Do not invent a toggle mechanism that is not already there.

- [ ] **Step 3: Build-check compiles (App tier -> local Swift cannot; rely on the type being trivially correct)**

This is an App-tier enum change with no Linux coverage. Verify by inspection: the new case is a bare `case selection` with no associated value, so `CaseIterable`/`RawRepresentable` synthesis still holds. No test to run locally; macOS CI compiles it.

- [ ] **Step 4: Commit**

```bash
git add App/LogCategory.swift
git commit -m "chore(app): add .selection LogCategory for highlight diagnostics"
```

---

## Task 2: Selection-state probe helper

**Files:**
- Create: `App/SelectionDiagnostics.swift`
- Test: none (App-tier, SwiftTerm-coupled, not Linux-testable; verified via device log shape in Task 3/6)

**Interfaces:**
- Consumes: SwiftTerm `TerminalView` (its `selectionActive`/`hasActiveSelection` flag, `getTerminal().buffer.selection` start/end, and `selectedTextBackgroundColor`).
- Produces: `enum SelectionDiagnostics { static func snapshot(_ view: TerminalView, phase: String, mode: String) -> String }` returning a single log-line string. Tasks 3 and 4 call this.

- [ ] **Step 1: Confirm the exact SwiftTerm selection API names available on `TerminalView`**

Run: `grep -rniE 'selectionActive|hasActiveSelection|selectedTextBackgroundColor|var selection|func selectNone' /tmp/claude-*/scratchpad/swiftterm-src/Sources/SwiftTerm/iOS/iOSTerminalView.swift /tmp/claude-*/scratchpad/swiftterm-src/Sources/SwiftTerm/Apple/AppleTerminalView.swift 2>/dev/null | head`

If that scratchpad path is gone, run instead against the resolved package:
`find ~/.cache ./.build /tmp -path '*SwiftTerm*iOSTerminalView.swift' 2>/dev/null | head -1` then grep it.
Confirm which of `selectionActive` (seen at `TerminalScreen.swift:165`) vs `hasActiveSelection` (seen at `TerminalGestureController.swift:669`) is the public accessor, and how selection start/end `Position`s are read (the terminal exposes `getTerminal().buffer` with a `selection` describing start/end grid coords).

- [ ] **Step 2: Write the helper using the confirmed names**

Create `App/SelectionDiagnostics.swift`:

```swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SwiftTerm

/// One-line snapshot of a terminal view's live selection state for the
/// invisible-highlight diagnostic (spec 3g). Reports the ACTIVE flag, the
/// selection grid range, and the configured highlight COLOR at a given phase
/// (after-set / after-redraw / on-repaint), so the device log shows exactly
/// where state diverges between normal-screen and alt-screen. Logs coordinates
/// and a color description only, never selected text content (privacy).
enum SelectionDiagnostics {
    /// `phase` is one of "set" | "redraw" | "repaint". `mode` is the caller's
    /// current interaction mode string (e.g. "localScroll" / "appOwnsInput").
    static func snapshot(_ view: TerminalView, phase: String, mode: String) -> String {
        let active = view.selectionActive
        let term = view.getTerminal()
        // SwiftTerm exposes selection start/end on the terminal buffer's selection
        // service. Read defensively: if the accessor names differ, the Step-1 grep
        // pins the exact path; substitute here.
        let sel = term.buffer.selection    // adjust to confirmed accessor from Step 1
        let start = "(\(sel.start.col),\(sel.start.row))"
        let end = "(\(sel.end.col),\(sel.end.row))"
        let width = (sel.end.col - sel.start.col) + (sel.end.row - sel.start.row) * term.cols
        let color = view.selectedTextBackgroundColor.map { describe($0) } ?? "nil"
        return "sel:diag phase=\(phase) mode=\(mode) active=\(active) range=\(start)->\(end) span=\(width) color=\(color)"
    }

    /// Human-readable color + alpha so a transparent/unset highlight (candidate #2)
    /// is obvious in the log.
    private static func describe(_ c: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "rgba(%.2f,%.2f,%.2f,%.2f)", r, g, b, a)
    }
}
```

Note: `selectedTextBackgroundColor` is set at `TerminalPaletteBridge.swift:27`; confirm in Step 1 whether it is optional. If it is non-optional `UIColor`, drop the `.map`/`?? "nil"` and call `describe` directly.

- [ ] **Step 3: Verify SPDX header + no dashes**

Run: `head -2 App/SelectionDiagnostics.swift && grep -nP '[\x{2013}\x{2014}]' App/SelectionDiagnostics.swift || echo "clean"`
Expected: SPDX lines present; "clean" (no dashes).

- [ ] **Step 4: Commit**

```bash
git add App/SelectionDiagnostics.swift
git commit -m "feat(app): SelectionDiagnostics snapshot helper (highlight root-cause probe)"
```

---

## Task 3: Emit the after-set and after-redraw phases at the selection call sites

**Files:**
- Modify: `App/TerminalGestureController.swift` (double-tap ~649-671, triple-tap ~673-689)

**Interfaces:**
- Consumes: `SelectionDiagnostics.snapshot(_:phase:mode:)` (Task 2); `LogCategory.selection` (Task 1); the existing `callbacks.currentMode()` (returns the mode string already used in `sel:double` lines).
- Produces: `sel:diag phase=set ...` and `sel:diag phase=redraw ...` device-log lines at both select sites. Task 5 arms the matching `phase=repaint` line.

- [ ] **Step 1: Confirm `currentMode()` returns a stable string and how alt-screen reads**

Run: `grep -nE 'func currentMode|currentMode\(\)|appOwnsInput|localScroll|mouseReporting' App/TerminalGestureController.swift | head`
Confirm `callbacks.currentMode()` yields a value distinguishing `.localScroll` (normal shell) from `.appOwnsInput` (alt-screen). The diagnostic MUST be comparable across these two modes (the spec's whole ask: compare normal vs alt-screen).

- [ ] **Step 2: Add the after-set + after-redraw lines to `handleDoubleTap`**

In `handleDoubleTap`, immediately AFTER the existing `view.setSelectionRange(...)` (line ~659) and AFTER the existing `view.setNeedsDisplay(view.bounds)` (line ~668), insert the two probe lines. Keep the existing lines; ADD:

```swift
        // AFTER setSelectionRange (before any repaint): candidate-3 check (zero-width
        // range on alt-screen) + candidate-2 (color) captured at set time.
        let modeStr = "\(callbacks.currentMode())"
        DebugLog.shared.log(.selection, SelectionDiagnostics.snapshot(view, phase: "set", mode: modeStr))
```

Place the first line right after `setSelectionRange`. Then right after the existing `view.setNeedsDisplay(view.bounds)`:

```swift
        // AFTER the forced synchronous repaint request (the guessed 64dc281 fix):
        // if active is still true here but the highlight never draws, candidate #1
        // (repaint race) is implicated; the phase=repaint line (Task 5) confirms.
        DebugLog.shared.log(.selection, SelectionDiagnostics.snapshot(view, phase: "redraw", mode: modeStr))
```

- [ ] **Step 3: Add the same two lines to `handleTripleTap`**

Mirror Step 2 in `handleTripleTap` (after `setSelectionRange` ~680 and after `setNeedsDisplay` ~686), reusing an identical local `modeStr`. Do not factor into a shared function yet (the two handlers differ in range computation); duplicating two log lines is acceptable and keeps each handler readable.

- [ ] **Step 4: Verify no dashes, SPDX intact**

Run: `grep -nP '[\x{2013}\x{2014}]' App/TerminalGestureController.swift || echo "clean"`
Expected: "clean".

- [ ] **Step 5: Commit**

```bash
git add App/TerminalGestureController.swift
git commit -m "feat(app): log selection state at set+redraw phases (double/triple-tap)"
```

---

## Task 4: Arm the on-repaint phase from SwiftTerm's draw

**Files:**
- Modify: `App/PaneTerminalView.swift` (the `TerminalView` subclass; survey confirmed it overrides `bufferActivated`/`mouseModeChanged` here)

**Interfaces:**
- Consumes: `SelectionDiagnostics.snapshot(_:phase:mode:)`; `LogCategory.selection`. A module-level or view-level `armSelectionRepaintDiag` flag set true when a selection is made and consumed once on the next draw.
- Produces: `sel:diag phase=repaint ...` emitted from inside the actual SwiftTerm repaint, exactly once per selection, so candidate #1 (selection cleared between set and draw) is directly observable (active would flip false by repaint time).

- [ ] **Step 1: Confirm `PaneTerminalView` is the drawing subclass and find its draw entry**

Run: `grep -nE 'class PaneTerminalView|override func draw|drawRect|bufferActivated|mouseModeChanged|@MainActor' App/PaneTerminalView.swift`
SwiftTerm's iOS `TerminalView` draws in its own `draw(_:)`. Confirm whether `PaneTerminalView` already overrides `draw(_ rect:)`. If it does NOT, add a minimal override that calls `super.draw(rect)` first, then the diagnostic (drawing must not change).

- [ ] **Step 2: Add the armed one-shot flag + repaint probe**

In `App/PaneTerminalView.swift`, add a stored property and the draw hook. Per the recurring `@MainActor` delegate-callback trap (project memory), `DebugLog.shared.log` is `@MainActor`; a `UIView.draw` override is already main-actor isolated so no `assumeIsolated` is needed here, but confirm `draw` is not marked `nonisolated`.

```swift
    /// Set true by the gesture controller right after a selection is made, so the
    /// NEXT SwiftTerm repaint logs the live selection state (spec 3g candidate #1:
    /// selection cleared by a mode-transition / tmux -CC repaint between set and
    /// draw). One-shot: cleared after it fires once.
    var armSelectionRepaintDiag: Bool = false
    /// The mode string captured at arm time, echoed on the repaint line for
    /// normal-vs-alt comparison.
    var armSelectionRepaintMode: String = "?"

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        if armSelectionRepaintDiag {
            armSelectionRepaintDiag = false
            DebugLog.shared.log(.selection,
                SelectionDiagnostics.snapshot(self, phase: "repaint", mode: armSelectionRepaintMode))
        }
    }
```

- [ ] **Step 3: Arm the flag from the two selection handlers**

Back in `App/TerminalGestureController.swift`, in BOTH `handleDoubleTap` and `handleTripleTap`, right after the existing `view.setNeedsDisplay(view.bounds)`, arm the repaint diagnostic. `view` is a `TerminalView`; cast to `PaneTerminalView` (the concrete subclass) to set the flag:

```swift
        if let pane = view as? PaneTerminalView {
            pane.armSelectionRepaintMode = modeStr
            pane.armSelectionRepaintDiag = true
        }
```

Confirm the concrete type: run `grep -nE 'PaneTerminalView\(|as\? PaneTerminalView|let .*= PaneTerminalView' App/*.swift | head` in Step 1 area to verify panes are `PaneTerminalView` instances (survey listed `PaneTerminalView.swift` as the subclass mounting point). If the gesture controller only ever holds the base `TerminalView` type and cannot see `PaneTerminalView`, instead move the arm flag onto whatever concrete subclass the pane container instantiates (`TmuxPaneContainer.swift:363` region) and set it there.

- [ ] **Step 4: Verify no dashes, SPDX intact on both files**

Run: `grep -nP '[\x{2013}\x{2014}]' App/PaneTerminalView.swift App/TerminalGestureController.swift || echo "clean"`
Expected: "clean".

- [ ] **Step 5: Commit**

```bash
git add App/PaneTerminalView.swift App/TerminalGestureController.swift
git commit -m "feat(app): log selection state on next SwiftTerm repaint (candidate-1 probe)"
```

---

## Task 5: keybar `playInputClick` mount-context probe

**Files:**
- Modify: `App/InputClickFeedback.swift`
- Modify: the keybar accessory host (confirm in Step 1: `KeybarInputAccessory` conforming `UIInputViewAudioFeedback`, referenced in `InputClickFeedback.swift:27-29`)

**Interfaces:**
- Consumes: `LogCategory.keybar` (existing); `UIDevice.current.playInputClick()`.
- Produces: `keybar:clickprobe ...` log lines reporting (a) whether the `UIInputViewAudioFeedback` host is in the responder chain at tap time, and (b) that `playInputClick()` was invoked. This is the evidence for spec 8c's "device-verify playInputClick actually fires" item.

- [ ] **Step 1: Pin the accessory host file + its `UIInputViewAudioFeedback` conformance**

Run: `grep -rnE 'UIInputViewAudioFeedback|enableInputClicksWhenVisible|class KeybarInputAccessory|inputAccessoryView' App/*.swift | head`
Identify the class that (a) is set as the terminal's `inputAccessoryView` and (b) conforms `UIInputViewAudioFeedback` (returns `enableInputClicksWhenVisible = true`). That is the host whose presence in the responder chain determines whether `playInputClick()` produces sound/haptic.

- [ ] **Step 2: Add an invocation-logging path to `InputClickFeedback.play()`**

In `App/InputClickFeedback.swift`, extend `play()` to optionally log. Keep the existing behavior; add a debug-gated log so normal runs are unaffected:

```swift
    /// Play the keyboard click, honoring the user's system keyboard feedback settings.
    static func play() {
        UIDevice.current.playInputClick()
        if diagnosticsEnabled {
            DebugLog.shared.log(.keybar, "keybar:clickprobe called=playInputClick host=\(hostInChainDescription)")
        }
    }

    /// Toggle from the diagnostics session; default off so shipping builds are silent.
    static var diagnosticsEnabled = true   // enabled for the diagnostics slice; flip to false before merge to main

    /// Whether a `UIInputViewAudioFeedback` responder is currently reachable. The
    /// probe (Task 5 Step 3) sets this from the accessory host; if it stays
    /// "unknown", the host never entered the chain, which is exactly the silent
    /// no-op the InputClickFeedback header warns about.
    static var hostInChainDescription = "unknown"
```

- [ ] **Step 3: Report responder-chain membership from the accessory host**

In the accessory host class (Step 1), when it becomes/leaves first-responder context (e.g. `didMoveToWindow` or when it is installed as `inputAccessoryView`), set `InputClickFeedback.hostInChainDescription`. Log once on install. Wrap any `@MainActor`-isolated logging in `MainActor.assumeIsolated {}` if the setter runs from a `nonisolated` UIKit callback (per the @MainActor delegate-callback trap):

```swift
    override func didMoveToWindow() {
        super.didMoveToWindow()
        let inChain = (window != nil)
        InputClickFeedback.hostInChainDescription = inChain ? "audioFeedbackHost@window" : "detached"
        DebugLog.shared.log(.keybar, "keybar:clickprobe host=\(InputClickFeedback.hostInChainDescription) conformsAudioFeedback=true")
    }
```

If the host is a SwiftUI-hosted view without a `didMoveToWindow`, place the equivalent on the UIKit `UIInputView` subclass that actually provides the `UIInputViewAudioFeedback` conformance (the comment at `InputClickFeedback.swift:27-29` names `KeybarInputAccessory` as that provider).

- [ ] **Step 4: Verify no dashes, SPDX intact**

Run: `grep -nP '[\x{2013}\x{2014}]' App/InputClickFeedback.swift || echo "clean"`
Expected: "clean".

- [ ] **Step 5: Commit**

```bash
git add App/InputClickFeedback.swift App/<AccessoryHostFile>.swift
git commit -m "feat(app): probe whether playInputClick fires from keybar accessory mount"
```

---

## Task 6: macOS CI compile gate + device-capture runbook

**Files:**
- Create: `docs/superpowers/topics/2026-07-31-gesture-diagnostics-capture.md` (the capture procedure + what each log line proves)

**Interfaces:**
- Consumes: all diagnostic lines from Tasks 3-5.
- Produces: a written runbook so the device round yields a conclusive read on both root causes; and the CI green signal that the App-tier diagnostic code compiles.

- [ ] **Step 1: Push the branch and gate on the macOS CI job**

```bash
git push -u github feat/gesture-diagnostics
gh run list --branch feat/gesture-diagnostics --limit 1
```
The App-tier changes are only validated by the **macos** CI job (~15-18 min). Wait for it. If `linux-rust` flakes with "sshd fixtures not reachable", rerun that job only (`gh run rerun <id> --failed`); it is unrelated to this non-Rust change. Do NOT proceed to device capture until macos is green (compile errors in App-tier code only surface here).

- [ ] **Step 2: Write the capture runbook**

Create `docs/superpowers/topics/2026-07-31-gesture-diagnostics-capture.md` with:
- **Pre-reqs:** `tools/syslog-sink` docker UP (`docker compose -f tools/syslog-sink/docker-compose.yml up -d`); device streaming **TLS 6514 / TCP** (not UDP); categories `.selection`, `.gesture`, `.keybar` enabled in Settings -> Diagnostics.
- **Highlight capture:** in a NORMAL shell pane, double-tap a word; then triple-tap a line. Repeat in an ALT-SCREEN pane (open Claude/vim). Collect the `sel:diag phase=set|redraw|repaint mode=...` triples for each.
- **Read table (what each outcome proves), transcribe from spec 3g:**
  - `active=true` at set+redraw but `active=false` at repaint -> **candidate #1** (selection cleared by mode-transition / tmux -CC repaint between set and draw). Highest-ranked.
  - `active=true` throughout but `color=rgba(...,0.00)` or `nil` -> **candidate #2** (highlight color transparent/unset at draw).
  - `span=0` / `range` degenerate on alt-screen only -> **candidate #3** (zero-width range on alt-screen).
  - `active=true`, non-transparent color, non-zero span at repaint, yet no visible highlight -> candidates #4/#5 (overlay hiding it / dirty-rect miss).
- **playInputClick capture:** tap several keybar keys. Collect `keybar:clickprobe` lines. If `host=detached`/`unknown` -> the audio-feedback host is NOT in the responder chain -> `playInputClick` is a silent no-op -> the next slice pivots to hosting in a real `UIInputView` or a `UISelectionFeedbackGenerator` fallback (spec 8c). If `host=...@window` and feedback is still absent on device -> the mount is fine and the issue is the user's system keyboard-feedback setting (expected/correct behavior), no pivot needed.

- [ ] **Step 3: Verify the runbook has no dashes**

Run: `grep -nP '[\x{2013}\x{2014}]' docs/superpowers/topics/2026-07-31-gesture-diagnostics-capture.md || echo "clean"`
Expected: "clean".

- [ ] **Step 4: Commit + note the TestFlight trigger**

```bash
git add docs/superpowers/topics/2026-07-31-gesture-diagnostics-capture.md
git commit -m "docs: gesture-diagnostics device-capture runbook + root-cause read table"
```
Then, ONLY after macos CI is green, the diagnostics build can go to device via TestFlight: `gh workflow run "Release to TestFlight" --repo ds7n/semicolyn --ref feat/gesture-diagnostics` (gated on repo var TESTFLIGHT_ENABLED=true). Gate the trigger on the macOS job passing.

---

## Exit criteria (this slice is done when)

1. macOS CI green on `feat/gesture-diagnostics` (App-tier diagnostic code compiles).
2. A device capture exists that reads out, per the Task-6 table, **which** highlight root-cause candidate is real (comparing normal vs alt-screen), NOT a guess.
3. A device capture exists that reads out whether `playInputClick()` reaches an in-chain `UIInputViewAudioFeedback` host.
4. Both findings recorded in the capture doc + project memory, feeding the NEXT slice (Selection UI), whose highlight-fix task is chosen by the candidate the data implicates.

**Not in scope (deliberately):** fixing the highlight, changing selection behavior, wiring per-arrow haptics, any Pad/keybar/scroll work. This slice only produces evidence. The guessed `setNeedsDisplay` (64dc281) is LEFT IN PLACE for now so the diagnostic measures the real current state; its removal/replacement is a Selection-slice decision driven by the capture.

---

## Self-review notes

- **Spec coverage:** 3g (invisible-highlight, all 5 ranked candidates surfaced by the set/redraw/repaint + color + span probe) -> Tasks 2-4, 6. 8c playInputClick mount diagnostic -> Task 5, 6. The redesign's "diagnose-don't-guess" workflow rule -> the entire slice is instrumentation-only, no fixes.
- **Type consistency:** `SelectionDiagnostics.snapshot(_:phase:mode:)` signature is identical across Tasks 2/3/4. `armSelectionRepaintDiag`/`armSelectionRepaintMode` names consistent between Task 4 Step 2 (definition) and Step 3 (use). `InputClickFeedback.hostInChainDescription`/`diagnosticsEnabled` consistent between Task 5 Steps 2 and 3.
- **Placeholder scan:** the two "confirm exact accessor / concrete type" steps (2.1, 4.3) are genuine verification steps with explicit grep commands and explicit substitution instructions, not "TBD" hand-waves; they exist because the SwiftTerm selection-accessor name and the pane concrete-type must be read from source before the code compiles, and the plan says exactly how.
