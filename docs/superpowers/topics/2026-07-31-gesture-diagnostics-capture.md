<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Gesture diagnostics device-capture runbook (2026-07-31)

This runbook drives the device capture for the `feat/gesture-diagnostics` slice. It
targets two open questions, not fixes: (1) why the alt-screen selection highlight is
invisible, and (2) whether the keybar's `playInputClick()` actually reaches an
in-chain audio-feedback host. Diagnose, do not guess: read the log lines below rather
than assuming a root cause.

## Pre-reqs

1. Start the syslog sink so device logs land somewhere readable:
   ```bash
   docker compose -f tools/syslog-sink/docker-compose.yml up -d
   ```
   It must be UP before the capture starts, or nothing lands. Output goes to
   `tools/syslog-sink/logs/semicolyn.log` (root-owned, `sudo cat` to read).
2. On the device: Settings -> Diagnostics -> Stream logs to a server, using
   **TLS 6514 / TCP**, not UDP. UDP re-parses and concatenates the long lines this
   capture depends on (syslog-ng `flags(no-parse)` is only wired for tcp/tls).
3. On the device: Settings -> Diagnostics -> enable log categories `.selection`,
   `.gesture`, and `.keybar`.

## Highlight capture procedure

Do each of the four gestures below and let the app settle (repaint finished) before
moving to the next one, so the three-line sets do not interleave in the log.

1. **Normal shell pane, double-tap a word.** Open a plain (non-alt-screen) shell
   pane, double-tap a word to select it.
2. **Normal shell pane, triple-tap a line.** In the same pane, triple-tap a line to
   select it.
3. **Alt-screen pane, double-tap a word.** Open an alt-screen program (Claude or
   vim), double-tap a word.
4. **Alt-screen pane, triple-tap a line.** In the same alt-screen program,
   triple-tap a line.

Each gesture should produce a triple of `sel:diag` lines, one per phase
(`set`, `redraw`, `repaint`). Collect all four triples (12 lines total) before
moving to the read table.

## Log line format (as emitted, not the brief's placeholder)

```
sel:diag phase=<set|redraw|repaint> mode=<localScroll|appOwnsInput|...> active=<bool> selLen=<int> color=rgba(r,g,b,a)
```

- `phase`: which point in the pipeline this snapshot was taken. `set` = right after
  `setSelectionRange`; `redraw` = right after the forced `setNeedsDisplay`; `repaint`
  = taken from a `Task { @MainActor [weak view] in ... }` scheduled immediately after
  the forced `setNeedsDisplay` (`App/TerminalGestureController.swift` lines 677 and
  711). It runs on the NEXT main-runloop turn, after the current turn's layout/draw
  pass has had a chance to run, so it captures the selection state one runloop-turn
  later. The `[weak view]` guard only drops the line if the terminal view was
  deallocated in the meantime (essentially never during a live capture). (Note:
  `repaint` is NOT a per-pixel draw callback and it does NOT fire on a real
  selection-state-change hook. SwiftTerm's `draw(_:)` and `selectionChanged(source:)`
  are non-open in the CI-resolved v1.15.0, so they cannot be overridden cross-module;
  the runloop-hop `Task` is the workaround. It is still a useful candidate-#1 signal:
  if a repaint cleared the selection within that turn, `active` will read false at
  `phase=repaint`. But because it fires unconditionally every time (not gated on
  anything changing), it is not a guaranteed draw-time reading, see the read table
  note.)
- `mode`: the caller's current interaction mode string.
- `active`: whether the terminal view reports a selection is active
  (`view.selectionActive`).
- `selLen`: a content-free length proxy (`view.getSelection()?.count ?? 0`), never
  the selected text itself (privacy). Not literally SwiftTerm's internal selection
  range, this is a substitute the implementation could actually read.
- `color`: the configured highlight color as `rgba(r,g,b,a)`, each component
  formatted to two decimal places.

## Read table (root-cause candidates)

Compare the normal-pane triples against the alt-screen triples; the candidate is
whichever pattern actually appears in the alt-screen capture.

| Observed pattern in the `sel:diag` triple | Candidate | Rank |
| --- | --- | --- |
| `active=true` at `phase=set` and `phase=redraw`, but `active=false` at `phase=repaint` | #1: selection cleared by a mode-transition / tmux -CC repaint between set and draw | Top-ranked |
| `active=true` at all three phases, but `color=rgba(...)` has an alpha (last component) of `0.00` | #2: highlight color is transparent or unset at draw time | |
| `active=true` at all three phases, non-transparent color, but `selLen=0` (especially only on the alt-screen captures, not the normal-pane ones) | #3: degenerate / zero-length selection | |
| `active=true` at `phase=repaint`, non-transparent color, `selLen>0`, yet no highlight is visible on screen | #4 / #5: something else is drawing over the highlight (overlay), or the dirty-rect for the highlight is missed on repaint | |
| Caveat: `phase=repaint` is a runloop-hop snapshot (one main-runloop turn after the forced `setNeedsDisplay`), not a real draw-time reading, and it fires on every gesture (the `[weak view]` guard essentially never drops it). A selection cleared by a LATER tmux -CC frame, after that `Task` turn has already run, can still read `active=true` at `phase=repaint` and falsely point at #4/#5. Always cross-check the `phase=repaint` line against the actual on-screen highlight, not just the logged `active` value. | n/a (methodology caveat, not a distinct candidate) | |

Record which row matched for each of the four captured gestures (normal word,
normal line, alt-screen word, alt-screen line). The Selection-UI slice's fix task is
chosen by whichever candidate the alt-screen data actually implicates, not by
assumption.

## playInputClick capture

1. Tap several different keybar keys (a mix of letters, modifiers, arrows) so
   multiple `keybar:clickprobe` lines are collected.
2. Each tap should log a line of the form:
   ```
   keybar:clickprobe called=playInputClick host=<audioFeedbackHost@window|detached>
   ```
   (a companion `keybar:clickprobe host=... conformsAudioFeedback=true` line is
   logged once from `KeybarInputAccessory` when the accessory mounts.)
3. Interpretation:
   - `host=audioFeedbackHost@window`: the audio-feedback host IS in the responder
     chain, `playInputClick()` should fire. If the device is still silent, the
     mount is fine and the cause is the user's system keyboard-feedback setting
     (Settings -> Sounds & Haptics / Sound Effects and Haptic Feedback), which is
     expected behavior, no pivot needed.
   - `host=detached` (or the pre-probe default `unknown`, if that value is ever
     observed in the log): the host is NOT in the responder chain, so
     `playInputClick()` is a silent no-op regardless of the user's settings. The
     next slice pivots to hosting the keybar in a real `UIInputView` or falling
     back to `UISelectionFeedbackGenerator`.

## After the capture

Record, in project memory and in the follow-up slice's brief:
1. Which highlight candidate row (#1 through #5) the alt-screen data implicates.
2. Whether the keybar's `host=` value was `audioFeedbackHost@window` or `detached`,
   and if `audioFeedbackHost@window` with still-silent device audio, note that as
   "expected, no pivot" rather than as an open bug.

## RESULT (captured 2026-08-01, TestFlight build 102 = run 30669541913)

**Highlight root cause: DIAGNOSED. Not candidates #1/#2/#3.** All captured
`sel:diag` triples were `mode=appOwnsInput` (alt-screen) and every phase read
identically: `active=true selLen=8|55 color=rgba(1.00,0.44,0.37,0.30)`.
- `active=true` at set + redraw + repaint -> selection NOT cleared (rules out #1).
- `selLen` non-zero -> real selection (rules out #3; consistent with copy menu).
- color alpha `0.30`, non-transparent -> highlight color is set (rules out #2).

So the selection state is fully healthy yet no highlight draws -> candidate #4/#5,
and cross-referencing SwiftTerm v1.15.0 source pins it to a **yDisp
coordinate-space mismatch**: our `setSelectionRange` stores a VIEWPORT-relative row
(`TapRowMapping` strips `yDisp`), but SwiftTerm's draw loop
(`AppleTerminalView.selectedColumnsRange`) matches the selection against ABSOLUTE
buffer rows (`displayBuffer.yDisp` + offset) by exact `==`. When `yDisp > 0`
(always on the alt-screen), no visible row matches -> no cell gets the highlight
background -> invisible highlight. `getSelection()` reads the stored coords (and
adds `yDisp` itself), so copy still returns the correct text, which is exactly the
observed "selects + copy works, no highlight" symptom.

The guessed `setNeedsDisplay` (64dc281) was irrelevant: the highlight was never
going to draw regardless of repaint, because the row match fails.

**Trap for the fix (slice 2):** the same `Position.row` feeds two SwiftTerm paths
that want OPPOSITE spaces, `getSelection`/text wants viewport-relative (adds yDisp
itself), the draw loop wants absolute. A naive flip to absolute rows may fix the
highlight but double-count in `getSelection` and break copied text. Fix is designed
in slice 2 (Selection UI): either reconcile the row space for both, or (aligned
with the locked CUSTOM selection UI) draw a custom highlight fill keyed on our own
stored coords, bypassing SwiftTerm's row-equality entirely. Add a Kit test with a
`yDisp > 0` boundary case.

**playInputClick / haptic:** `keybar:clickprobe` lines were captured (10x). [Read
the `host=` value from the sink before the next slice: `audioFeedbackHost@window`
means the mount is fine and any silence is the user's system keyboard-feedback
setting; `detached`/`unknown` means pivot to a real UIInputView host or
`UISelectionFeedbackGenerator`.]
