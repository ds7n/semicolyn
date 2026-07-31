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

- `phase`: which point in the pipeline this snapshot was taken (after set, after
  redraw, at repaint time).
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
