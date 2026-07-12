<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Spec B: Terminal Gesture Cleanup + Categorized Diagnostic Logging

**Status:** design, approved for planning (2026-07-12).
**Predecessor:** Spec A (tmux -CC native scrollback, shipped PR #81) + the mouse-forward
gate fix (PR #83). Those closed the "can't scroll" root cause; this spec finishes the
gesture cleanup and adds durable diagnostic coverage.

## Goal

Close the remaining terminal-gesture bugs surfaced by the TF35/TF37 device traces, and
make future device-troubleshooting self-serve by adding **categorized, user-selectable
diagnostic logging** across the App tier — so we stop the reactive "add a log → rebuild →
re-test" loop.

## Background / evidence

The TF35 trace (`gesture-trace-diagnosis-2026-07-11`) root-caused four gesture failures.
The #1 cause (mouse-mode drags forwarded to tmux instead of scrolling) is FIXED in PR #83
(gate `allowMouseReporting` on `isCurrentBufferAlternate`, not `mouseMode != .off`). The
remaining three are confirmed still present in source:

1. **Stuck selection** — `TerminalGestureController.handleSingleTap` places the cursor but
   never clears an active selection, so a tap can't dismiss a selection block.
2. **Render storm** — `TmuxPaneContainer` render + `tmux:render` log fire on every
   `onStateChanged`, even when nothing visually changed (dozens of identical renders per
   trace).
3. **Window-tab switch** — tapping a window tab may not switch/redraw the active window;
   the trace couldn't tell whether the tap failed to reach `selectWindow` or tmux's reply
   wasn't applied.

The recurring meta-problem: each device bug required adding logs, rebuilding, and
re-testing, because instrumentation was sparse and uncategorized. This spec fixes that by
making comprehensive logging a first-class, filterable feature.

## Architecture — three layers, built in order

### Layer 1 — Logging infrastructure (`LogCategory` + Diagnostics UI)

A `LogCategory` enum plus per-category enable/disable, persisted like the existing
keystroke-content toggle and **user-selectable in Settings → Diagnostics**.

```swift
// App/RemoteLogConfig.swift (or a sibling — App-tier, UI/diagnostics wiring)
enum LogCategory: String, CaseIterable, Sendable {
    case lifecycle   // connect/attach/disconnect, app fg/bg, transport switch
    case connect     // auth, hostkey, mosh fallback, reconnect
    case tmux        // control-mode send / %reply / state-apply / pane register
    case render      // pane/window render — LOG-ON-CHANGE only (Layer 2 Fix 2)
    case gesture     // tap/pan/long-press/pinch handlers + classify decisions
    case input       // keystroke STRUCTURAL events (length/backspace/modifier), NOT content
    case predictor   // suggestion lifecycle + secret-exclusion gates
    case keybar      // accessory sizing, macro resolution, live-edit apply
    case seed        // tmux history seeding (applyHistory pre/post) — recategorized
}
```

**`DebugLog.log` gains a category (default `.lifecycle` for back-compat):**
```swift
func log(_ category: LogCategory = .lifecycle, _ message: @autoclosure () -> String)
```
The gate becomes `guard enabled, isEnabled(category) else { return }` — evaluated BEFORE
the autoclosure runs, preserving the zero-cost sacred-path guarantee (no string built when
the category is off). `isEnabled` reads a cached `Set<LogCategory>` refreshed when settings
change (not a per-call UserDefaults read).

**Defaults** (low-volume/high-value ON; high-volume/niche OFF):

| Category | Default | Rationale |
|---|---|---|
| `.lifecycle` | ON | Spine of any trace; near-zero volume |
| `.connect` | ON | #1 "won't connect" complaint; low volume |
| `.tmux` | ON | Most tmux bugs live in the command round-trip; moderate |
| `.gesture` | ON | Current debugging area; fires only on touch |
| `.seed` | ON | New + actively verified; low volume |
| `.render` | OFF | High volume (the storm) — opt-in |
| `.input` | OFF | Per-keystroke high volume — opt-in |
| `.predictor` | OFF | High volume, niche |
| `.keybar` | OFF | Niche layout debugging |

A fresh Diagnostics session therefore yields a useful trace immediately; the noisy
categories are opt-in.

**Diagnostics UI** — a new "Log categories" section in `DiagnosticsSettingsView`, one
`Toggle` per `LogCategory.allCases`, each backed by `@AppStorage("diagnostics.logcat.<rawValue>")`
seeded to the default above. Mirrors the existing keystroke-content toggle pattern. The
existing keystroke-content toggle stays as-is — it is an orthogonal content-vs-structure
switch layered on top of `.input` (content still requires BOTH `.input` on AND the
keystroke-content nag confirmed).

### Layer 2 — The three gesture fixes (categorized as they land)

**Fix 1 — clearSelection on single-tap.**
- Add a `clearSelection: () -> Void` callback to `TerminalGestureController.Callbacks`,
  wired at both mounts (`TerminalScreen` + `TmuxPaneContainer` coordinators) to
  `terminalView.getTerminal().clearSelection()`.
- In `handleSingleTap`: if a selection is active, call `clearSelection()` and RETURN
  (the tap dismissed the selection); else place the cursor as today.
- Pure decider in SemicolynKit: `func tapAction(hasSelection: Bool) -> TapAction` where
  `TapAction = .clearSelection | .placeCursor`. EP-tested (selection → clear; none →
  place). App wiring stays thin; the controller calls the decider then dispatches.
- Emits `.gesture`: `gesture:singleTap action=<clear|place> at=(col,row)`.

**Fix 2 — render-storm dedup (log-on-change).**
- Pure `RenderSignature: Equatable` in SemicolynKit, derived from `TmuxSessionState`
  (active window id + window-id list + per-window `visibleLayout` pane-set/geometry
  fingerprint). Two states with the same signature render identically.
- `TmuxPaneContainer`/`ConnectionViewModel.onStateChanged` keeps the last-applied
  signature; if the new signature equals it, SKIP the render AND its log. On a real
  change, render and emit `.render`: `render:apply reason=<active|windows|layout>`.
- EP tests: equal state → equal signature (skip); changed active/windows/layout → differs
  (render), one representative per field.
- This single change IS both the perf fix and the diagnostic (the log now marks only real
  renders, with the reason).

**Fix 3 — window-tab switch (instrument-then-fix).**
- Instrument every hop with `.gesture`/`.tmux` logs: `WindowTabStrip.onSelect` →
  `vm.selectWindow` (has `win:select`) → `TmuxRuntime.selectWindow` command-sent → the
  control-mode `%window-changed` / active-window parse → `activeWindow` state-apply →
  render (via Fix 2, reason=`active`).
- The spec commits to the instrumentation now, plus the LIKELY fix: ensure the
  `select-window` reply updates `tmuxState.activeWindow` and produces a render. If a fresh
  trace (now available thanks to the instrumentation) shows the tap never reaches
  `selectWindow`, the fix moves to the `WindowTabStrip`→`onSelect` wiring instead. Either
  way the diagnostic hops are permanent (Layer 3 coverage), so this can't regress silently.

### Layer 3 — App-tier diagnostic coverage audit (logs-only, zero behavior change)

Systematically ensure every meaningful **boundary** in `App/` emits one categorized log
line. This is additive instrumentation only — NO behavior changes (the only behavior
changes in Spec B are the three Layer-2 fixes).

**A "boundary" is:**
- A state transition (a stored/`@Published` property that drives behavior changes value).
- An external-call crossing (send to tmux/SSH/mosh, a UniFFI call, a callback firing into
  or out of the file).
- A decision fork (an early-return guard or a branch on transport/mode that changes what
  happens).
- A failure/fallback (catch blocks, error-masking nil-coalescing, degraded paths).

**Per-category coverage targets:**

| Category | Boundaries to cover |
|---|---|
| `.lifecycle` | connect start/success/fail, attach tmux/raw/mosh decision, disconnect, app fg/bg, transport switch |
| `.connect` | hostkey verdict, each auth attempt + outcome, mosh probe/fallback, reconnect trigger + result |
| `.tmux` | every command send, every `%`-event parsed, each state-apply, pane register/unregister |
| `.render` | log-on-change only (Fix 2) |
| `.gesture` | each recognizer fire + its classify decision + action taken (place/scroll/switch/zoom/select) |
| `.input` | keystroke structural events (length, backspace, modifier); content stays behind the existing separate toggle |
| `.predictor` | suggestion surface/accept/reject, each secret-exclusion gate that fires |
| `.keybar` | accessory sizing recompute, macro resolution, live-edit apply |
| `.seed` | recategorize the existing `applyHistory` pre/post lines under `.seed` |

**Coverage discipline (so it is "done," not "sprinkled"):**
- The implementation plan enumerates the in-scope `App/*.swift` files (fixed list generated
  at plan time via `git ls-files App/*.swift`); each file is a checklist item: "audit
  boundaries, add missing categorized logs."
- **Log-line style convention** (spec-mandated, for grep-friendly traces):
  `"<category>:<event> key=value key=value"`; identifiers always rendered `%N` (pane) /
  `@N` (window); one line per boundary; no multi-line messages.
- **Scope boundary (YAGNI):** the audit covers `App/` ONLY. `SemicolynKit` (pure,
  Linux-tested) does NOT log — it returns values the App logs at the boundary. Matches
  CLAUDE.md's "log at orchestration boundaries, not inside reusable utilities."
- **Migration:** existing uncategorized `DebugLog.shared.log("…")` calls keep working via
  the `.lifecycle` default; the audit re-categorizes them as it touches each file.

## Components / units (each independently testable)

**SemicolynKit (pure, Linux-tested):**
- `TapAction` + `tapAction(hasSelection:)` — the tap decider (Fix 1).
- `RenderSignature` + its derivation from `TmuxSessionState` (Fix 2).

**App (macOS-CI-gated):**
- `LogCategory` enum + `DebugLog` category gate + cached enabled-set (Layer 1).
- `DiagnosticsSettingsView` "Log categories" section (Layer 1 UI).
- `TerminalGestureController` clearSelection wiring (Fix 1).
- `TmuxPaneContainer`/`ConnectionViewModel` signature-gated render (Fix 2).
- Window-tab hop instrumentation + fix (Fix 3).
- The coverage audit across enumerated `App/` files (Layer 3).

## Data flow

- **Tap:** recognizer fires → `tapAction(hasSelection:)` (Kit) → App clears selection OR
  places cursor → `.gesture` log.
- **State change:** tmux `%event` → `TmuxSessionState` → `RenderSignature` compare (Kit) →
  render + `.render` log ONLY if changed.
- **Window tab:** tap → `onSelect` → `vm.selectWindow` → tmux `select-window` →
  `%window-changed` → `activeWindow` apply → signature changes (reason=`active`) → render.
  Every hop logged.
- **Log emit:** any `DebugLog.log(cat, …)` → gate on `enabled && isEnabled(cat)` → panel
  buffer + `os.Logger` + remote sink (unchanged transport).

## Error handling

- Category gate is fail-safe: an unknown/missing `@AppStorage` key falls back to the
  category's compiled-in default.
- The render-dedup MUST NOT skip a needed render: the signature includes every field that
  affects layout; a conservative miss (rendering when unchanged) is acceptable, a false
  skip (not rendering a real change) is not — tests assert each changed field forces a
  differing signature.
- Coverage audit adds no error paths (logs-only).

## Testing

- **Kit (Linux, real tests):** `tapAction` EP (has/none). `RenderSignature` EP+boundary:
  equal state equal; each of {active changed, windows added/removed, layout/pane-set
  changed} produces a differing signature; one representative per field, asserting the
  exact equality/inequality.
- **App (macOS CI + device):** category gate compiles + toggles; the three fixes verified
  on-device via the new categorized trace (tap dismisses selection; renders drop to
  real-changes-only; window-tab hops appear and the active window changes). No App unit
  tests (two-tier rule); device trace is the behavioral gate.

## Out of scope

- The mouse-gate fix (PR #83, already shipped).
- A user-facing Auto/Always/Never mouse-reporting SETTING (deferred until a normal-screen
  mouse-TUI need arises — the alt-screen auto-gate is the iTerm2/WezTerm default).
- Any `SemicolynKit` logging (pure tier stays log-free by design).
- Non-gesture UX items (auto-reconnect, disconnect-button redesign) — separate specs.

## Self-review notes

- No placeholders: Fix 3's "instrument-then-fix" is a deliberate evidence-gated seam with a
  stated likely fix + fallback, not a TBD.
- Consistency: the render-dedup (Fix 2) and the `.render` category (Layer 1) are the same
  mechanism, described once as log-on-change; `.seed` recategorization is noted in both
  Layer 1 and Layer 3.
- Scope: one plan's worth — three surgical fixes + one infra addition + a bounded,
  file-enumerated audit. The audit is mechanical and additive, so it doesn't balloon the
  plan's risk.
