<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Gesture & Interaction System Design

**Status:** IN PROGRESS (interactive design, 2026-07-30). This is the canonical
specification for semicolyn's entire touch-interaction system. It supersedes the
scattered and partially-defunct gesture decisions in `docs/brainstorming-decisions.md`
(the 2026-07-10 "terminal-gesture-system" and 2026-06 cursor-drag specs are retired;
this document replaces them).

## Purpose

Ground the interaction/gesture requirements from first principles instead of
letting them emerge bug-by-bug from device testing. Define, for every gesture,
exactly what it does and what the user should experience, so implementation
carries out a deliberate design rather than accreting behavior.

## Guiding principles (these GATE every decision below)

Every topic in this document must satisfy all three. A design that violates any
of these is wrong, even if it is "functionally correct."

1. **Native & expected.** Matches iOS and terminal muscle memory. There is no
   semicolyn-specific behavior the user has to remember or work against. If a
   user has to think "how does semicolyn do X," the design has failed.
2. **Automatic, "it just happens."** Correct behavior with zero cognitive load.
   The user acts on muscle memory; the right thing occurs without deliberation.
3. **Snappy is correctness, not polish.** A correct gesture that lags is a
   FAILURE, not a success with a caveat. Perceived latency counts. Example: a
   swipe that changes windows two seconds later is a big fail. Where a gesture
   must wait on tmux/network, the design MUST make it FEEL immediate (optimistic
   local response) or the latency is called out explicitly as an accepted cost.

## Division of responsibility

- The USER defines usage and experience: what they do, what should happen, what
  feels right.
- The IMPLEMENTER (Claude) owns carrying it out: recognizer mechanics,
  feasibility, edge cases, latency mitigation. Where implementation constrains
  the experience, it is surfaced as a question, never silently decided.

## Topic areas

1. Governing model: panes, focus, and "which pane am I acting on"
2. Tapping (single-tap): focus / place-cursor / yield
3. Text: selection, copy, paste
4. Scrolling: normal-screen and alt-screen (Claude/vim)
5. Window swiping: horizontal swipe between tmux windows
6. Zoom: long-press (pane zoom) and pinch (font size)
7. Keybar: tap / long-press / swipe per key
8. Cross-cutting: gesture disambiguation, precedence, latency, haptics

---

## Topic 1: Governing model, panes, focus, "which pane am I acting on" [LOCKED]

**The problem this fixes:** today, touching a pane and acting on it are decoupled.
Selecting text in an inactive pane does not focus it, so paste/keyboard go to
tmux's active pane instead of the pane you touched (device report 2026-07-30:
selected in the bottom pane, paste landed in the Claude pane). That violates
principle 2 ("it just happens").

**THE RULE: focus follows input.**

> A gesture that SENDS BYTES to a pane makes that pane the active pane (keyboard
> target, paste target, accent border, tmux active pane). A gesture that only
> moves the LOCAL scrollback view sends nothing and is passive (no focus change).

Applied:

| Gesture | Sends bytes to pane? | Focus? |
|---|---|---|
| Single-tap (place cursor / focus) | yes (or is itself a focus action) | FOCUS |
| Double/triple-tap select | selection is the precursor to copy/act on THIS pane | FOCUS |
| Paste | yes (bytes) | FOCUS (pane must already be focused; see below) |
| Alt-screen scroll-drag (Claude/vim) | yes (arrow keys to the app) | FOCUS |
| Normal-screen scrollback drag (shell history) | no (moves local UIScrollView only) | passive |

**Consequences (these bind later topics):**
- You always act on the pane you touch. There is never a state where you select
  or paste in one pane while "active" is another. This eliminates the
  paste-to-wrong-pane bug *by construction*: selecting focuses, so paste (which
  targets the focused pane) lands where you selected.
- Because it is "focus follows input," the single test for any new gesture is:
  *does it send bytes to the pane?* If yes, it focuses first.
- Reading local shell scrollback never steals focus from the pane you are typing
  in. In practice you rarely scroll a *background* alt-screen (Claude) pane, so
  "alt-screen scroll focuses" almost never surprises (that pane is usually
  already active when you scroll it).

**Latency note (principle 3):** focus-on-touch must be applied OPTIMISTICALLY and
LOCALLY the instant the gesture is recognized (move the accent border + first
responder immediately), then reconciled with tmux's echoed `select-pane`. The
user must never wait a network round-trip to see focus move. (This is the
optimistic-border mechanism already built for tap-to-focus, PR #112.)

**Rationale:** matches every native split UI (VS Code panes, iPad Split View,
tmux-with-mouse): the pane you interact with is the one that is yours. Focus
following input is a single principle with no exception list to remember
(principle 1).

**Open thread for later topics:** double/triple-tap selection must ADD a focus
dispatch (it currently does not, per the 2026-07-30 audit); the paste target
routing must follow the focused pane. Detailed in Topic 3.

---

## Topic 2: Single-tap [LOCKED]

Single-tap resolves from Topic 1 (focus follows input) plus the tapped pane's
state and mode:

**Tap an INACTIVE pane** -> FOCUS it (optimistic border/keyboard move + tmux
`select-pane`). The tap is consumed by the focus switch: it does NOT also place a
cursor or forward to the app. (This is tap-to-focus, PR #112, device-confirmed.)

**Tap the ALREADY-ACTIVE pane** -> by mode:
- **Normal shell (`.localScroll`):** if a selection is active, DISMISS it (first
  tap clears selection, standard). Otherwise, NO-OP beyond keeping the keyboard
  up. (Tap-to-place-cursor is DROPPED, see below.)
- **Claude/vim (`.appOwnsInput`):** YIELD. Keep the keyboard up; send nothing.
- **Mouse-mode (`mouse=a`, `.mouseReporting`):** forward as an SGR mouse click to
  the app (the app asked for mouse events).

Every mode also raises the keyboard on tap if it is not already up (a dismissed
keyboard must be re-summonable by tapping the terminal).

**DROPPED: tap-to-place-cursor.** A terminal shell has no "click to move cursor";
readline only understands arrow keys, so tap-to-place was a SIMULATION (synthesize
N left/right arrows from the tap's column). It is the least-native, least-reliable
gesture in the system: it only works on the current input line, drifts on
wrapped / multiline / RPROMPT lines, and gives invisible wrong-place feedback,
which reads as exactly the "taps don't land where I tapped" complaint. Most iOS
terminals do not do it. Cursor movement lives where it is reliable: arrow keys /
keybar. Dropping it makes single-tap always-correct and surprise-free
(principles 1 and 2).

---

## Zoom trigger [DECIDED here; mechanics finalized in Topics 6/7]

Context: long-press on the terminal is being reassigned to TEXT SELECTION (its
native iOS home), so pane-zoom needs a new trigger. Investigation found there is
NO canonical iOS gesture for "maximize a pane": iPad Split View / Stage Manager
use explicit chrome (drag divider / tap handle), and desktop tmux uses an
explicit keybind (`prefix z`). So the MOST native answer is an explicit,
discoverable, one-handed control, not an invented multi-finger gesture.
Additionally, two-finger gestures are awkward one-handed (a phone terminal is
often one-thumb), disqualifying two-finger-tap as a PRIMARY trigger.

**DECISION: primary zoom is a plain, always-visible tappable control** (a keybar
button or the pane corner-index badge; exact placement finalized in Topic 6
"Zoom" / Topic 7 "Keybar"). Discoverable, one-handed, unambiguous, no hidden
gesture (principle 1). Long-press on the terminal is freed for selection.

**PARKED for Topic 7 (real discussion):** possibly tie zoom to the **Esc key**,
which already carries a long-press options menu, e.g. as a keybar per-key swipe
or a menu item, rather than a dedicated new key. Do NOT treat swipe-on-a-key as a
hidden one-off; if adopted, it should be part of a documented keybar per-key
gesture model (tap / long-press / swipe). Deferred, not decided.

**Two-finger double-tap** may ride along later as an optional two-handed
accelerator, but is not the primary and is not required.

---

## Topic 3: Text selection, copy, paste [MOSTLY LOCKED; one item pending investigation]

The freshest pain point and the reason for this whole design pass. Target: text
selection that feels second-nature, exactly like native iOS text.

### 3a. Selection gestures [LOCKED]
- **Double-tap = sub-word.** Breaks on punctuation (`. - / _ , :` and similar),
  matching iOS/desktop double-click. Double-tapping `staging` in
  `.claude-staging-oauth.json` selects `staging`, NOT the whole token. (Fixes the
  2026-07-30 device complaint; today's code treats everything non-whitespace as
  one word.)
- **Triple-tap = line.**
- **Long-press-drag = select an arbitrary range from scratch** (press, then drag
  to select; loupe follows). Unblocked now that long-press is no longer zoom.
- **Selecting FOCUSES the pane** (Topic 1: selection is the precursor to copy /
  acting on this pane). This is the construction-level fix for paste-to-wrong-pane.

### 3b. Selection extension: handles + loupe [LOCKED as UX; rendering path pending 3f]
- After any selection, **draggable endpoint handles**: a ball at the TOP of the
  start edge and a ball at the BOTTOM of the end edge (iOS-standard). Drag a
  handle to grow/shrink; the opposite end stays anchored.
- **Magnifier loupe** appears while dragging a handle (and during long-press-drag),
  showing the character under the fingertip so placement is precise (finger does
  not obscure the target). This is THE native affordance the user asked for.
- This is what makes double-tap-sub-word complete: double-tap `staging`, then drag
  the end handle out to cover the whole filename.

### 3c. Copy menu [LOCKED]
- **Auto-appears at the selection** the moment a selection is made (iOS edit menu:
  Copy / Paste / Select All), native pattern.
- **Re-summonable** if dismissed while a selection is still active, via EITHER a
  **tap ON the selected text** OR a **two-finger-tap**. A single tap OUTSIDE the
  selection CLEARS it (Topic 2).
- Copy writes to the iOS system clipboard.

### 3d. Paste [LOCKED]
- Targets the **FOCUSED pane** (Topic 1). Because selecting/tapping focuses,
  paste lands where you are working: the wrong-pane bug is fixed by construction.
- **Bracketed paste at the cursor** when the app supports it, so multi-line pastes
  stay intact and are treated as pasted text (not auto-executed commands / not
  auto-indent-mangled in editors). Available from the edit menu when the clipboard
  has text.

### 3e. Scope [LOCKED]
- Selection operates on the VISIBLE screen, including after scrolling up (uses the
  Kit-tested TapRowMapping for the scrolled offset). One selection is bounded to
  a screenful; MULTI-PAGE selection that grows across scroll is DEFERRED.
- Local iOS-native model (no tmux copy-mode / no server-side scrollback selection
  in this pass).

### 3f-RESULT. Spike verdict [LOCKED, 2026-07-30]: CUSTOM (native not viable)
The native-vs-custom spike returned CONCLUSIVE (static source, zero device builds).
Native `UITextInteraction` is NOT viable, all three gates failed:
1. **Cannot suppress only content-drag-select.** UIKit bundles all its
   text-interaction recognizers under one `_UITextSelectionInteraction` delegate;
   the content-select pan and handle-drag pan are indistinguishable at runtime.
   All-or-nothing, `.none` is the only off-switch.
2. **Cannot toggle per-mode.** `editingInteractionConfiguration` is read ONCE at
   `becomeFirstResponder`, not live; runtime flips do not reinstall the interaction.
3. **DECISIVE: SwiftTerm's `UITextInput` conformance is STUBBED for terminal use.**
   `firstRect(for:)` returns the whole view (loupe would magnify the entire pane,
   not the character), `caretRect(for:)` returns view bounds (handles snap to view
   edges, not cells), `closestPosition(to:)` ignores the tap point (tap-to-position
   always lands the same wrong spot). SwiftTerm is a terminal, not a text editor:
   real selection lives in `Terminal.buffer.selection` (grid cells), which has NO
   mapping to UIKit UTF-16 text positions. So native selection UI would render
   VISIBLY BROKEN even on the shell.

Therefore CUSTOM is not a compromise, it is the ONLY grid-aware option (a custom
loupe/handles can snap to real cells; native cannot). "Go native" was the right
instinct but the framework cannot deliver it here because SwiftTerm does not
expose the terminal grid as native text. The user's "verify early to pivot
cheaply" call paid off: resolved with ZERO device builds.

### 3f. Selection UI rendering path [LOCKED: Path B / custom]
**Design intent (user, 2026-07-30): use iOS-native `UITextInteraction`
everywhere it can be, and verify the risky part EARLY so we can pivot cheaply if
it does not hold.** Rationale: in the NEW gesture design, most "selection"
gestures (double/triple-tap select, handle-drag, long-press-drag, loupe) ARE
exactly what `UITextInteraction` provides, so custom-building them reinvents iOS.
Going native inherits the real loupe + handles + tap-position instead of
rebuilding them (principle 1, most "exactly like iOS").

Why PR #90's `.none` was NOT a "can't": it was a BLUNT total off-switch for the
old ad-hoc gesture setup, where UIKit's selection-drag pan fought our custom
single-finger drag handlers. The redesign removes most of that tension: taps,
handles, and loupe are ALIGNED with UITextInteraction; the ONLY residual conflict
is **single-finger content-drag** (scroll / window-switch / alt-screen->arrows),
which we own.

**THE PIVOT-GATE (verify before building on it):** can UITextInteraction's
`drag-to-select-on-CONTENT` recognizer be separated / suppressed while KEEPING its
tap + handle-drag + loupe, VALIDATED SPECIFICALLY ON THE ALT-SCREEN
(`.appOwnsInput`), where a content-drag must remain "scroll -> arrows" and NOT
become a text selection? The alt-screen is the highest-risk zone (a Claude
scroll-drag would fight drag-to-select).
- **If YES (separable):** native selection EVERYWHERE. One consistent UI. The
  custom loupe (3h) is DELETED from scope, we inherit the system loupe. Content
  drag stays ours (scroll/switch/arrows) in every mode; selection is initiated by
  taps + handle-drag + long-press only.
- **If NO (UITextInteraction is all-or-nothing / its content-pan is not
  suppressible):** PIVOT to hybrid, native on `.localScroll` (shell), SwiftTerm's
  OWN rendering (3f-old / Path B below) on `.appOwnsInput` + `.mouseReporting` so
  alt-screen scrolling is never threatened. Cost of the wrong guess = only the
  spike, discovered before any device build.

**Spike method:** static first (no device build), read how `UITextInteraction`
attaches to a `UITextInput` view, whether its member recognizers are individually
addressable/disable-able, and how SwiftTerm's iOS `UITextInput` conformance
exposes/creates them. If statically all-or-nothing, pivot with ZERO device cost.
If plausibly separable, a minimal device check confirms on the alt-screen.

**Fallback rendering (Path B, if we pivot):** SwiftTerm draws its own highlight +
handle circles in `drawRect` independent of `.none` (`AppleTerminalView.swift`:
`selectedTextBackgroundColor` fill ~1464-1515; `drawSelectionHandle` ~1741). We
add a pan over the handle zones -> `selection.extend`, plus the custom loupe (3h).

### 3g. Invisible-highlight root cause [DIAGNOSE ON DEVICE, do NOT guess again]
The code says SwiftTerm's highlight SHOULD be visible with `.none`, so the
device-observed invisible highlight is a specific bug, not the general design. The
recent `setNeedsDisplay` change (commit 64dc281) was a GUESS and may not be the
real cause. Ranked root-cause candidates (investigation 2026-07-30):
1. **(MEDIUM-HIGH) Selection cleared by a mode transition / tmux `-CC` repaint
   between set and draw** (fits the alt-screen, constant-repaint device report).
2. (MEDIUM) `selectedTextBackgroundColor` transparent/unset at draw time.
3. (MEDIUM) selection range computed zero-width on the alt-screen.
4-5. (LOW) overlay hiding it / dirty-rect misses selected rows.
**Required next step: a DIAGNOSTIC build** that logs `selection.active`, the
selection color value, and `selection.start/.end` immediately after
`setSelectionRange`, again after `setNeedsDisplay`, and on the next repaint, with
`.gesture` on. Compare normal-screen vs alt-screen. This tells us WHICH candidate
it is instead of shipping another guess. (Directly addresses the user's core
frustration: stop guessing through the device loop.)

### 3h. Loupe [LOCKED: in-scope, real magnifier]
The loupe (magnifier while dragging a handle / long-press-drag) is ESSENTIAL, not
polish: when a finger drags a selection boundary it OCCLUDES the target character,
so without the loupe you place the boundary blind, exactly the "doesn't land where
I meant" failure. It ships as part of "selection done."

**Why the loupe is the one custom piece (verified against SwiftTerm 1.x source
2026-07-30, not assumed):** highlight and handle CIRCLES are drawn by SwiftTerm
inside its own `drawRect` (they are part of rendering the character grid, so they
come free): `selectedTextBackgroundColor` fill + `drawSelectionHandle`
(`AppleTerminalView.swift:1741`, draws a 12pt ellipse per end when
`selection.active`). A magnifier is fundamentally different: a separate FLOATING
view showing a zoomed snapshot of a screen region tracking the finger, which is
NOT part of drawing the grid. A grep of all SwiftTerm iOS source found ZERO
loupe / magnifier / `UITextInteraction` references, so there is nothing to
inherit, and native iOS loupe comes from `UITextInteraction` which `.none`
disables. Hence: custom overlay (~200-300 lines).

**Loupe design:** classic floating circular magnifier above the finger,
screenshot the region under the contact point, scale up, glass effect, track the
finger, hide on release. Perf note: must not choke on the tmux `-CC` repaint
stream (snapshot on a throttle, not every frame).

**Build order (dependency-ordered for provability, all land together as "selection
done"):**
1. Diagnose + fix the visible-highlight bug (3g) on a diagnostic build. The loupe
   magnifies the highlight, so highlight must render first.
2. Draggable handles (pan recognizer over SwiftTerm's drawn handle zones ->
   `selection.extend`).
3. Custom magnifier loupe.
Each step device-verified before the next; shipped together. Native UITextInteraction
is ruled OUT (3f-RESULT), so this custom path is the whole selection UI, not a
fallback. All of it is grid-aware (snaps to real cells), which native could not be.

---

## Rendering engine: SwiftTerm behind a `TerminalRenderer` protocol [LOCKED]

**The question (raised 2026-07-30):** the user is not attached to SwiftTerm. The
goal is the target experience (native feel, native functionality, no speedbumps);
the engine's fate is an OUTPUT of the requirements, not a protected input. No
sunk-cost. So: keep SwiftTerm, replace it, or something in between, whatever the
requirements adjudicate, item by item.

**Coupling survey (ground truth, 2026-07-30, read-only over the App tier):**
- **~1,900 LOC** touches SwiftTerm, ALL in the App tier. `SemicolynKit`, the tmux
  `-CC` control-mode parser, the predictor, and the keybar have **ZERO** SwiftTerm
  dependency. Our logic is already renderer-agnostic; only the VIEW layer is coupled.
- The coupled API surface is **narrow and well-shaped**: `feed(byteArray:)` in;
  reads of `getCharData(col:row:)`, `cols`/`rows`, `isCurrentBufferAlternate`,
  `mouseMode`/`applicationCursor`, `getCursorLocation()`, `buffer.yDisp`. Plus the
  9-method `TerminalViewDelegate`.
- SwiftTerm is **stock upstream, unforked**, `from: "1.0.0"` in `project.yml`.
- **DECISIVE for scrolling:** on iOS, SwiftTerm's `TerminalView` *is a
  `UIScrollView`* (`iOSTerminalView.swift:54`). Native scroll physics, deceleration,
  and rubber-band bounce are already the engine, not something we'd have to build
  or replace the renderer to get.

**DECISION: keep SwiftTerm, wrapped behind a thin `TerminalRenderer` protocol.**
The protocol exposes exactly the narrow surface above (`feed`, `cellAt`/`charData`,
`gridSize`, `isAlternate`, `mouseMode`, `cursor`, delegate events). Revisit an
engine swap ONLY when a specific requirement is shown to be structurally impossible
on SwiftTerm. Rationale:
- **No sunk cost to protect:** the protocol makes a future swap cheap (per the
  survey, replacement is a bounded multi-week project *behind the protocol*, with
  gestures/selection/tmux/predictor untouched). We do not have to make a
  keep-vs-replace bet now; we defer it and keep it cheap.
- **Nothing so far forces a swap.** The two user goals, native scroll FEEL and no
  speedbumps, are both reachable in our OWN code (scroll = configure the
  UIScrollView we already are; speedbumps = fix our gesture arbitration). The one
  thing SwiftTerm genuinely cannot do, native `UITextInteraction` selection, we
  already chose to build custom and grid-aware (3f-RESULT), which is BETTER here,
  not a compromise.
- Building the protocol is also the prerequisite for the future ET renderer
  (Track 3), so it is not throwaway work.

**This is engine-neutral by construction:** every later topic states its target
experience first, then tests "can SwiftTerm deliver this?" The protocol is where a
"no" gets absorbed cheaply.

---

## Topic 4: Scrolling [LOCKED]

Target experience (engine-neutral): native iOS feel, zero speedbumps, snappy by
construction (principle 3). Decomposes by mode.

### 4a. Normal shell (`.localScroll`) [LOCKED]
- **Native `UIScrollView` rubber-band bounce.** SwiftTerm's iOS `TerminalView`
  already IS a `UIScrollView` (`iOSTerminalView.swift:54`) and sets no
  `bounces`/`decelerationRate` overrides, so native bounce is essentially FREE:
  keep `isScrollEnabled = true`, ensure `bounces`/`alwaysBounceVertical = true` and
  `decelerationRate = .normal`. This is a CONFIG task on the scroll view we already
  own, NOT a renderer change.
- **Drag tracks the finger 1:1 from contact; flick → momentum → decelerate → bounce
  at the ends.** Genuine UIKit physics.
- **Passive: sends nothing, no focus change** (Topic 1). Reading shell history never
  steals focus.
- **Instant: history is the local SwiftTerm buffer, zero network on any drag**
  (principle 3). Deep server-backed history is DEFERRED (matches the one-screenful
  + seeded-scrollback scope from Topic 3e); no automatic network fetch on a drag
  boundary (that would be the exact lag principle 3 forbids).
- **Content-drag is ALWAYS scroll.** Drag-to-select-from-scratch on the shell is
  DROPPED; selection starts only via double/triple-tap + handle-drag + long-press
  (Topic 3). This is what lets the scroll pan win a vertical drag INSTANTLY with no
  "scroll or select?" disambiguation delay.

### 4b. Alt-screen (`.appOwnsInput`, Claude/vim) [LOCKED, carried from Topic 1]
- **1:1 finger-follow translated to the app's scroll** (arrow keys / xterm
  Alt-Scroll) **+ momentum.**
- **Sends bytes → FOCUSES the pane** (Topic 1).
- **No rubber-band bounce**, correct and intended: there is no local content to
  bounce against (the remote app owns the screen), exactly like every native
  terminal. "Bounce" is a `.localScroll`-only affordance.

### 4c. Mouse-mode (`.mouseReporting`, `mouse=a`) [LOCKED]
- A drag forwards as SGR mouse events (the app asked for mouse). No local scroll,
  no bounce. Focuses (sends bytes). Consistent with Topic 2's mouse-mode tap.

### 4d. The speedbump root cause + fix [LOCKED as the implementation target]
The "sluggish / doesn't start scrolling" feel is OUR gesture arbitration, not the
renderer:
- We flip `isScrollEnabled` per mode (`TerminalScreen.swift:76`) and, in
  `.appOwnsInput`, disable the native pan and re-implement scroll via our own
  `altScreenPan` (`TerminalGestureController.swift`).
- Our recognizer sweep disables SwiftTerm's recognizers and layers `switchPan` +
  `altScreenPan` competing for the same vertical drag.

**Fix target:** a vertical-dominant content-drag is owned by the scroll pan
IMMEDIATELY; `switchPan` (window switch, Topic 5) engages only on a
horizontal-dominant drag (the existing `DragAxisLock` decides axis). No shared
disambiguation delay on the common vertical-scroll case. Alt-screen keeps its
1:1→arrows pan, but that pan likewise starts on contact (no threshold beyond axis
lock).

---

## Topic 5: Window swiping [LOCKED]

**Horizontal swipe switches WINDOWS only** (whole screen changes to the next/prev
tmux window, panes and all). It NEVER moves pane-to-pane focus, that is tap-only
(Topic 1/2, tap an inactive pane to focus it). One gesture, one meaning; no native
iOS precedent for "swipe to move split focus," and it would collide with the window
switch.

- **Direction:** swipe LEFT → next window (index +1); swipe RIGHT → previous window
  (index −1). Matches iOS page/tab-carousel muscle memory (principle 1).
- **Wrap-around (infinite carousel):** past the last window → first; before the
  first → last. No hard stop and no end-bounce (with wrap there are no ends to
  bounce against). User-ruled 2026-07-30.
- **Snappy (principle 3):** fire on RELEASE past a horizontal-distance threshold;
  apply the target window OPTIMISTICALLY/locally (redraw the new window
  immediately), then reconcile with tmux `select-window`. The user never waits a
  network round-trip to see the window change. **No animation** (KISS, retained from
  the 2026-07-22 window-switch pass; the animated slide/dim machinery was
  deliberately deleted).
- **Disambiguation:** engages only on a HORIZONTAL-dominant drag (`DragAxisLock`
  decides axis at gesture start). A vertical-dominant drag is scroll (Topic 4).
  This single axis-lock is what keeps BOTH scroll and switch instant, no shared
  "which gesture?" delay.
- **Existing machinery reused:** `DragAxisLock` + `SwitchCommitDecision` +
  `select-window` are already built and Kit-tested (2026-07-22 KISS pass); Topic 5
  is those, made consistent with the axis-lock priority above. Nothing new to
  invent here.

---

