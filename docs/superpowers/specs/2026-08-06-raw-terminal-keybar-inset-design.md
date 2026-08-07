<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Raw terminal keybar-inset + exit-flash + scroll, design (next build)

**Status:** approved (2026-08-06). Batches three device-found issues from the ET
retest of PR #121 into one next-build change. All three are rooted in the raw
single-terminal path (`TerminalScreen` / `PaneTerminalView`), which ET, Mosh, and
opted-out (raw) SSH all use, not in the ET transport itself.

## Why these are one batch (the key finding)

After connection the terminal is transport-independent: the same SwiftTerm
`PaneTerminalView`, the same 70-column grid on every transport (device logs: every
`sizing:raw` line is 70 cols regardless of transport). The visible differences the
user hit on ET are NOT ET-vs-SSH; they are **render-path differences**:

- **SSH** by default probes and auto-attaches `tmux -CC` (`attachSSHShell` ->
  `tmuxLaunchDecision` -> `attachTmux`), landing in the **`TmuxPaneContainer`** path.
  That path received the keybar-height inset fix (PR #110/#111 + the 2026-08-02
  keybar-inset work) and has had its scroll/gesture wiring device-tuned.
- **ET** (and Mosh, and raw/opted-out SSH) uses the **`TerminalScreen`** single-terminal
  path. It never got the keybar inset, and its native-scroll path is under-exercised
  because almost every real SSH session is promoted to -CC.

So fixing the raw path fixes ET + Mosh + raw SSH together.

## Issue 1: exit shows a transient "Connecting…" screen (from PR #121)

**Symptom (device):** after a clean ET `exit`, a transient screen flashes before the
connection list appears.

**Root cause (code-confirmed):** PR #121's `.dismiss` path sets `state = .idle`, then
`SessionView`'s `.onChange(of: vm.state)` fires `dismiss()`. But between the state flip
and the dismissal, `SessionView`'s `Group` re-renders by state: `.shell` is now false,
`resolving`/`needsPasswordEntry` are false, so it falls to `else { statusView }`. The
`statusView` `.idle`/`.connecting` case draws a `ProgressView` spinner + "Connecting to
<host>…". That connecting spinner IS the transient screen, shown for the frame(s) until
`dismiss()` completes.

**Fix:** the transient `.idle` window must render nothing, not the connecting spinner.
In `SessionView.statusView`, split `.idle` out of the `.idle, .connecting` case so
`.idle` renders `Color.clear` (or `EmptyView` inside the same frame) while `.connecting`
keeps the spinner. `.idle` only ever occurs transiently on the way out (a fresh
pre-connect session is `resolving` or `.connecting`, never `.idle` in `statusView`), so
`.idle` -> blank is correct and safe. Result: exit is a clean cut to the connection list.

This is ET-exit-specific and stays in the PR #121 line (or this batch, either is fine).

## Issue 2: terminal rendered behind the keybar (the row/height bug)

**Symptom (device):** the bottom several ROWS of the terminal, including the shell
prompt, are drawn behind the floating keybar + keyboard. Not columns, not font.

**Root cause (device numbers):** keyboard-up state `bounds=402x499`, keybar
(`inputAccessoryView`) height `56`, SwiftTerm grid `70x45` -> ~11px/row. The
`TerminalScreen` path lets SwiftUI size the `PaneTerminalView` to the full slot (frame ==
499), and SwiftTerm pins its row count to `frame.height / cellHeight` = 45 rows with no
inset input. The keybar floats over the bottom `56px` ~= **5 rows**, so the PTY is sized
to 45 rows but only ~40 are visible; the prompt on row 45 renders behind the keybar.

This is exactly the `TmuxPaneContainer` bug that the keybar-inset saga fixed there, never
ported to the raw path. The -CC fix (see `TmuxPaneContainer.layoutSubviews`, the long
comment at ~lines 710-730) established the correct model: **a single consistent inset,
both the reported grid AND the terminal frame come from the same `usableH`**, because
SwiftTerm's row count follows the frame. The proven `usableH` source is the real keybar
top from `keyboardLayoutGuide` (it re-lays-out correctly post-app-switch), with the
measured-height reduction as fallback.

The Kit helpers already exist and are tested (`Sources/SemicolynKit/Terminal/TerminalGrid.swift`):
- `usableHeightFromKeyboardTop(rawHeight:keyboardTopY:)` (preferred, from the guide),
- `visibleTerminalHeight(rawHeight:keybarHeight:)` (fallback).

**Fix:** inset the RAW terminal's usable height to `usableH` so `rows == visible rows`
and the prompt sits on the last visible line. Because SwiftTerm follows `frame.height`,
the inset must reduce what SwiftTerm measures, not merely relabel the grid.

**Mechanism.** `PaneTerminalView` (the `TerminalView` subclass) is SHARED by both paths
and already overrides `layoutSubviews`. Add the inset there, gated to the raw path only
(the -CC path already sets each pane's frame to `usableH` externally in
`TmuxPaneContainer.layoutSubviews`, so it must NOT be double-inset):

1. Add a mount-set flag `var appliesOwnKeybarInset = false` on `PaneTerminalView`.
   `TerminalScreen.makeUIView` sets it `true` (raw path owns its inset);
   `TmuxPaneContainer` leaves it `false` (container owns the inset).
2. In `PaneTerminalView.layoutSubviews`, when `appliesOwnKeybarInset` is true, compute
   `usableH` from `self.keyboardLayoutGuide.layoutFrame.minY` (in this view's own
   coordinate space) via the same guard as `keyboardTopInContainer()`
   (`height>0 && width>0 && minY.isFinite && minY>0`), falling back to
   `visibleTerminalHeight(rawHeight:keybarHeight:)` using the keybar's
   `intrinsicContentSize.height` when the view is first responder (else `-1`).
3. Apply `usableH` via a **frame/size inset** (approach (a); (b) contentInset is a
   CONFIRMED dead end). Verified against vendored SwiftTerm v1.15.0
   `AppleTerminalView.swift`: `newRows = Int(frame.height / cellDimension.height)`
   (line 56) and `processSizeChange` `newRows = Int(newSize.height / cellDimension.height)`
   (line 122). Row count follows `frame.height` with NO `contentInset` term anywhere in the
   row math. So the inset MUST reduce the height SwiftTerm sees for its grid. In
   `PaneTerminalView.layoutSubviews`, after `super.layoutSubviews()`, when
   `appliesOwnKeybarInset` and `usableH < bounds.height`, set the view's frame/bounds
   height to `usableH` (mirrors how `TmuxPaneContainer` sets each pane frame to `usableH`).
   Guard against a layout loop: only mutate when the height actually differs from `usableH`
   (a re-entrant `layoutSubviews` with height already `usableH` must be a no-op), and let
   the SwiftUI slot keep providing the full-bounds origin so the keybar still floats over
   the freed bottom region.
4. Trigger a `keyboardLayoutGuide`-change relayout: observe keyboard frame changes (or
   rely on the system calling `layoutSubviews` when the guide updates, which it does on
   show/hide/app-switch) so the inset re-applies when the keyboard/keybar appears,
   disappears, or re-lays-out after an app-switch. If `layoutSubviews` is not called on
   a guide-only change, add a `keyboardLayoutGuide.topAnchor`-driven constraint or a
   keyboard-frame `NotificationCenter` observer to `setNeedsLayout`.

**Reference caution from the -CC saga (do not re-introduce):** setting the grid smaller
WITHOUT shrinking the frame does nothing (SwiftTerm re-measures rows from the full
frame). The inset MUST reduce the height SwiftTerm measures.

## Issue 3: scrolling does not work on the raw path

**Symptom (device):** a finger swipe on the ET (raw) shell produces no scroll movement.

**Evidence (device logs, all categories on):** `scroll:init isScrollEnabled=true
nativePan=true`; content `396x770` inside a `499` frame (content taller than frame, so
there is scrollback to show); pan recognizers installed (`addGR: UIPanGestureRecognizer
delegate=TerminalGestureController` x3, `altPan enabled`, `switchPan enabled`); yet
during the swipe there were **zero** `gesture:handlePan` / `drag-*` / `fling` / `sweep2:`
events and no scroll movement. In `.localScroll` (normal shell), vertical scroll is owned
by SwiftTerm's NATIVE scroll pan (not our `handlePan`), so the drag should ride the native
pan, and it did not move.

**Root-cause status (comparative log analysis done, cause NOT yet pinpointed).** Applying
the same "same terminal, what differs in ET" logic to the actual logs: the one real
raw-SSH-via-`TerminalScreen` session in the log (a `DEGRADE(optedOut)` host) DID scroll,
`drag-begin`/`drag-move`/`fling` ×11/56/118, `mode -> appOwnsInput`, `selectionPan
subordinated`. The ET session had ZERO of those. So the same `TerminalScreen` scrolls
under raw SSH and produces no gesture activity under ET. Emulator state was NOT the
difference: the ET session stayed `.localScroll`, `isScrollEnabled=true`, with no
mouse-reporting or alt-screen (`?1049`) sequences, so the terminal was in the plain
scrollable state, exactly like a raw shell.

**Why the current logs cannot name the culprit.** The instrumentation that identifies which
recognizer wins a touch (`observeRecognizerState` -> `gr-observe <kind>`, and the native-pan
target) is attached **lazily, only from inside `beginDrag`** (`TerminalGestureController`
~line 435/441). `beginDrag` runs only when OUR pan or an alt-screen drag fires, never for a
plain `.localScroll` vertical scroll. On ET (pure `.localScroll`, only typed + swiped),
that path never ran, so we were never listening to the native scroll pan. Zero
`gr:scrollPan`/`gr-observe` logs therefore means "not observed," not "did not fire." This
is the exact failure class the code comments flag (`TerminalGestureController` 187-204,
469-471): SwiftTerm's LAZILY-created selection/mouse pan (or the system text-interaction
stack) can pre-empt the native scroll pan on a fresh pane whose FIRST gesture is a scroll,
before any selection/tap has run the subordination.

**Decision: ship an INSTRUMENTATION task (Task 3), not a speculative fix.** Attach
`observeRecognizerState` to the native scroll pan (and all non-ours recognizers) ONCE at
mount (in `installOurRecognizers`), so the very first ET swipe is observed. Then one device
swipe yields the decisive `gr-observe <kind>` line telling us exactly which recognizer eats
the touch. The Issue 3 code fix follows from that trace, in a later build, with certainty.
Issue 2's inset may ALSO change scroll behavior; the same retest captures both. Do NOT write
an Issue 3 code fix before that trace exists.

## Scope and ordering

1. **Issue 1** (exit flash) folded in, small and independent.
2. **Issue 2** (raw keybar inset), the highest-impact geometry fix.
3. **Issue 3 instrumentation** (attach the recognizer observer at mount), NOT a fix, so the
   next device swipe pinpoints which recognizer eats the touch. The Issue 3 code fix is a
   later build, gated on that trace.
4. The device retest captures all three; the trace from #3 decides the follow-up.

All three land in one next-build branch; PR #121's ET-exit fix remains its own commit
history but the exit-flash fix (Issue 1) can be committed on the same branch since it is a
follow-on to that path.

## Testing

- **Kit (Linux):** the `usableHeightFromKeyboardTop` / `visibleTerminalHeight` helpers
  already have tests. If the raw-path inset introduces any new pure decision (e.g. a
  "which usableH source" selector), extract it to `Sources/SemicolynKit/Terminal/` with EP
  + BVA tests. The `layoutSubviews` wiring itself is App-tier (macOS-CI-compiled only).
- **App (macOS CI):** compile-only for `TerminalScreen`/`PaneTerminalView`/`SessionView`.
- **Device retest (all diagnostic categories ON):**
  1. Issue 2: connect ET; the shell prompt sits on the last VISIBLE row, no rows behind
     the keybar; show/hide keyboard and app-switch keep `rows == visible rows` (verify via
     `geo:pane`/`sizing:raw`: `grid rows` should now match `usableH/cellH`, and the pane
     frame height should equal `usableH`, not full bounds).
  2. Issue 3: swipe to scroll; content scrolls one line per line-height. Capture
     `gesture:*` / native-scroll events.
  3. Issue 1: type `exit`; clean cut to the connection list, NO transient "Connecting…"
     spinner.
  4. A/B confirm path-not-transport: set the dev host `attemptControlMode = false`
     (`semicolyn.tmux.attemptControlMode`), connect over plain (raw) SSH; it must now show
     the SAME corrected behavior as ET (proving the fix is in the shared raw path).

## Out of scope

- The "font stuck at ~8pt" persisted-pinch-zoom issue (separate, long-open; the 70-col /
  ~11px-row metrics are that issue, not this one; this spec does not change the font).
- The -CC (`TmuxPaneContainer`) path (already correct; must not be double-inset).
- ET roaming banner, ET §4 dedicated error UI (queued follow-ups).
