<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Build-47 device testing: five issues (resume doc)

**Written:** 2026-07-15, from the build-47 device syslog (`data/syslog/semicolyn-bunknown-2026-07-14.log`, build-47 session starts ~line 3262; extract was `/tmp/b47.txt`). Context ran full; this doc hands off to a fresh session.

## WHAT SHIPPED AND WORKS (build 47, PR #93, main 0a6db44)

**Alt-screen DETECTION is FIXED.** The persistent-altState (iTerm2-model) fix works on device:
- Claude (shared pre-existing tmux session, alt-screen before attach): `alternate_on REPLY: panes=9 alt=%0,%6,%12,%4,%2` then `mode[%0] -> appOwnsInput (altSrc=tracked)` and it STAYS (no build-46 flip-back to `mouseReporting (altSrc=live)`).
- less/btop (launched live while connected, pane %13): `?1049h` in `%output` -> `mode[%13] -> appOwnsInput (altSrc=live)`, `?1049l` -> `-> localScroll`. Correct enter/exit tracking every cycle.
So detection is DONE. The remaining problems are DOWNSTREAM of detection.

## THE FIVE ISSUES (device-reported 2026-07-15)

### #1 [CORE BUG] Claude / less / btop do not scroll on drag
**Root cause (trace-proven):** `gr:scrollPan began mode=appOwnsInput` = **0 occurrences**. Our `handleScrollViewPan` NEVER fires when a pane is in `.appOwnsInput`. Every `gr:scrollPan began` logged `mode=localScroll` (9 of them, all on localScroll panes/moments).
Why: the mount sets `terminal.isScrollEnabled = (mode == .localScroll)` (TerminalScreen.swift:76, TmuxPaneContainer twin). In `.appOwnsInput`, `isScrollEnabled = false`, which **disables the `UIScrollView.panGestureRecognizer`** (and thus OUR target added to it via `panGestureRecognizer.addTarget(self, #selector(handleScrollViewPan))`). So the drag->arrows path (`AltScreenScroll` -> `encodeArrowRun` -> sendBytes) can NEVER run in the exact mode it's for.
**This invalidates the build-45 assumption** (memory/web-research said "isScrollEnabled=false leaves panGestureRecognizer firing our target" — Apple docs implied it, DEVICE DISPROVES it). The `gr:winner` instrumentation (#90) shows `UIScrollViewPanGestureRecognizer delegate=PaneTerminalView state=2` fired 132x, but those are localScroll-mode drags; in appOwnsInput our target gets nothing.
**Fix direction (needs systematic-debugging + likely a design decision):** own the alt-screen drag with a mechanism that survives `isScrollEnabled=false`. Options: (a) our OWN `UIPanGestureRecognizer` added to the view (not the scrollview's inherited pan), enabled in `.appOwnsInput`, requiring the scroll pan to fail; (b) keep `isScrollEnabled=true` in appOwnsInput but intercept/consume the scroll delta before it moves content (translate to arrows, prevent native scroll). Both have risks (the redesign spec deliberately avoided a custom pan = the "straddle"; option b may fight native scroll). This is the crux of making alt-screen scroll actually work. The DETECTION is ready and waiting for it.

### #2 Arrow keys do not repeat (single press, seen in less)
Almost certainly a SYMPTOM of #1: with `handleScrollViewPan` dead in appOwnsInput, the `.changed`-phase arrow STREAM (`AltScreenScroll.arrows` emits runs across the drag) never runs. The few arrows the user saw were likely keybar taps or a one-shot path. VERIFY after #1: a real alt-screen drag should stream many `send-keys ... 1b 5b/4f 41/42` over the drag (the `.changed` loop, emittedCells threaded). If arrows STILL don't repeat after #1, investigate `AltScreenScroll.arrows` run-generation + `encodeArrowRun` (Kit, Linux-testable).

### #3 [WORKING] Regular terminal (shell/localScroll) scroll works
Confirms the diagnosis: `localScroll` keeps `isScrollEnabled=true` -> native SwiftTerm scroll fine. Only the `isScrollEnabled=false` modes (appOwnsInput) are broken. Not a bug; a control.

### #4 Keybar height not subtracted from terminal rows (cursor hidden behind keybar)
The keybar is one row tall (recent change/break) but the terminal grid does NOT reserve space for it, so the bottom terminal row (and the cursor) sits BEHIND the keybar. This is a layout/inset bug: the terminal's available height for grid-rows computation isn't subtracting the keybar (inputAccessoryView) height. Separate subsystem from gesture/mode. Trace shows fluctuating grid sizes: `75x40`, `75x47`, `75x74`, `75x39`, `rows=40`, `rows=23` (col=75 mostly). Look at where rows are computed from view bounds vs the keybar accessory height; `refresh-client -C <w>x<h>` is what tmux is told (saw `80x24` prime + `75x40` etc). The keybar is the terminal's `inputAccessoryView` (installed in TerminalScreen/TmuxPaneContainer makeUIView).

### #5 Column count looks off (rendering "minoring"/mirroring, screens look off)
Col count mismatch: `75` cols recurred but sizes fluctuated (`75x40/47/74`, also `41x47`, `33x47`, `80x40`). Possibly related to #4 (same size-calc path) or a resize/reflow race (multiple `refresh-client`/resize events). Needs a focused look at the width->cols computation and whether a stale/wrong col count reaches tmux (`refresh-client -C`) or SwiftTerm. Could be the fluctuation itself (grid resized many times mid-session) causing reflow artifacts. Lower confidence on root cause; gather more trace (a clean connect + note the rendered col width vs `refresh-client -C` value).

## Key code locations
- Mode->ownership flip: `App/TerminalScreen.swift:74-78` (`onChange`: `isScrollEnabled`, `allowMouseReporting`) + the `App/TmuxPaneContainer.swift` twin (~line 74-84).
- Drag handler: `App/TerminalGestureController.swift` `handleScrollViewPan` (rides `view.panGestureRecognizer` via addTarget in `installOurRecognizers`; `.began` snapshots `dragMode = callbacks.currentMode()`; `.changed` emits `AltScreenScroll.arrows` when `dragMode == .appOwnsInput`). The `gr:winner` + `addGR:` instrumentation is here + `PaneTerminalView`.
- `currentMode` wiring (correct, reads per-pane): `TerminalScreen.swift:146` (`modeTracker.mode`), `TmuxPaneContainer.swift:275` (`modeTracker.mode(for: pane)`).
- Keybar accessory install: TerminalScreen/TmuxPaneContainer `makeUIView` (`inputAccessoryView` / `keybarAccessory`).

## RESUME PLAN (fresh context)
1. **#1 is the priority** and the hardest: systematic-debugging on isScrollEnabled-vs-drag-ownership. Decide the ownership mechanism (own-pan vs intercept-native). This is the last thing between "detection works" and "scroll works". Likely a small spec (the redesign spec's §4 ownership section is now contradicted by device reality).
2. #2 verify-after-#1 (probably auto-fixed).
3. #4 + #5 are layout/size bugs, likely share a size-computation root; can be one investigation. #4 (keybar height) is concrete and high-value (cursor hidden is bad UX).
4. Consider grouping: (#1+#2 = alt-screen scroll) as one fix; (#4+#5 = terminal sizing/layout) as another.

See memory: [[altscreen-consume-once-overcorrection]] (detection fix, now SHIPPED+working), [[altscreen-scroll-and-diagnostics-rootcause]] (the whole arc), [[iterm2-tmux-cc-design-lessons]] (hardening backlog). Build facts + syslog-read in [[session-resume-2026-07-13]].
