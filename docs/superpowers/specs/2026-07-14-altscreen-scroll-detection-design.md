<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Alt-screen scroll: detection reconcile + drag-swallow diagnosis

**Written:** 2026-07-14, after three build-45 device traces (Claude, htop, less) isolated
two distinct bugs behind "alt-screen drag→arrows doesn't scroll." Extends the interaction-mode
redesign (`2026-07-12-terminal-interaction-mode-design.md`). Grounded in captured syslog evidence,
not conjecture.

> **Scope discipline:** this spec FIXES Bug A (fully proven) and DIAGNOSES Bug B (instrumentation
> only, so the follow-up fix targets the confirmed culprit rather than a third guess). It does NOT
> fix Bug B. `less` scroll is explicitly out of scope (not our bug: see §6).

## 1. The two bugs (evidence)

The interaction-mode redesign resolves each pane to `localScroll` / `appOwnsInput` / `mouseReporting`
via `resolveMode(isAltScreen:mouseReporting:)`. Alt-screen panes should get `appOwnsInput`, where a
vertical drag becomes arrow-key runs (xterm `alternateScroll` `?1007`: the documented, standard
mechanism, confirmed to target less/vim/htop). Three device traces proved two independent failures.

**Bug A: alt-screen not detected under shared/attach tmux -CC.**
semicolyn runs `tmux -CC new-session -A -s <name>`; when a session of that name already exists (the
user's own native session), the -CC client ATTACHES to it. An app already on the alternate screen
*before* attach never re-sends `?1049h` to our client. Trace: across the entire 248 KB session, the
Claude pane `%0` received **zero** `?1049` and only ever resolved to `mouseReporting`/`localScroll`,
never `appOwnsInput` → the drag went out as 349 SGR mouse events, 0 arrows. tmux DID forward
mouse-mode (`?1000/1002/1006h`) but NOT alt-screen. **The per-pane emulator flag
`isCurrentBufferAlternate` is unreliable for the attach-into-existing-alt-screen case.**

Crucially, the htop and less traces proved the emulator flag IS correct when semicolyn witnesses the
transition LIVE: launching htop/less while connected forwarded `?1049h`/`?1049l` via `%output`, and
`mode[%11] -> appOwnsInput` / `-> localScroll` fired at exactly the right moments. So Bug A is
SPECIFICALLY the pre-attach case.

**Bug B: the drag never reaches our handler in `appOwnsInput`.**
On htop and less the mode resolved CORRECTLY to `appOwnsInput`, yet across many drags there were
**0 `gr:scrollPan began`** lines and **0 arrow sends** from the drag (the few arrows in the less
trace were keybar taps, confirmed by the user: a real drag streams many small `.changed` sends).
The `addGR:` instrumentation (from #90) shows `delegate=nil` UIKit pans present at alt-screen entry:
`_UIDragAutoScrollGestureRecognizer delegate=nil` (UIKit drag-and-drop auto-scroll) and a
`UIPanGestureRecognizer delegate=nil` (SwiftTerm's lazily-created pan). `delegate=nil` makes them
invisible to our simultaneity delegate (#89) and unreachable by `editingInteractionConfiguration`
= `.none` (#90). One of them appears to win the drag before our scroll-pan target fires.

## 2. Non-goals / rejected

- **`%layout-change` as an alt-screen trigger: REJECTED.** The traces prove it does NOT fire on
  alt-screen enter/exit: htop's `?1049h` at t=8.21 and `?1049l` at t=15.12 had NO accompanying
  `%layout-change` (those fired only during early pane setup, t from 3.1 to 3.5). `%layout-change` tracks
  pane GEOMETRY (splits/resizes/zoom), not the alternate buffer. Using it would miss every alt-screen
  transition.
- **Wall-clock polling: REJECTED.** A 1 s per-pane `list-panes` poll is battery/data/log-noise for a
  state that changes a few times a session. Unneeded: attach-query + live `?1049` events cover it.
- **After-keyboard re-query: REJECTED (for now).** Redundant with live `?1049` forwarding (a keystroke
  that toggles alt-screen also emits `?1049` → emulator updates → recompute). Add later only if a real
  gap appears.
- **Fixing Bug B in this build: DEFERRED.** We have been wrong about the culprit recognizer twice
  (#89 SwiftTerm selection pan, #90 UITextInteraction). This build instruments to CONFIRM which
  recognizer wins; the fix ships next, targeting the proven culprit.
- **`less` drag-scroll: OUT OF SCOPE.** Blink (a mature reference client) also does not scroll `less`
  by drag; `less` + mouse-mode ignores the input. Not our bug. htop/vim/Claude are the real targets.

## 3. Part 1: Bug A fix: attach-time alt-screen reconcile

**Kit (Linux-tested), `Sources/SemicolynKit/Tmux/`:**

- `TmuxCommand.queryAlternateOn() -> String`: a new pure encoder returning
  `list-panes -a -F "#{pane_id} #{alternate_on}"`. Constant format string (no interpolated input),
  contains no `\n`/`\r` (framing-safe), mirroring the existing `listPaneCommands()` / `listWindowsForLayout()`.
- A pure parser (sibling to `parseWindowListing`) for the reply block: each line is
  `%<id> <0|1>`. Returns `[(PaneID, Bool)]`. Malformed lines fail closed (skipped / typed nil),
  never crash. EP+BVA covered in tests: alt=1, alt=0, several panes, a malformed line, an empty reply.

**Controller seam, `TmuxSessionController.feed`:**

- Add `queryAlternateOn()` to the `justAttached` prime command list (currently
  `["refresh-client -C 80x24", listWindowsForLayout()]`), so it's submitted the moment the session
  attaches: the one moment the emulator flag may be stale. Its reply resolves through the existing
  `submit`/`pending`/`resolved` FIFO correlation.

**App wiring, `TmuxRuntime` / `TmuxPaneContainer` / `PaneModeTracker`:**

- The runtime routes the query's resolved reply through the alt-screen parser and calls a new
  `PaneModeTracker.setAltScreenOverride(for: PaneID, isAlt: Bool)` per pane.
- `PaneModeTracker` gains a per-pane `altOverride: [PaneID?: Bool]`. `recompute(for:terminal:)` uses
  `altOverride[pane] ?? terminal.isCurrentBufferAlternate` as the `isAltScreen` input to `resolveMode`.
  The override is a ONE-TIME reconcile: it is CLEARED the first time a live `%output`-driven recompute
  for that pane observes a definite `isCurrentBufferAlternate` transition (i.e. once the emulator flag
  becomes trustworthy for that pane, the override steps aside). This prevents a stale override from
  pinning a pane to alt-screen after the app exits.
- Raw (non-tmux) panes never set an override → unchanged behavior.

**Data flow:** attach → `queryAlternateOn` submitted → tmux replies `%0 1 / %10 0 …` → parsed →
`setAltScreenOverride(%0, true)` → `recompute` resolves `%0` to `appOwnsInput` → drag→arrows path
becomes eligible (subject to Bug B).

## 4. Part 2: Bug B diagnosis: drag-time recognizer-state trace

**App (macOS-CI compile), `TerminalGestureController` / `PaneTerminalView`:**

Add drag-time recognizer-state instrumentation, active only when logging is on and the pane is
`appOwnsInput` (zero cost otherwise, per the `@autoclosure` gate):

- When a touch sequence begins on an `appOwnsInput` pane, enumerate `view.gestureRecognizers` and log
  each recognizer's class + `delegate`-class + `state` as it transitions, so the trace shows WHICH
  recognizer reaches `.began`/`.changed` and therefore owns the drag. Mechanism: add our controller as
  an extra `target`/`action` on each non-ours recognizer for the duration (or observe `.state` via KVO),
  whichever is the lighter touch. The deliverable is a `gr:winner <class> delegate=<class> state=<n>`
  line naming the swallower.
- This does NOT change routing or disable anything: pure observation. The follow-up fix (a separate
  spec/build) disables the CONFIRMED stray via the existing `PaneTerminalView.addGestureRecognizer`
  seam, extended to reach `delegate=nil` pans.

## 5. Testing

- **Kit (Linux, `swift test`):** `queryAlternateOn()` exact-string output; the `#{pane_id}
  #{alternate_on}` reply parser: EP (alt=1, alt=0), multi-pane, malformed line (typed skip, no crash),
  empty reply. `PaneModeTracker` override precedence: override present → used; override cleared after a
  live transition → emulator flag used again. Assert observable mode outputs, no tautologies.
- **App (macOS CI):** compile of the query wiring + the recognizer-state instrumentation.
- **Device (build 46):**
  1. Reconnect into a shared pre-existing session with Claude on alt-screen → syslog shows the
     `queryAlternateOn` reply and `mode[%0] -> appOwnsInput` (was `mouseReporting`). Bug A fixed.
  2. Drag on htop (mode already `appOwnsInput`) → the new `gr:winner …` line NAMES the recognizer that
     swallows the drag. Bug B culprit confirmed for the follow-up fix.

## 6. Follow-ups (separate specs)

- **Bug B fix**: disable the confirmed stray `delegate=nil` pan(s) so `handleScrollViewPan` fires in
  `appOwnsInput`; verify htop/vim/Claude drag→arrows scrolls on device.
- **Broader alt-screen drift**: if a future trace shows a transition tmux neither forwards nor exposes
  at attach, revisit an event-driven re-query (NOT wall-clock polling).
