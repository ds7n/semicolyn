# Alt-screen state tracking (iTerm2 model) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the device-disproven consume-once alt-screen override with a persistent per-pane `altState` (seeded by the tmux `#{alternate_on}` query, maintained only by real `?1049` transitions), so a pane already on the alternate screen before -CC attach stays in `.appOwnsInput` instead of flipping back to `.mouseReporting`.

**Architecture:** All changes are App-tier (macOS-CI-compiled, NOT locally buildable). `PaneTerminalView` splits its mode-relevant callback so a `bufferActivated` (a real `?1049` transition) is distinguishable from a `mouseModeChanged`. `PaneModeTracker` gains an `AltSource` param on `recompute` and a persistent `altState: [PaneID?: Bool]`: a `.liveTransition` adopts the live flag, a `.keepTracked` reads the seeded flag unchanged, a `.rawLive` uses the emulator flag directly for non-tmux panes. Kit `resolveMode` is unchanged.

**Tech Stack:** Swift 6 (strict concurrency), App tier (SwiftTerm), macOS CI as the only compile gate.

## Global Constraints

- **App tier only:** these files import SwiftTerm and are validated ONLY by macOS CI. There is NO Swift toolchain on this host and NO local `swift test` for them. Verify by careful reading; the plan has no local test-run steps for App code.
- **`PaneModeTracker` MUST stay nonisolated** (no `@MainActor` on the class, properties, or methods). It was `@MainActor` and that caused a cascade of Swift 6 isolation compile failures because nonisolated coordinators own it. The single `@MainActor` dependency (`DebugLog` logger + `onChange`) stays inside the existing `MainActor.assumeIsolated { ... }` block. Do NOT reintroduce `@MainActor`.
- SPDX headers already present on both files (do not duplicate).
- No em-dashes in code, comments, or commit messages (use a colon, parentheses, or two sentences).
- Conventional commits (`fix:` / `refactor:`).
- Branch: `feat/altscreen-alt-state-tracking` off `main`.
- Implements `docs/superpowers/specs/2026-07-14-altscreen-alt-state-tracking-design.md`.

---

### Task 1: `PaneTerminalView` splits the mode-relevant callback by event kind

**Files:**
- Modify: `App/PaneTerminalView.swift` (the `onModeRelevantChange` property + the two overrides, lines 14-25)

**Interfaces:**
- Produces:
  - `enum ModeRelevantEvent { case bufferChanged, mouseChanged }` (top-level in this file, above the class)
  - `var onModeRelevantChange: ((ModeRelevantEvent, Terminal) -> Void)?` (was `((Terminal) -> Void)?`)
  - `bufferActivated` calls `onModeRelevantChange?(.bufferChanged, source)`; `mouseModeChanged` calls `onModeRelevantChange?(.mouseChanged, source)`.

> This is App-tier: no local compile. The two call sites that ASSIGN `onModeRelevantChange` (TerminalScreen, TmuxPaneContainer) are updated in Task 3; this task changes the type they must match. Task 3 depends on this signature.

- [ ] **Step 1: Add the event enum + change the callback type + route each override**

In `App/PaneTerminalView.swift`, add the enum just above `final class PaneTerminalView` (after the imports/doc comment):

```swift
/// Which mode-relevant SwiftTerm event fired. `bufferActivated` is a real alternate-screen
/// (`?1049`) transition, so the live `isCurrentBufferAlternate` flag is authoritative at that
/// instant. `mouseModeChanged` is NOT an alt-screen transition, so the tracked alt-state must
/// be preserved across it (see `PaneModeTracker.AltSource`).
enum ModeRelevantEvent { case bufferChanged, mouseChanged }
```

Change the property (line 16) from:

```swift
    var onModeRelevantChange: ((Terminal) -> Void)?
```

to:

```swift
    var onModeRelevantChange: ((ModeRelevantEvent, Terminal) -> Void)?
```

Change the two overrides (lines 18-25) to pass the event kind:

```swift
    override func bufferActivated(source: Terminal) {
        super.bufferActivated(source: source)
        onModeRelevantChange?(.bufferChanged, source)
    }
    override func mouseModeChanged(source: Terminal) {
        super.mouseModeChanged(source: source)
        onModeRelevantChange?(.mouseChanged, source)
    }
```

- [ ] **Step 2: Compile-check reasoning (no local build)**

Confirm by reading: the enum is a plain value type (no isolation concerns). The two overrides and the property are the only references to `onModeRelevantChange` in THIS file. `Terminal` is already imported (SwiftTerm). The assign sites in other files will not compile until Task 3, which is expected. macOS CI (Task 4) is the compile gate.

- [ ] **Step 3: Commit**

```bash
git add App/PaneTerminalView.swift
git commit -m "refactor(terminal): split PaneTerminalView mode callback by event kind"
```

---

### Task 2: `PaneModeTracker` persistent `altState` + source-aware recompute

**Files:**
- Modify: `App/PaneModeTracker.swift` (the `altOverride` property → `altState`, `recompute`, `setAltScreenOverride`, `forget`, and add `AltSource`)

**Interfaces:**
- Consumes: `resolveMode(isAltScreen:mouseReporting:)` (Kit, unchanged); `PaneID` (`Hashable`).
- Produces:
  - `enum AltSource { case liveTransition, keepTracked, rawLive }`
  - `func recompute(for pane: PaneID?, terminal: Terminal, altSource: AltSource)` (adds the `altSource:` param)
  - `func recompute(terminal: Terminal, altSource: AltSource)` (single-pane convenience, adds `altSource:`)
  - `func setAltScreenOverride(for pane: PaneID?, isAlt: Bool, terminal: Terminal)` (unchanged signature; now seeds persistent `altState`)
  - `private var altState: [PaneID?: Bool]` replaces `altOverride`

> App-tier: no local compile. Keep `PaneModeTracker` nonisolated (see Global Constraints).

- [ ] **Step 1: Replace `altOverride` with `altState`**

In `App/PaneModeTracker.swift`, replace the `altOverride` property (lines 21-25) with:

```swift
    // Authoritative alternate-screen flag per TMUX pane (PaneID != nil). SEEDED by the
    // attach-time #{alternate_on} query (setAltScreenOverride) and updated ONLY on a real
    // `?1049` transition (a `.liveTransition` recompute), so a pane already on the alternate
    // screen before this -CC client attached (its `?1049h` predated our stream, and tmux
    // never replays it) stays correct until a real exit transition. NOT consume-once: the
    // build-46 device trace showed consume-once reverts to the permanently-wrong live flag.
    // Raw (non-tmux) panes never populate this (their live flag is reliable).
    private var altState: [PaneID?: Bool] = [:]
```

- [ ] **Step 2: Add the `AltSource` enum**

Add it just above `final class PaneModeTracker` (after the imports/doc comment), or as a nested type at the top of the class body. Place it above the class:

```swift
/// How a `recompute` learns a pane's alternate-screen truth.
enum AltSource {
    /// A real `?1049` transition (SwiftTerm `bufferActivated`): the live flag is
    /// authoritative now, so adopt and persist it.
    case liveTransition
    /// A non-alt event (`mouseModeChanged`) or an attach prime: keep the tracked flag,
    /// do not overwrite it from the (possibly stale) live flag.
    case keepTracked
    /// A raw (non-tmux) pane: the live emulator flag is always reliable, use it directly.
    case rawLive
}
```

- [ ] **Step 3: Rewrite `recompute` to be source-aware**

Replace the `recompute(for:terminal:)` method (lines 36-60) with:

```swift
    /// Recompute a pane's `InteractionMode`. Idempotent; only fires `onChange` on a real
    /// mode change. `altSource` decides how the alternate-screen input is derived (see
    /// `AltSource`): the tracked `altState` is the source of truth for tmux panes, updated
    /// only on a live `?1049` transition.
    func recompute(for pane: PaneID?, terminal: Terminal, altSource: AltSource) {
        let liveAlt = terminal.isCurrentBufferAlternate
        let isAlt: Bool
        switch altSource {
        case .rawLive:
            isAlt = liveAlt
        case .liveTransition:
            altState[pane] = liveAlt        // ?1049 just parsed: adopt and persist the live truth
            isAlt = liveAlt
        case .keepTracked:
            isAlt = altState[pane] ?? liveAlt   // tracked wins; fall to live only if never seeded
        }
        let next = resolveMode(isAltScreen: isAlt,
                               mouseReporting: terminal.mouseMode != .off)
        if modes[pane] != next {
            modes[pane] = next
            // recompute is always called on the main thread (SwiftUI/SwiftTerm view
            // callbacks). Both the @MainActor logger and the @MainActor `onChange`
            // (which touches isScrollEnabled / mouseDot UI state) run under one hop.
            let label: String
            switch altSource {
            case .rawLive: label = "raw"
            case .liveTransition: label = "live"
            case .keepTracked: label = altState[pane] != nil ? "tracked" : "live"
            }
            MainActor.assumeIsolated {
                DebugLog.shared.log(.gesture, "mode[\(pane.map { "%\($0.raw)" } ?? "raw")] -> \(next) (altSrc=\(label))")
                onChange(pane, next)
            }
        }
    }
```

- [ ] **Step 4: Update the single-pane convenience + `setAltScreenOverride` + `forget`**

Replace the single-pane convenience (line 64):

```swift
    func recompute(terminal: Terminal, altSource: AltSource) {
        recompute(for: nil, terminal: terminal, altSource: altSource)
    }
```

Replace `setAltScreenOverride` (lines 66-73):

```swift
    /// Seed the attach-time alternate-screen truth for `pane` (from tmux's `#{alternate_on}`)
    /// into the persistent `altState`, then recompute. The seed is authoritative for this tmux
    /// pane until a real `?1049` transition (a `.liveTransition` recompute) updates it.
    func setAltScreenOverride(for pane: PaneID?, isAlt: Bool, terminal: Terminal) {
        altState[pane] = isAlt
        recompute(for: pane, terminal: terminal, altSource: .keepTracked)
    }
```

Update `forget` (lines 78-81) to clear `altState` instead of `altOverride`:

```swift
    func forget(_ pane: PaneID?) {
        modes[pane] = nil
        altState[pane] = nil
    }
```

- [ ] **Step 5: Compile-check reasoning (no local build)**

Confirm by reading: no `@MainActor` added; the `assumeIsolated` block is unchanged except computing `label` before it (the `label` switch is pure, runs nonisolated, fine). `altState` (was `altOverride`) is referenced only in `recompute`/`setAltScreenOverride`/`forget` (grep to confirm 0 remaining `altOverride`). `resolveMode` call signature unchanged. macOS CI (Task 4) is the compile gate.

- [ ] **Step 6: Commit**

```bash
git add App/PaneModeTracker.swift
git commit -m "fix(terminal): persistent alt-state seeded by query, maintained by ?1049 transitions"
```

---

### Task 3: Update the four recompute call sites to declare their `AltSource`

**Files:**
- Modify: `App/TerminalScreen.swift` (lines ~60-61 onModeRelevantChange closure + ~81 prime)
- Modify: `App/TmuxPaneContainer.swift` (lines ~596-598 onModeRelevantChange closure + ~603 prime)

**Interfaces:**
- Consumes: `ModeRelevantEvent` (Task 1), `AltSource` + `recompute(for:terminal:altSource:)` + `recompute(terminal:altSource:)` (Task 2).

> App-tier: no local compile. This task makes the assign sites match Task 1's new callback type and Task 2's new recompute signature. After this task the whole set compiles as a unit (verified by macOS CI in Task 4).

- [ ] **Step 1: TerminalScreen (raw mount) closure + prime**

In `App/TerminalScreen.swift`, the `onModeRelevantChange` closure (around line 60) currently:

```swift
        terminal.onModeRelevantChange = { [weak coordinator = context.coordinator] term in
            coordinator?.modeTracker.recompute(terminal: term)
        }
```

Change it to take the event and pass the raw source. A raw pane's live flag is always reliable, so BOTH event kinds use `.rawLive`:

```swift
        terminal.onModeRelevantChange = { [weak coordinator = context.coordinator] _, term in
            coordinator?.modeTracker.recompute(terminal: term, altSource: .rawLive)
        }
```

And the prime call (around line 81):

```swift
        context.coordinator.modeTracker.recompute(terminal: terminal.getTerminal())
```

becomes:

```swift
        context.coordinator.modeTracker.recompute(terminal: terminal.getTerminal(), altSource: .rawLive)
```

- [ ] **Step 2: TmuxPaneContainer closure + prime**

In `App/TmuxPaneContainer.swift`, the `onModeRelevantChange` closure (around line 596):

```swift
                    t.onModeRelevantChange = { [weak coordinator] term in
                        coordinator?.modeTracker.recompute(for: pane, terminal: term)
                    }
```

Change it to map the event kind to the source (`.bufferChanged` is a real `?1049` transition; `.mouseChanged` keeps the tracked flag):

```swift
                    t.onModeRelevantChange = { [weak coordinator] event, term in
                        let src: AltSource = (event == .bufferChanged) ? .liveTransition : .keepTracked
                        coordinator?.modeTracker.recompute(for: pane, terminal: term, altSource: src)
                    }
```

And the prime call (around line 603):

```swift
                    coordinator?.modeTracker.recompute(for: pane, terminal: t.getTerminal())
```

becomes (a prime is not a transition, so keep any already-seeded state):

```swift
                    coordinator?.modeTracker.recompute(for: pane, terminal: t.getTerminal(), altSource: .keepTracked)
```

- [ ] **Step 3: Confirm no other `recompute(` / `onModeRelevantChange =` call sites remain unmigrated**

Run: `grep -rn 'recompute(\|onModeRelevantChange =' App/*.swift`
Expected: every `recompute(...)` call now passes `altSource:`; both `onModeRelevantChange =` closures take `(event/_ , term)`. The only `recompute` decls without a call-site `altSource` are the two method DEFINITIONS in PaneModeTracker.swift (they declare the param). If any CALL lacks `altSource:`, migrate it the same way (raw mount → `.rawLive`; tmux transition → event-mapped; tmux prime → `.keepTracked`).

- [ ] **Step 4: Compile-check reasoning (no local build)**

Confirm by reading: the closure params now match `((ModeRelevantEvent, Terminal) -> Void)?`; `AltSource` is referenced in a file that can see it (top-level enum in PaneModeTracker.swift, same module). `event == .bufferChanged` compiles (`ModeRelevantEvent` is `Equatable` by synthesis since all cases are payload-free... confirm: a payload-free enum auto-conforms to `Equatable` only when it has no associated values, which is the case here, but `==` still requires `Equatable`; if the compiler complains, add `: Equatable` to `ModeRelevantEvent` OR use a `switch` instead of `==`). To be safe, PREFER a `switch` in the closure to avoid the Equatable question entirely:

```swift
                    t.onModeRelevantChange = { [weak coordinator] event, term in
                        let src: AltSource
                        switch event {
                        case .bufferChanged: src = .liveTransition
                        case .mouseChanged: src = .keepTracked
                        }
                        coordinator?.modeTracker.recompute(for: pane, terminal: term, altSource: src)
                    }
```

Use the `switch` form (above) as the implementation to sidestep any `Equatable` requirement. macOS CI (Task 4) is the compile gate.

- [ ] **Step 5: Commit**

```bash
git add App/TerminalScreen.swift App/TmuxPaneContainer.swift
git commit -m "refactor(terminal): pass AltSource at every recompute call site"
```

---

### Task 4: Push, macOS CI compile gate, PR

**Files:** none (verification + PR)

- [ ] **Step 1: Confirm the full working set is consistent**

Run: `grep -rn 'altOverride' App/`
Expected: 0 matches (fully renamed to `altState`).

Run: `grep -rn 'recompute(' App/*.swift`
Expected: all CALLS pass `altSource:`; only the method DEFINITIONS in PaneModeTracker.swift declare it.

- [ ] **Step 2: Push and open the PR**

```bash
git push github feat/altscreen-alt-state-tracking
gh pr create --base main --head feat/altscreen-alt-state-tracking \
  --title "fix(terminal): persistent alt-screen state tracking (iTerm2 model)" \
  --body "Implements docs/superpowers/specs/2026-07-14-altscreen-alt-state-tracking-design.md. Replaces the device-disproven consume-once override (PR #92) with a persistent per-pane altState seeded by the tmux #{alternate_on} query and maintained only by real ?1049 transitions (SwiftTerm bufferActivated). Fixes the build-46 40ms flip-back (pane stays appOwnsInput) and retires correctly on app-exit. App-tier; macOS CI is the compile gate; device re-trace is acceptance. Also unblocks the Bug-B gr:winner capture."
```

- [ ] **Step 3: Wait for CI (all 4 jobs; macOS is the App-tier compile gate)**

The macOS job is the ONLY validation for these App-tier changes (nonisolated `PaneModeTracker` under Swift 6, the callback-type change propagating to both mounts, `AltSource` resolution). Do not merge until macOS is green. If it fails, read the compile error and fix at the root (this branch's history shows isolation errors surface one layer at a time).

---

## Acceptance (device, build after merge)

With `.gesture` + `.tmux` logging on, reconnect into a pre-existing session with an app already on the alternate screen:
1. `mode[%0] -> appOwnsInput` and it STAYS (no `mode[%0] -> mouseReporting (altSrc=live)` flip-back on the next `mouseModeChanged`). The `altSrc=tracked` label confirms the persistent path held it.
2. Quit the app -> `mode[%0] -> localScroll` (retires on the real `?1049l`, `altSrc=live`).
3. With `%0` now stably `appOwnsInput`, a drag captures the Bug-B `gr:winner <class>` line (previously blocked).
