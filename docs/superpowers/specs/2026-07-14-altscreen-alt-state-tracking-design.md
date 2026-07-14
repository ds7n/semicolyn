<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Alt-screen state tracking (iTerm2 model): supersedes the retirement mechanism

**Written:** 2026-07-14, after build-46 device testing disproved the override-retirement mechanism shipped in `2026-07-14-altscreen-scroll-detection-design.md` (PR #92). Grounded in a source-level study of iTerm2, WezTerm, and Blink.

> **Relationship to the prior spec.** The prior spec's Bug-A approach (query tmux `#{alternate_on}` at attach) and all its WIRING (encoder, parser, attach-prime submit, runtime reply to `ConnectionViewModel` queue/forward, `TmuxPaneContainer` drain at mount) are CORRECT and stay as-is. This spec REPLACES ONLY that spec's §3 override-retirement mechanism (the one-time override, tightened to "consume-once" during its final review), which device testing proved wrong. Bug B (the `gr:winner` drag-swallow diagnosis) is unchanged; this fix unblocks its capture. The prior spec is kept as the historical record.

## 1. What device build 46 proved

The attach query works: syslog showed `tmux alternate_on REPLY: panes=9 alt=%0,%6,%4,%2` then `mode[%0] -> appOwnsInput (altSrc=override)`. The seed reaches the mode tracker correctly.

But ~40 ms later: `mode[%0] -> mouseReporting (altSrc=live)`. The consume-once override applies to exactly ONE recompute, then reverts to `terminal.isCurrentBufferAlternate`. For a pane already on the alternate screen BEFORE the `-CC` client attached, that live flag is PERMANENTLY wrong: tmux never replays `?1049h` to a client that attached after the app entered alt-screen (verified in tmux source: `control.c` initializes the new client's per-pane offset to the current write position, and `%output` is strictly forward-only, with no grid/screen serialization anywhere in the control-notify path). Claude emits frequent `mouseModeChanged` events, each triggering a recompute, so the override survives one frame then loses to the wrong live flag. The pane flips back to `.mouseReporting` and the drag goes out as SGR mouse, not arrows.

## 2. The reference model (iTerm2)

iTerm2 is the tmux control-mode reference implementation. Its alt-screen model (source-verified in `TmuxWindowOpener.m`, `TmuxStateParser.m`, `VT100ScreenMutableState.m`, `PTYMouseHandler.m`):

1. **Seed at attach:** query `#{alternate_on}` per pane (`list-panes -F`); use it to set the pane's alternate-screen flag. (iTerm2 also `capture-pane` + `capture-pane -a` to fill both grid buffers, then swaps grid pointers if the flag is set. `capture-pane` output does NOT carry the `?1049h` sequence, so the separate `#{alternate_on}` query is mandatory: the flag cannot be inferred from the captured bytes.)
2. **Maintain from the live stream:** `?1049h`/`?1049l` arriving in `%output` after attach flip the pane's flag through the ordinary emulator path.
3. **Scroll routing reads the pane's OWN tracked flag** (seeded in step 1, maintained in step 2), never a per-scroll tmux query, and NEVER reverts to a raw/unseeded flag.

WezTerm is the anti-pattern: `LocalPane::is_alt_screen_active()` hard-returns `false` for tmux panes, causing open scroll bugs (#1226, #4922, #6166). Blink does not implement `-CC` pane demuxing at all (one emulator per shell), so it never faces this. We copy iTerm2.

## 3. The fix: persistent tracked alt-state

Replace the consume-once override in `PaneModeTracker` with a persistent per-pane alt-state that is SEEDED by the attach query and MAINTAINED only by real `?1049` transitions. All changes are App-tier (`App/PaneModeTracker.swift` + `App/PaneTerminalView.swift`); Kit `resolveMode` is unchanged.

### 3.1 `PaneTerminalView`: split the mode-relevant event by kind

Our per-pane SwiftTerm emulator IS fed the tmux pane's `%output` (`ConnectionViewModel` `view.feed(byteArray:)`), so SwiftTerm fires `bufferActivated` exactly when it parses a `?1049` transition. That is our live-transition signal. Distinguish it from `mouseModeChanged` (which is NOT an alt-screen transition):

```swift
enum ModeRelevantEvent { case bufferChanged, mouseChanged }
var onModeRelevantChange: ((ModeRelevantEvent, Terminal) -> Void)?

override func bufferActivated(source: Terminal) {
    super.bufferActivated(source: source)
    onModeRelevantChange?(.bufferChanged, source)   // emulator just parsed ?1049: live flag is now truth
}
override func mouseModeChanged(source: Terminal) {
    super.mouseModeChanged(source: source)
    onModeRelevantChange?(.mouseChanged, source)     // NOT an alt-screen transition: keep tracked flag
}
```

### 3.2 `PaneModeTracker`: source-aware recompute over persistent `altState`

```swift
/// How a recompute learns the pane's alternate-screen truth.
enum AltSource {
    case liveTransition   // a real ?1049 transition (bufferActivated): the live flag is authoritative now
    case keepTracked      // mouseModeChanged / attach-prime: keep the tracked flag, do not overwrite it
    case rawLive          // raw (non-tmux) pane: the live emulator flag is always reliable
}

/// Authoritative alternate-screen flag per TMUX pane (PaneID != nil). Seeded by the
/// attach-time #{alternate_on} query and updated only on a live ?1049 transition, so a
/// pane already on the alternate screen before attach (whose ?1049h predates our stream)
/// stays correct until a real exit transition. Raw panes never populate this.
private var altState: [PaneID?: Bool] = [:]

func recompute(for pane: PaneID?, terminal: Terminal, altSource: AltSource) {
    let liveAlt = terminal.isCurrentBufferAlternate
    let isAlt: Bool
    switch altSource {
    case .rawLive:
        isAlt = liveAlt                                   // raw pane: trust the emulator directly
    case .liveTransition:
        altState[pane] = liveAlt                          // ?1049 just seen: adopt + persist the live truth
        isAlt = liveAlt
    case .keepTracked:
        isAlt = altState[pane] ?? liveAlt                 // tracked wins; fall to live only if never seeded
    }
    let next = resolveMode(isAltScreen: isAlt, mouseReporting: terminal.mouseMode != .off)
    if modes[pane] != next {
        modes[pane] = next
        MainActor.assumeIsolated {
            DebugLog.shared.log(.gesture, "mode[\(pane.map { "%\($0.raw)" } ?? "raw")] -> \(next) (altSrc=\(altSourceLabel(altSource, seeded: altState[pane] != nil)))")
            onChange(pane, next)
        }
    }
}
```

`altSourceLabel` yields a precise diagnostic string (`live` / `tracked` / `raw`) so a device trace distinguishes which path set the mode. `setAltScreenOverride` (from the query reply) becomes:

```swift
func setAltScreenOverride(for pane: PaneID?, isAlt: Bool, terminal: Terminal) {
    altState[pane] = isAlt                                // the authoritative seed
    recompute(for: pane, terminal: terminal, altSource: .keepTracked)
}
```

`forget(_:)` clears both `modes[pane]` and `altState[pane]` (a reused PaneID after tmux window-switch starts clean).

### 3.3 Call sites (each declares its source)

| Call site | `altSource` |
|---|---|
| `PaneTerminalView.onModeRelevantChange` `.bufferChanged` (tmux + raw mounts) | `.liveTransition` |
| `PaneTerminalView.onModeRelevantChange` `.mouseChanged` | `.keepTracked` |
| tmux mount prime (`TmuxPaneContainer` makeUIView + apply) | `.keepTracked` |
| raw mount prime (`TerminalScreen` makeUIView + updateUIView) | `.rawLive` |
| `setAltScreenOverride` (query reply) | `.keepTracked` (writes `altState` first) |

Note the raw mount's `bufferActivated` also routes through `.liveTransition` (which writes `altState`), but raw panes never read `altState` via `.keepTracked` (their only non-transition recomputes pass `.rawLive`), so the write is harmless and the raw path stays "live flag direct".

## 4. Why this fixes both failure modes

- **Shared-session pre-attach pane (the build-46 bug):** query seeds `altState[%0]=true` → `.appOwnsInput`. A later `mouseModeChanged` recompute passes `.keepTracked`, reads `altState[%0]=true` unchanged → STAYS `.appOwnsInput`. No 40 ms flip-back.
- **App exits alt-screen:** the app sends `?1049l` → SwiftTerm fires `bufferActivated` → `.liveTransition` sets `altState[%0]=false` → resolves to `.localScroll`/`.mouseReporting`. Retires correctly (the exact case the prior spec promised but did not deliver).
- **Raw (non-tmux) pane:** always `.rawLive` / live flag. Unchanged behavior.

## 5. Testing

- **Kit:** `resolveMode` is unchanged (already tested). No new pure logic to unit-test; the tracking lives in the App tier by necessity (it reads SwiftTerm's `Terminal`).
- **App (macOS CI compile gate):** the `AltSource` enum, the split callback, the source-aware recompute.
- **Device (build 47) acceptance:**
  1. Reconnect into a pre-existing session with an app already on the alternate screen → `mode[%0] -> appOwnsInput` and it STAYS (no `-> mouseReporting (altSrc=live)` flip-back on the next `mouseModeChanged`).
  2. Quit the app → `mode[%0] -> localScroll` (retires on the real `?1049l`).
  3. With `%0` now stably `appOwnsInput`, a drag on it captures the Bug-B `gr:winner <class>` line (previously blocked because the pane kept leaving `appOwnsInput`).

## 6. Out of scope

- The Bug-B disable fix (still awaiting the `gr:winner` trace this fix unblocks).
- iTerm2's `capture-pane -a` alternate-buffer seeding: we do not swap grid buffers (SwiftTerm owns rendering; we only need the alt-SCREEN mode flag for gesture routing, not the alt-buffer CONTENT, which tmux paints for us). Only the `#{alternate_on}` flag is required.
- The broader tmux -CC hardening backlog (FIFO abort-cascade, `%pause`/`%continue` re-capture, no-resume reattach, two-decoder scrollback, send-keys C0 trap): tracked separately, not this fix.
