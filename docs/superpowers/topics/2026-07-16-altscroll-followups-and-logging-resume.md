<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Alt-scroll device-feedback followups + logging rework (RESUME, 2026-07-16)

Written before a `/clear` (large context). Picks up after the app-aware alt-scroll feature
(#96) shipped and the crash-fix/diagnostics round (#97) shipped, both on `main`.

## IMMEDIATE NEXT TASK (user-directed): logging rework FIRST, then retest

The user has hit "logs insufficient to reconstruct what I did" THREE times. Logs record
outputs/events, not the inputs/state at decision points, so every bug needs a fresh
diagnostic + a device round-trip. **Promote the decision-point logging standard to the
immediate task** (memory: `decision-point-logging-standard`). Concretely for the gesture path:
- ONE line per drag that is self-evident: `drag pane=%N mode=X app=<cmd> winner=<recognizer> keys=<arrows|pageKeys> emitted=<n> outcome=<scroll|select|mouse|nothing>`.
- A user-action / session marker so a trace replays without narration.
- Log mode + resolved-command AT the drag `.began`, not as separate correlated lines.
- The goal the user stated: "the logs should be self-evident" — reconstruct the session without the user narrating.
Then the user does ONE clean scripted retest and we fix B-remainder/C/D from a trace we can actually read.
This is a brainstorm-worthy design task (standard + a sweep of decision points), not a quick patch.

## STATE OF THE 4 ISSUES (from build-51 device trace, log data/syslog/*2026-07-16*, ~08:03-08:05)

### A [FIXED, on main a960f08/2b4835a] settings crash
Opening Settings>Experimental in-session crashed: @EnvironmentObject TerminalSettingsStore
not injected into the in-session Settings sheet -> fatalError. Fixed: all 3 settings views
(Experimental/Terminal/font-picker) read AppStores.shared.terminalSettings via @ObservedObject.
DEVICE-CONFIRMED no crash (user went to options/experimental, no crash).

### B [PARTIAL FIX committed, branch fix/altscroll-b-context-and-logging 87a02e8; NOT fully fixed]
Claude drag emits arrows not PgUp/PgDn. TWO causes found:
1. [FIXED 87a02e8] vm.paneContexts is FILTERED to renderablePanes, so dragging Claude pane %0
   got cmd=nil while the poll reported %0:claude. Fix: vm.tmuxPaneCommand(pane) reads the
   runtime's COMPLETE map (tmux?.paneContext(pane)); alt-scroll callback uses it.
   (Earlier truncation/list-panes theories were WRONG — the poll returns all 9 panes fine;
   the 80-char log preview hid them. The context REPLY shows: %0:claude %10:bash %6:bash
   %8:bash %12:claude %14:claude %4:claude %5:python3 %16:less/bash.)
2. [NOT FIXED] Device shows Claude pane %0 classifies as **.mouseReporting** (not
   .appOwnsInput). In mouseReporting, altPan is disabled and the drag is forwarded to
   SwiftTerm as SGR mouse -> the app draws it as a **selection** (this is the "selection
   issue came back" the user saw when scrolling Claude in PgUp/PgDn mode — NOT the old
   UITextInteraction bug; zero sel:/setSelectionRange events fired). REMAINING FIX candidate:
   extend app-aware PgUp/PgDn into .mouseReporting for registered apps (claude/gemini/codex/
   qwen) so their drag scrolls instead of mouse-selecting. Decide after the logging rework +
   a clean retest confirms the mode classification.

### C [gain FIXED on main; MOMENTUM still open] less scroll feel
scrollGain=2.5 (main) made it faster, but user reports still "stiff/tight/awkward, no
momentum". Remaining: flick/inertia (decaying arrow/page tail on fast lift). App-side timer.

### D [ROOT-CAUSED, not fixed] terminal redraw width off
sizing:tmux logs: bounds.width=402 STABLE, but cell.w DRIFTS (5.0->grid 80x39; 4.8->grid
83x79) while tmux renders the window at 89 (layout-change ...89x40; cell should be ~4.52).
ROOT CAUSE (user's instinct, confirmed): zoom is CONTINUOUS (handlePinch sets
fontSize=clampFont(base*scale), clampFont only clamps 7...24, no stepping), so a fractional
font size yields a fractional cell.w and 402/cell rounds unpredictably (80/83/89). The
resolvedCell() readback (optimal.width/term.cols) drifts with the stale col count.
USER SUGGESTION (good): discretize/quantize zoom levels (or round cell.w to whole points) so
bounds/cell gives a stable integer col count matching what SwiftTerm renders. CAUTION: this
is the grid code with a documented "1xN collapse" history — change carefully + test.
OPEN QUESTION: is 80 (our bounds) or 89 (tmux) the CORRECT width? Maybe tmux holds 89 for
another attached client (window-size policy). Check before forcing either.

## UX notes (user, build 51) — Experimental settings screen
- The Experimental items (alt-scroll options + Diagnostics) should be on ONE screen, NOT
  nested (Diagnostics is currently a nested NavigationLink like the old logging nesting).
- The "Alt-screen scroll" Section HEADER looks like a selectable/tappable option but isn't —
  confusing presentation. Restyle so the header reads as a label, not a row.
  (File: App/ExperimentalSettingsView.swift — inline Picker inside a Section with a header.)

## EXACT USER TEST ACTIONS (build 51, so the trace is interpreted correctly)
1. Tried to scroll in Claude -> FAILED (still history/no scroll).
2. Switched to a terminal window, scrolled -> SUCCESS (localScroll).
3. Scrolled in less -> worked but STIFF/TIGHT/AWKWARD, no momentum.
4. Went to Options -> NO crash; went to Experimental; selected PgUp/PgDn (alwaysPageKeys).
5. Tried scrolling* in Claude with PgUp/PgDn -> the SELECTION issue was back (screen selection
   on drag). [*user clarified: scrolling, not zooming.]

## Git / build state
- main = 2b4835a (A crash fix + C gain + B/D diagnostics; all merged, CI green, TF build 51 = this trace).
- B partial fix committed on branch `fix/altscroll-b-context-and-logging` (87a02e8), NOT pushed/merged.
- Monitor task was watching data/syslog for B/D lines (may need re-arming next session).
- Untracked .idea/.vscode appeared in the repo (consider gitignoring; not this task).

## RESUME ORDER (next session)
1. **Logging rework** (brainstorm -> spec -> implement the self-evident gesture/decision logging + session markers). This is the user's explicit priority and unblocks everything.
2. Rebuild TF, user does ONE clean scripted retest -> a readable trace.
3. From that trace: finish B (mouseReporting+AI-CLI -> PgUp/PgDn), decide D (quantize zoom vs force width), C momentum.
4. UX: flatten Experimental + fix the header-looks-tappable.
See memory: [[decision-point-logging-standard]], [[session-resume-2026-07-15]], and the #96/#97 arc.
