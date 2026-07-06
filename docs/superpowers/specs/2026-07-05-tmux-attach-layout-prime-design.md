<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# tmux attach-time layout prime — design

**Date:** 2026-07-05
**Status:** approved (design), pre-implementation.
**Triggered by:** on-device TestFlight build #14 diagnostic — connecting shows a blank terminal + no keyboard, with the diagnostic overlay reading `tmux: attached · sess=semicolyn · wins=0 · active=nil · layout=NO · panes=0 · rx=…`.

## Problem (root cause, confirmed on device)

`tmux -CC new-session -A -s semicolyn` **attaches** (control-mode channel opens, `sess=semicolyn`, bytes flow) but tmux emits **zero** `%window-add` / `%layout-change` events for the session — so `TmuxSessionState` has `windows=[]`, `activeWindow=nil`, and no `visibleLayout`. The renderer's guard (`TmuxPaneContainer.apply`) bails when `activeWindow`/`window`/`visibleLayout` is nil, so **no pane view is created** — which means both **no terminal content AND no keyboard** (the pane view is the first responder; no view → no keyboard).

The app *does* have a layout-priming command — `refresh-client -C <WxH>` — but it is only sent via the **render path** (`onTmuxResize` → `setClientSize`), which fires when `TmuxPaneContainer` measures its bounds. That container only renders when a visible layout exists. So:

> **Deadlock:** no windows → no pane container → no resize → no `refresh-client` → tmux never (re)emits layout → no windows.

tmux `-CC` does not spontaneously replay window/layout state on attach to a session that already exists; the client is expected to ask. The app never asks outside the render path, so on a real server (where the session persists or other sessions exist) the grid stays blank.

## Fix — prime the layout the moment control mode attaches

Send layout-discovery commands **as soon as lifecycle transitions to `.attached`**, independent of the render path, breaking the deadlock. Two commands (belt-and-suspenders across tmux versions):

1. **`refresh-client -C 80x24`** — nudges tmux to emit the current window's `%layout-change` (works on most builds). The default `80x24` is corrected by the real `refresh-client -C <actualWxH>` once the pane container measures.
2. **`list-windows -F "#{window_id} #{window_active} #{window_layout}"`** — explicit window + layout discovery. Its `%begin/%end` reply is parsed into window/layout state, so windows populate even if `refresh-client` alone doesn't dump layout on a given tmux build.

### Decisions locked

| Decision | Choice |
|---|---|
| When to prime | On the `.attaching → .attached` lifecycle edge, exactly once. |
| Priming commands | Both `refresh-client -C 80x24` AND `list-windows -F …` (robust across tmux versions). |
| Where the prime is *decided* | In the pure `TmuxSessionController` (returns the commands to send at the edge), so it stays I/O-free and unit-testable. |
| Where the prime is *sent* | In `TmuxRuntime` (owns the channel writer), which also tracks the `list-windows` command id and applies its reply. |
| Default prime size | `80×24` (the same seed the controller/session already assume); corrected by the first real resize. |
| Diagnostic overlay | **Kept** through this fix so on-device we confirm `wins` goes non-zero; removed in a follow-up. |

## Components

**Pure Kit (Linux-tested):**

- **`TmuxSessionController`** — detect the `.attaching → .attached` edge inside `feed()` and surface the prime commands to send. Add to `TmuxControllerOutput` a field like `attachedPrimeCommands: [String]` (empty except on the edge), or a dedicated `justAttached: Bool` that the runtime turns into commands. Prefer returning the command strings so the controller owns "what to send on attach". The commands are:
  - `refresh-client -C 80x24`
  - `list-windows -F "#{window_id} #{window_active} #{window_layout}"`
  Emitted exactly once (guard so a later `feed` doesn't re-emit).

- **`parseWindowListing(_ lines: [String]) -> [ParsedWindow]`** (new pure function, mirrors `parsePaneCommandListing`). `ParsedWindow` = `(id: WindowID, active: Bool, layout: PaneLayout)`. Parses `#{window_id} #{window_active} #{window_layout}` lines; a malformed/unparseable line is skipped (best-effort), not fatal. `window_layout` is tmux's layout string, parsed via the existing layout parser.

- **A way to apply parsed windows into `TmuxSessionState`** — either the controller exposes an `applyWindowListing([ParsedWindow])` that appends windows + sets `activeWindow` + `visibleLayout`, or the existing event-application path is reused by synthesizing `windowAdd`/`layoutChange`/`sessionWindowChanged` events. Prefer synthesizing events so all state mutation stays in the one `apply(event:)` path (single source of truth), and the reply parser just maps lines → events.

**App tier (macOS-CI-verified):**

- **`TmuxRuntime.ingest`** — after `feed`, if the output carries prime commands, `write` each (the `refresh-client`) and `writeTracked` the `list-windows` (recording its id in a `primeWindowIDs` set, mirroring `contextPollIDs`). When a `resolved` command matches `primeWindowIDs` with `.ok(lines)`, run `parseWindowListing` → synthesize + apply the window/layout events → fire `onStateChanged` so the renderer picks up the now-populated layout.

## Data flow

```
attach (open_exec "tmux -CC new-session -A -s semicolyn")
  → controller.feed(...) sees %begin/%end of the new-session, lifecycle .attaching→.attached
  → controller returns prime commands: [refresh-client -C 80x24, list-windows -F ...]
  → runtime writes refresh-client (nudge) + writeTracked(list-windows) [id stored]
  → tmux replies:
       (a) possibly %layout-change from refresh-client  → applied via existing path
       (b) %begin … window rows … %end for list-windows  → resolved with .ok(lines)
  → runtime: parseWindowListing(lines) → synthesize windowAdd/layoutChange/sessionWindowChanged
       → controller.apply(each) → state.windows>0, activeWindow set, visibleLayout set
  → onStateChanged → TmuxPaneContainer renders panes → becomeFirstResponder → keyboard
```

## Error handling / edges

- **Empty session (no windows):** `list-windows` returns zero rows → state stays empty. That is a genuinely empty session; acceptable (rare — `new-session -A` creates a window if none exists, so there is normally ≥1).
- **`refresh-client` unsupported / no-op:** covered by the `list-windows` path (the whole point of sending both).
- **Malformed layout string:** `parseWindowListing` skips that window (best-effort); other windows still render.
- **Re-attach (crash-recovery `reattachTmux`):** goes through the same `attachTmux` → same prime, so recovery also populates layout. ✓
- **Prime fires once:** guard the edge so a subsequent `feed` (more bytes) does not re-send the prime.

## Testing (pure Kit, TDD; per the repo testing standards)

- **Prime-on-edge:** feed a stream that drives `.attaching → .attached`; assert the controller output carries exactly the two prime commands, once. A later `feed` with more bytes carries none. (BVA on the edge.)
- **`parseWindowListing`:** EP — single window; multi-window (one active); a zoomed window; a malformed line mixed with valid lines (malformed skipped, valid parsed). Assert the exact `[ParsedWindow]` (ids, active flag, parsed layout), not just non-empty.
- **End-to-end (the bug):** feed an attach stream with **no spontaneous `%window-add`/`%layout-change`**, then feed the `list-windows` `%begin/%end` reply; assert `state.windows.count > 0`, `state.activeWindow != nil`, and the active window's `visibleLayout != nil`. This test fails on today's code and passes with the fix.
- **Idempotence / no double-apply:** applying the same `list-windows` reply twice does not duplicate windows.

## Out of scope

- The tmux **multi-session** UX (choosing among several server-side sessions) — not needed; `-s semicolyn` targets one session.
- Removing the diagnostic overlay — a follow-up once on-device confirms `wins>0`.
- The attach-failure classification refinement (`.attaching`-EOF → raw fallback) — a separate, smaller improvement tracked independently; this spec is specifically the blank-panes (zero-windows) fix.

## Relationships

- Builds on the tmux control-mode stack (`TmuxSessionController`, `ControlModeParser`, `TmuxSessionState`, `TmuxRuntime`) and mirrors the existing `list-panes` context-poll reply-parse pattern (`parsePaneCommandListing` + `contextPollIDs`).
- The diagnostic overlay added in PR #48 (`TmuxRuntime.onDiagnostic`) is the instrument that confirmed this root cause and will confirm the fix.
