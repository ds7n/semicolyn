<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# RESUME (2026-07-19): three device findings on the timing-fix TF build

Written before a `/clear` (context full). The window-switch animation TIMING FIX
(both-ready gate + page-turn + generation guard) shipped to TestFlight (run 29668399422,
macOS CI green run 29667551491) on branch `feat/finger-drag-window-transition` (HEAD
`2163a0a`, PR #103, on main `b83e404`). Device-tested -> THREE findings. Evidence pulled
from `data/syslog/semicolyn-bunknown-2026-07-19.log`.

## Finding #3 (HIGHEST-VALUE, ROOT-CAUSED): bottom line(s) hidden behind the keybar

This is the **build-47 #4 keybar-height bug, still unfixed** (`docs/superpowers/topics/
2026-07-15-build47-five-issues.md`). Syslog proof:

```
sizing:tmux bounds=402x403 si=(t0,b0) cell=5.0x10.0 kbH=78.0 grid=80x40
```

- Container height = 403pt, cell height = 10pt -> grid computed as **40 rows**.
- BUT the keybar (`inputAccessoryView`) is **78pt tall** (`kbH=78.0`) and is NOT subtracted.
- Usable height above the keybar = (403 - 78) = 325pt -> only ~**32 rows** actually fit.
- So tmux is told 40 rows; the bottom ~8 rows render BEHIND the keybar.

**Fix direction:** the grid computation in `ContainerView.layoutSubviews` (the `sizing:tmux`
log site in `App/TmuxPaneContainer.swift`, `terminalGrid(...)` / `resolvedCell` path) must
subtract the first-responder keybar height (`firstResponderKeybarHeight()`, already exists
and returns 78 here) from `bounds.height` before dividing by cell height. NOTE the earlier
root-cause caveat (memory/build-47 doc): kbH can be -1 (no first responder) or a transient
negative during keyboard avoidance - guard for that. This is a real, isolated, testable fix
(pure grid math -> could even extract a Kit helper `usableGridRows(height, kbH, cellH)`).

## Finding #1 (animation still not visible - the gate WORKS, perceptibility doesn't)

**Surprising:** the both-ready gate is functioning PERFECTLY. Syslog ordering is exactly as
designed, every switch:
```
anim-start gen=3 delta=1 ... out=left in=right
switch delivered active=@3 animDone=false
switch finish WAIT anim=false delivered=true      <- gate correctly WAITS
anim-done gen=3
switch finish (both-ready) -> live shown           <- fires only after both
```
No premature finish, generations clean (gen increments per switch), no STALE bugs. **The
fix did what it was designed to do.**

BUT: `anim-start -> anim-done` is **~110-140ms**, not the 180ms `withDuration: 0.18`. And
every commit is a hard flick: `drag-switch commit dx=-126 vx=-1552` (vx ~1500-1900 every
time). So the animation is running but is imperceptible at flick speed.

**Hypotheses for a FRESH systematic-debugging session (do NOT guess - verify):**
1. The `content.transform` slide + `host` slide-in ARE animating, but at ~110ms nobody sees
   a full-width slide. (Why 110 not 180? UIView may be coalescing/short-circuiting - or the
   completion fires early. Measure with a longer duration to test.)
2. POSSIBLE the animation never visibly moves because `paneContentView.transform` slide is
   masked - the earlier TF59 investigation NEVER confirmed the `content` transform is
   visibly applied (the pre-pivot motion came from the neighbor host, now removed). The gate
   fix assumed the slide plays; verify the slide is actually VISIBLE by itself (e.g.
   temporarily bump duration to 1.0s and slow-drag). If even a 1s slide shows nothing, the
   transform isn't the visible mover and the whole animation approach needs rethinking (this
   was flagged as an open question in the TF59 root-cause but deferred).
3. The snapshot (`snapshot=true`, added on top at commit) may be covering the slide the whole
   time regardless of the gate. Re-examine z-order + when the snapshot becomes visible.

Bottom line: the RACE is fixed but the animation may have a SEPARATE visibility problem that
the timing fix didn't address. Needs a fresh debug pass with a temporarily-lengthened
duration to isolate "is the slide visible at all".

## Finding #2 (no prediction) - UNDIAGNOSED

Only "predict" hits in the syslog are terminal CONTENT (skkserv / satellite-tracking text),
NOT predictor-engine activity. So either: (a) the `.predictor` log category is OFF (likely -
it's default-off), so we can't SEE it, or (b) the predictor genuinely isn't firing. The
predictor is a large shipped subsystem ([[predictor-secret-exclusion-design]], keybar
predictor). Next step: enable Settings>Diagnostics>Predictor logging on device, reproduce,
pull syslog; OR check whether the predictor is even wired for tmux panes (it may only run on
raw-SSH / the keybar path). Do NOT assume it's broken - first confirm it's supposed to be
active in this context.

## GIT / STATE
- Branch `feat/finger-drag-window-transition` HEAD `2163a0a`, PR #103 open, macOS CI GREEN.
- The whole finger-drag -> pivot -> timing-fix stack is on this branch; squash-merging #103
  ships all of it. DO NOT merge until the animation (#1) is resolved or explicitly deferred.
- SDD ledger `.superpowers/sdd/progress.md` has the full task history of all three feature
  rounds (finger-drag, pivot, timing-fix).

## RECOMMENDED NEXT-SESSION ORDER
1. **#3 keybar-height** first - clear root cause, isolated, high user value, testable. Small fix.
2. **#1 animation** - fresh systematic-debugging: lengthen duration to 1s, confirm whether
   the `content` slide is visible AT ALL. If not, rethink; if yes, it's a flick-speed
   perceptibility issue (maybe fine, or make the min duration floor higher).
3. **#2 prediction** - enable predictor diagnostics, confirm it's meant to be active here.
