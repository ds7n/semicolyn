<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# tmux -CC native scrollback (Spec A)

**Date:** 2026-07-11
**Status:** Approved (brainstorming), pending implementation plan
**Motivation:** On-device (TF33–TF35) the terminal gestures were broken; a remote-log
trace root-caused it. The core fact: **in `tmux -CC`, scrollback lives on the tmux
server, not the client.** `%output` is a forward-only live stream with no history
backfill, so a tmux pane's SwiftTerm buffer holds only the visible screen —
`contentSize=(0,0)` in the trace — and dragging its `UIScrollView` cannot scroll because
there is no local history. Our custom scroll layer was built on a false premise.

This spec makes scrollback work the way the two reference `-CC` implementations do it
(iTerm2's source + WezTerm PR #6602, confirmed at source level): **seed each pane's
history once via `capture-pane`, then let SwiftTerm's native buffer accumulate live
`%output` and scroll locally.** See the memory note `tmux-cc-scrollback-architecture`.

**Scope:** this is **Spec A** — the scrollback core only. A separate **Spec B** covers the
gesture cleanup (alt-screen mouse-gate, `clearSelection` on tap, tmux render-storm dedup,
window-switch / pane-zoom gestures). Consequence: after Spec A, scroll works on
**non-mouse** panes; mouse-mode panes complete in Spec B (the mouse-gate). That is an
acceptable intermediate state — plain shells are the common case.

**Related:** `App/TmuxPaneContainer.swift`, `App/TmuxRuntime.swift`,
`Sources/SemicolynKit/Tmux/ControlModeParser.swift` (already handles `%begin`/`%end`/
`%error` blocks), `Sources/SemicolynKit/Tmux/TmuxCommand.swift` (control-mode command
encoder), `TerminalSettings.scrollbackLines` (existing, default 5000, presets
[1000,2000,5000,10000,∞]).

## Problem

`tmux -CC` sends only live screen output via `%output`; the scrollback history stays on
the server (bounded by the server's `history-limit`). SwiftTerm scrolls its own local
buffer by mapping `contentOffset` → `yDisp` (its `contentSize` is
`displayBuffer.lines.count × cellHeight`). For a tmux pane that buffer is ~the visible
screen, so `contentSize≈frame` → nothing to scroll. The user cannot scroll back through
history at all.

Naive fixes fail: accumulating `%output` locally is **provably wrong** because tmux's
control-mode pause path (`control_check_age` → `control_discard_pane`) *permanently
discards* bytes when a client falls behind (`%pause`), then resumes at the pane's current
position — missed bytes are gone. On mobile (backgrounding, flaky links) `%pause` is
common. tmux's own FAQ: scrollback "is very likely to be incomplete."

## Goal

Give each tmux pane real, scrollable history that a normal touch drag scrolls smoothly —
matching a real tmux attach — by fetching history from tmux and rendering it in SwiftTerm's
native scrollback, then keeping it live and correct across pauses/reconnects.

Non-goals (→ Spec B): the alt-screen mouse-forwarding gate, `clearSelection`-on-tap, the
tmux render-storm dedup, and the window-switch / pane-zoom gestures. Also non-goals:
alt-screen history capture (`-a`), and any change to raw-PTY (non-tmux) scrollback (which
already works).

## Architecture

Three units.

```
CapturePaneCommand (SemicolynKit, pure)
  ├─ build: "capture-pane -p -e -S -<N> -t %<paneID>"  (N from scrollbackLines; no -J, no -a)
  └─ parse: a %begin/%end control-mode command-response block → history payload bytes
            (or a typed error on %error / malformed)

PaneSeedState (SemicolynKit, pure)
  └─ per-pane state machine: .unseeded → .seeding(pendingOutput:[…]) → .seeded
     - while .seeding: buffer live %output for that pane
     - on seed arrival: emit (historyBytes ++ bufferedOutput), go .seeded
     - .seeded: pass %output straight through
     - resync(): → .unseeded (next output re-triggers a capture)

PaneHistorySeeder (App, macOS-CI)
  ├─ on a pane's FIRST render (lazy): send CapturePaneCommand via TmuxRuntime,
  │  set PaneSeedState .seeding
  ├─ on the capture response: clear the pane's SwiftTerm scrollback (idempotent for
  │  reseed), feed(historyBytes), then feed(bufferedOutput), mark .seeded
  ├─ route %output through PaneSeedState (buffer during seed, else feed live)
  └─ resync trigger: %pause/%continue, reconnect, resize-desync → PaneSeedState.resync
```

**Removed:** the custom scroll layer in `App/TerminalGestureController.swift` /
`App/TmuxPaneContainer.swift` — specifically our repurposing of the native
`panGestureRecognizer` for scroll and any `contentOffset`-driven scrolling. Once a pane is
seeded, `displayBuffer.lines.count` is real → SwiftTerm's `contentSize` is non-zero → its
**own native** `UIScrollView` scroll works with an ordinary finger drag. (The
`handleScrollViewPan` window-switch target and the `mouseReportingActive` gate are
**retained for now** and reworked in Spec B; this spec only stops *fighting* native scroll.)

**Two-tier:** `CapturePaneCommand` + `PaneSeedState` are pure, Linux-tested. `PaneHistorySeeder`,
the SwiftTerm `feed()`/`clearScrollback` calls, and the resync wiring are App-tier
(macOS-CI + device).

## Data flow & ordering (correctness core)

Per pane:

```
pane first renders (lazy, in TmuxPaneContainer)
  → PaneSeedState: .unseeded → .seeding
  → send: capture-pane -p -e -S -<N> -t %<paneID>   (TmuxRuntime control channel)
  → (meanwhile) any %output for THIS pane is buffered in PaneSeedState.pendingOutput
  → tmux replies: %begin <id> … <history bytes> … %end <id>   (or %error)
  → CapturePaneCommand.parse → historyBytes
  → clear pane scrollback (idempotent), feed(historyBytes), feed(pendingOutput in order)
  → .seeded → subsequent %output feeds straight through
```

**The race** — live `%output` can arrive while the capture response is in flight. Feeding
it before the seed would interleave history and live output wrong. So `%output` for a
`.seeding` pane is **queued** and flushed, in order, immediately after the history is fed.
The queue is only active during the seed window.

**Resync** reuses the path: mark the pane `.unseeded`; the next `%output` (or an explicit
kick) re-issues `capture-pane`, buffers live output, reseeds. Because the pane already has
content, reseed does `clearScrollback` first (no duplication).

**N (history depth)** = the existing `TerminalSettings.scrollbackLines` (default 5000;
presets 1000/2000/5000/10000/∞). `∞` (`Int.max`) maps to tmux's whole-history shorthand
`-S -` (capture everything). tmux clamps `-S -<N>` to available history automatically, so
we send our N and take what tmux returns — no need to query `history-limit`. `N==0` (if
ever set) → skip seeding (pane starts with live output only).

## Error handling

- **capture-pane error / pane gone** (`%error` block, or pane closed before response):
  parse yields a typed error → mark `.seeded` (don't get stuck), flush pending output, pane
  starts with live output only. No crash. Logged via `DebugLog`.
- **Empty history**: capture returns ~0 lines → seed is a no-op, live output flows.
- **Malformed response block**: `CapturePaneCommand.parse` returns a typed error → same as
  the error case (fail toward "live works, history absent"), logged.
- **Reseed while seeded** (resync): `clearScrollback` first, then reseed — no duplicate
  history.
- **Large capture**: one command-response block streamed through the existing
  `ControlModeParser` (already handles large `%output` and block framing). Bounded by the
  `scrollbackLines` clamp.
- **Diagnostics**: every seed / reseed / parse-failure logs through `DebugLog` (the
  remote-diagnostics stream shipped in PR #79), so on-device behavior is observable — we can
  watch the capture go out, the seed return, and `contentSize` become non-zero in the trace.

## Testing

Per `docs/superpowers/specs/2026-06-18-testing-standards-design.md`:

- **`CapturePaneCommand` (Linux):** builder emits exactly
  `capture-pane -p -e -S -5000 -t %3` for (paneID 3, N 5000); `∞`/`Int.max` → `-S -`;
  `N==0` → no command (nil). Parser: a well-formed `%begin/%end` block → exact history
  payload bytes (including preserved escapes, since `-e`); `%error` block → typed error;
  malformed/truncated block → typed error; block split across two feeds → still parses once
  complete. Exact bytes asserted, a negative case per failure mode.
- **`PaneSeedState` (Linux):** EP+ordering — `.unseeded`→seed→`.seeded` passes output
  through; output arriving during `.seeding` is buffered and flushed **after** history, in
  arrival order (assert exact concatenation `history ++ o1 ++ o2`); `resync()` from
  `.seeded` returns to `.unseeded`; a second seed clears-then-seeds (assert no duplication
  marker). Negative: output before any seed on an `.unseeded` pane (define + assert the
  behavior — buffer until first seed, or pass through; pick buffer-until-seed and assert).
- **App-tier (macOS CI + device):** `PaneHistorySeeder` wiring; `capture-pane` issued on
  first render; SwiftTerm `feed()` seeds the buffer; **`contentSize` becomes non-zero** and a
  finger drag scrolls natively; resync on `%pause`/reconnect reseeds. Verified via the
  on-device diagnostics trace (watch capture→seed→contentSize→scroll).

## Risks & mitigations

- **Ordering race (seed vs live output)** — the central risk. Mitigated by `PaneSeedState`'s
  pure, tested pending-output queue; the App layer only wires it.
- **Attach latency** (capture-pane cost) — mitigated by **lazy per-pane seeding** (only
  panes you view are fetched, when first shown) + the `scrollbackLines` clamp.
- **`%pause` data loss** — the reason resync exists; wired to `%pause`/`%continue`/reconnect/
  resize. This is the correctness-critical behavior; do not skip it.
- **Reseed duplication** — `clearScrollback` before every (re)seed.
- **`-e` escape parsing** — history bytes carry real escape sequences; they flow through the
  same SwiftTerm `feed()` as live output, so fidelity matches the live path (no separate
  parser). `-J` deliberately omitted to keep tmux's real wrapping (avoids width reflow
  mismatch vs the live buffer).
- **Intermediate state** — mouse-mode panes still won't scroll until Spec B's mouse-gate.
  Documented; non-mouse is the common case.

## Open items (deferred to plan / implementation)

- Exact SwiftTerm API to clear scrollback before reseed (`getTerminal()` reset vs a
  scrollback-specific clear) — verify on macOS CI; must not clear the live screen, only
  history. Fallback: full `feed` of history into a fresh buffer at pane (re)creation.
- Whether resync needs an explicit "kick" when a paused pane produces no new `%output`
  after `%continue` (re-capture on `%continue` directly vs. on next output). Lean: capture
  on `%continue`.
- The precise control-mode framing of a `capture-pane` response on tmux 3.4 (`%begin/%end`
  with the payload as the block body) — confirm against a real capture in the plan's first
  task (the user can paste one from their host).
