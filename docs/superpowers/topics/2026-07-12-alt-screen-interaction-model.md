<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# TOPIC (for a fresh-context brainstorm): Alt-screen vs normal-screen interaction model

**Status:** topic captured 2026-07-12, NOT yet brainstormed. Two quick fixes shipped
separately (swipe-threshold + tap-offset, branch `fix/gesture-swipe-and-tap`); this doc is
the deferred, larger design. Brainstorm it in a FRESH context.

## The problem (from device testing, build 38)

Most of the user's tmux panes run **Claude Code** — a full-screen TUI on the terminal's
**alternate screen** (like vim/htop/less). The user's findings:

1. **Local scrollback barely helps in practice.** Spec A (PR #81) seeds each pane's history
   and lets SwiftTerm scroll it locally. But that only works on **normal-screen** panes. On
   an **alt-screen** pane (Claude/vim), the mouse-gate (PR #83) correctly forwards touch to
   the app, so the drag scrolls the APP's history (Claude's prompt history), not our local
   scrollback. The user verified: scroll works in a plain shell pane, does nothing useful in
   a Claude pane. **This is the mouse-gate working as designed — but the overall UX is
   incoherent: the feature we built (local scroll) is invisible in the panes they use most.**

2. **Tap-offset desync (user's own root-cause).** On an alt-screen pane, a drag was captured
   by Claude's history scroll, BUT semicolyn's `contentOffset` advanced anyway (it thought it
   scrolled locally). A subsequent double/triple-tap then selected "where the content WOULD be
   if local scroll had worked" — i.e. our belief about scroll position desynced from reality.
   (The immediate `cell(at:)` double-count-offset bug is fixed separately; the ALT-SCREEN
   desync — our offset advancing while the app owns the screen — is this topic's concern.)

3. **User mandate:** *"we DEFINITELY need to address this. blink handles it fine. we also need
   to systematically handle this generically."*

## The core insight — the fix is a MODE, gated on alt-screen

Everything above stems from one thing: **semicolyn runs its local-interaction machinery
(scroll, `contentOffset`, tap-to-cell, selection) even on alt-screen panes where it makes no
sense.** On the alternate screen the app owns the entire display; there is no local scrollback
to scroll, `contentOffset` should be pinned, and tap-to-cell/selection is against a buffer
that isn't ours to scroll. The generic fix is a clean **two-mode interaction model** switched
on `isCurrentBufferAlternate` (the SAME signal the mouse-gate already uses):

- **Normal screen:** run the Spec A local machinery — native scroll of the seeded buffer,
  tap-to-place-cursor, double/triple-tap selection, single-tap-clears-selection.
- **Alternate screen:** DON'T run local scroll/selection. Pin `contentOffset`. Translate a
  vertical drag into something the APP understands (see the reference model below), and leave
  taps/mouse to the app.

## Reference model (grounded — this is how it's "supposed" to work)

**xterm's "Alternate Scroll" mode (`DECSET ?1007`)** is the industry-standard mechanism, and
it answers this exactly:
- Default (normal screen): wheel/scroll → scroll the local scrollback.
- **Alternate Scroll mode ON + alt-screen active → scroll is translated to CURSOR UP/DOWN
  arrow keys sent to the app.** So in `less`/`man`/a pager, a scroll gesture moves the app's
  own view; no local scrollback involved. (Sources: xfree86 ctlseqs "Alternate Scroll mode";
  iTerm2/xterm docs.)

**The touch analog (xterm.js issue #1007, "Touch scrolling should send arrow keys like wheel
events"):** on mobile, a **touch-drag on the alternate screen should be translated into
arrow-key presses** (`ESC O A` = up, `ESC O B` = down — SS3 cursor keys, or `ESC [ A/B` in
normal cursor-key mode) sent to the app, instead of native scroll. This is the mobile answer:
the user drags, and vim/less/Claude scroll THEIR content via synthesized arrow keys, smoothly,
with no jitter and no desync. (Issue closed-but-unresolved in xterm.js; it's the right model
to implement here.)

**So the alt-screen scroll behavior we want:** vertical drag on an alt-screen pane →
synthesize N arrow-key presses proportional to the drag distance (÷ cell height), respecting
the app's cursor-key mode (SS3 `ESC O A/B` vs CSI `ESC [ A/B` — check DECCKM). Do NOT forward
raw mouse for the DRAG (that's the current jittery behavior); DO keep forwarding taps/clicks
as mouse if the app requested mouse reporting (vim menus, etc.). This is subtler than the
current binary mouse-gate — it splits "drag" (→ arrows) from "tap/click" (→ mouse).

## Design questions for the brainstorm

1. **Scroll translation:** vertical drag on alt-screen → how many arrow keys? (drag Δy ÷
   cellHeight, clamped? momentum?) Which arrow encoding — honor DECCKM (`ESC O A` vs `ESC [ A`)?
   Does SwiftTerm expose the app's cursor-key mode? (grep `applicationCursor`/`DECCKM`.)
2. **Drag vs tap split on alt-screen:** drag → arrow keys; tap/long-press → still forward as
   mouse if the app requested it? Or gate each gesture independently?
3. **`contentOffset` pinning:** on alt-screen, pin the scroll view (isScrollEnabled=false or
   force offset=0) so our belief can't desync. Confirm this doesn't fight SwiftTerm's own
   rendering of the alt-screen (which is a live full-screen redraw, not a scrollback).
4. **Mode transitions:** when an app enters/exits the alt-screen (`?1049h`/`?1049l`), switch
   modes cleanly — re-enable native scroll on exit, pin on enter. Where does semicolyn observe
   this? (`isCurrentBufferAlternate` is polled in `updateMouseDots`/`updateMouseDot` already.)
5. **Selection on alt-screen:** does double/triple-tap-to-select even make sense there? (Blink/
   iTerm2 still allow selecting visible text.) Or disable and rely on the app?
6. **Window-switch gesture on alt-screen:** the horizontal-swipe window-switch (now bias-tuned)
   — keep it on alt-screen panes, or does the drag→arrow translation conflict? (Probably keep:
   horizontal = switch, vertical = arrows-to-app.)
7. **The bigger UX question the user raised:** given alt-screen-heavy usage, is per-pane local
   scrollback even the right primary feature, or is "smooth drag→arrows into the app" the thing
   that actually matters day-to-day? Weight the design accordingly.

## What's already in place to build on

- `isCurrentBufferAlternate` (SwiftTerm public API) — already used by the mouse-gate
  (`TmuxPaneContainer.updateMouseDots` / `TerminalScreen.updateMouseDot`) and `SwiftTermEchoOracle`.
- `TerminalGestureController` (App) — our gesture layer; `handleScrollViewPan` (drag),
  `handleSingleTap`, double/triple tap, long-press. This is where mode-gating goes.
- `GestureClassifier` (Kit, Linux-tested) — pan axis classifier; a drag→arrow-count decider
  would be a natural pure Kit companion (testable).
- `CursorArrowStream`/`cursorTapArrows` (Kit) — ALREADY synthesize arrow-key byte sequences
  for cursor placement. The drag→arrows translation can reuse this arrow-encoding.
- The categorized diagnostics (Spec B, PR #84) — `.gesture` logs will show the mode + the
  translated arrows in the device trace.

## Quick fixes already shipped (context, NOT this topic)

Branch `fix/gesture-swipe-and-tap` (off main `92db11c` post-Spec-B):
- **Swipe threshold:** `GestureClassifier.switchDominanceRatio = 1.7` — a drag switches windows
  only when `|dx| >= 1.7·|dy|` (clear horizontal); vertical/diagonal/gently-horizontal scroll.
  Fixes the accidental-swipe-into-wrong-window. 14 Kit tests.
- **Tap-offset:** `cell(at:)` now maps `row = Int(point.y / cellH)` (matches SwiftTerm's own
  `calculateTapHit`), removing the double-counted `contentOffset` math that grew the error with
  scroll distance. App-tier.

These are palliative — they stop the bleeding in the NORMAL-screen case. The ALT-SCREEN model
above is the real, generic fix.

## Sources
- xfree86 Control Sequences — "Alternate Scroll mode" (`DECSET 1007`): scroll → cursor up/down
  on the alternate screen. https://www.xfree86.org/current/ctlseqs.html
- xterm.js #1007 — "Touch scrolling should send arrow keys like how wheel events are translated"
  (the mobile drag→arrows model). https://github.com/xtermjs/xterm.js/issues/1007
- xterm.js #3607 — "Scrollback emulation in alternative buffer" (the alt-screen scrollback UX
  problem). https://github.com/xtermjs/xterm.js/issues/3607
- Blink Shell — touch/mouse support (docs.blink.sh); open-source `blinksh/blink` for a source
  dive if the brainstorm wants Blink's exact alt-screen handling (the discussion threads don't
  cover the implementation; read the terminal-view source).
