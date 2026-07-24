<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# RESUME (2026-07-17): finger-drag window transition + open device items

Written before a `/clear`. Picks up after PR #102 (tap-yield + window-switch slide animation)
shipped to `main` and TF build 56 was device-tested.

## ▶▶ IMMEDIATE NEXT TASK: BRAINSTORM the finger-drag window transition

The user device-tested the shipped window-switch animation (build 56) and **rejected the
feel**: the current animation happens AFTER the switch is decided (slide-out on release,
slide-in on tmux delivery). **The user wants the window to DRAG WITH THE FINGER live during
the swipe, and commit the switch only once dragged past a threshold** (iOS-home-screen /
photos-app feel) - continuous finger-tracking, not a release-triggered animation.

### The `-CC` constraint + the BREAKTHROUGH (feasibility already proven in logs)
Under `tmux -CC` the next window's content does not exist locally mid-drag (panes are
destroyed/recreated on switch). So the revealed area needs *something*. The user asked "can we
pre-populate on connect? or on drag?" - and the **build-56 device log ANSWERS YES, it's already
partially built:**
- `tmux capture: pane=%N lines=5000` + `tmux capture REPLY: pane=%N lines=… bytes=…` fire
  ALREADY - `capture-pane` returns REAL pane content (the tmux-cc scrollback-seed path).
- We capture panes in **DIFFERENT / non-active windows** (`%10`, `%6` while `@0` is active) and
  get real bytes back (16421, 7085) - so **capturing a non-active window's content works today.**
- We even receive `%output` for some off-screen windows (`%6`,`%4`,`%12` stream while `@0`
  active) - content is not fully frozen.

**Conclusion: the "reveal shows the REAL next window via capture-pane snapshots, seeded on
connect + refreshed on drag-start" path is VIABLE and LOW-RISK** (the capture mechanism already
exists; we point it at the transition). This removed the main reason to hedge scope - lean
toward the FULL version (finger-drag + real snapshots), not a dimmed-placeholder phase.

### What the brainstorm must design
- **Gesture redesign:** the swipe becomes a CONTINUOUS drag (drive `paneContentView.transform`
  from the live drag translation), replacing the current dead-zone-then-classify one-shot in
  `GestureClassifier` -> `.switchWindow(delta)`. Threshold-to-commit on release; spring-back if
  short.
- **Snapshot lifecycle:** off-screen SwiftTerm view (or rendered snapshot) per ADJACENT window,
  fed by `capture-pane`, pre-seeded on connect, refreshed on drag-start. Which windows
  (prev+next only?), how stored, staleness handling.
- **Commit/cancel:** past threshold -> commit (real window slides into place as tmux delivers);
  short -> spring current window back. Reuse `WindowTransition`? Likely superseded by
  finger-driven transforms.
- The shipped `WindowTransition` (release-triggered slide) + `windowSlideDirection` are the
  CURRENT impl this redesign REPLACES/EVOLVES. `paneContentView` (the transform wrapper) STAYS
  and is the foundation the finger-drag rides on.

Invoke `superpowers:brainstorming`. This is a full feature (gesture + snapshot + commit), not a tweak.

## STATE OF SHIPPED WORK (all on main, all device-tested unless noted)

### Wheel alt-screen scroll [SHIPPED main, DEVICE-CONFIRMED build 55]
The big win: `tmux -CC` synthetic SGR mouse-wheel events (`ESC[<64/65;col;rowM`, 1 per
line-height) DO reach Claude and scroll it LINE-BY-LINE. Trace: `alt-scroll pane=%0 mode=wheel
app=claude -> keys=wheel`, `drag-move keys=wheel runs=1 sent=1 coord=(c,r)`. Replaced the
PgUp/arrows fork; `AltScrollMode`={wheel default, pageKeysArrows fallback}. Spec
`2026-07-17-wheel-altscreen-scroll-design.md`, PR #101. Claude PgUp=half-screen is NON-changeable
(Ink has no scroll primitive; Anthropic docs; fullscreen line-scroll is `-CC`-incompatible) - so
wheel was the only lever and it works.

### Double/triple-tap yield [SHIPPED main, DEVICE-CONFIRMED build 56]
Double/triple-tap now YIELD on `.appOwnsInput`/`.mouseReporting` (no garbage selection on
Claude's alt-screen). Trace confirms `tripleTap yield mode=appOwnsInput`. Local word/line select
still works in `.localScroll` (normal shell) - UNTESTED on device yet (user only tapped Claude),
but code-unchanged for that path. PR #102.

### Window-switch slide animation [SHIPPED main, build 56 - USER REJECTED THE FEEL]
Release-triggered slide (out on release, in on delivery, 1.5s timeout). WORKS but is the
wrong model - user wants finger-drag (see IMMEDIATE NEXT TASK). `paneContentView` wrapper +
`WindowTransition` + `windowSlideDirection`. PR #102. The paneContentView foundation STAYS.

### Decision-point logging [SHIPPED main, earlier] - the self-narrating `drag-*`/`alt-scroll`/
`user-action:` trace lines that made all the above device-debugging possible. `gesture` category
default-OFF (enable in Settings>Diagnostics>Gesture before a scripted test).

## GIT / BUILD STATE
- **github `main`** = `b83e404` (PR #102 merge) - has wheel + tap-yield + slide-anim. CI green.
- **TF build** = run 29618571285, uploaded OK (Delivery UUID 0cc6ff17), = build 56, device-tested.
- **ROLLBACK ANCHOR:** git tag `tf54-known-good` = `99e90ff` (last pre-wheel, live TF build 54).
- **LOCAL main IS STALE** (`1aa2f22`, pre-wheel) - the squash-merges diverged it; `git reset
  --hard github/main` is PERMISSION-GATED (user chose skip-sync each time). TF/CI build off
  github so it doesn't matter, but **sync local main before more code work**:
  `! git reset --hard github/main` (working tree clean apart from untracked extern/*).
- Untracked (ignore, not this work): `extern/eternaltermlib/`, `extern/swift-sodium/`,
  `docs/superpowers/topics/2026-07-15-build47-five-issues.md`.

## OTHER OPEN / DEFERRED (not lost)
- **D-width** (terminal redraw width off / continuous-zoom fractional cols) - ROOT-CAUSED
  earlier (early layout pass measures cell before metrics settle, `kbH<0` transient), NOT fixed.
- **decisionLine sweep** (spec 4c of decision-point-logging): adopt `decisionLine(...)` at
  tmux-grid / context-poll / transport boundaries. Built + tested, not yet consumed.
- **Normal-shell double/triple-tap select** - verify still works on device (untested build 56).
- **Local-scrollback-buffer** (iTerm2 %output-ring model, memory `tmux-cc-scrollback-architecture`)
  - was plan B if wheel failed; wheel WORKED so it's deferred, but it's the same capture-pane
  machinery the finger-drag snapshots will use - may converge.

## SDD LEDGER: `.superpowers/sdd/progress.md` has the full task-by-task history of all the above.
