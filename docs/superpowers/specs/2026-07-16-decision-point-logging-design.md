<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Self-contained decision-point logging (standard + gesture path) — design

**Date:** 2026-07-16
**Status:** approved (brainstorm), ready for implementation plan
**Branch context:** builds on `fix/altscroll-b-context-and-logging`; unblocks the B/C/D alt-scroll retest.

## Problem

The user has hit "the logs are insufficient to reconstruct what I did" three times. The
logging *infrastructure* is already good (`App/LogCategory.swift`: 9 toggleable, autoclosure-
gated, persisted, remote-syslog-capable categories). The gap is a **coverage pattern**, not
infra: log lines record the *conclusion* of a decision, not the *premises*. Two examples from
PR #97:

- Bug B logged `gr:altPan keys=arrows` (the decision) but not the inputs (pane id +
  resolved pane command) that produced it. The log could confirm the wrong output but never
  say *why* -> a fresh diagnostic round-trip every time.
- A single drag today emits ~4 separate lines (`gr:<owner> began mode=`, `altPan enabled=`,
  `gr:altPan keys=`, `gr:winner`) that must be **correlated** to reconstruct one gesture.

A log line that shows an output without the inputs that determined it can CONFIRM a bug but
never DIAGNOSE it. The fix is to make **each decision line self-contained**: inputs + output
+ short reason, at the moment the decision is made.

## Principle (agreed)

**Each decision boundary emits one complete, self-contained line at the moment it decides,
carrying its inputs + output + a short reason.** No stashed record, no collapse-to-one-line,
no cross-line correlation to read any single line. High volume is acceptable because these
lines live behind a per-category toggle (see the `gesture` default-OFF change below).

A **decision boundary** = any function that maps inputs -> a routing / sizing / mode / gate
result.

## Section 1 — The standard

Three parts, deliberately lightweight (a format + a convention + one string helper; NOT a
logging framework). The gesture path does not *consume* the helper (it logs
`decision.logLine` directly), but the helper is **built and tested in this spec** anyway so
the standard ships complete and ready — a deferred-but-unused helper would quietly never get
written.

### 1a. Format

One line, self-contained, at the moment of decision:

```
<event> <input>=<v> <input>=<v> → <output>=<v> [reason=<short>]
```

Example:

```
alt-scroll pane=%0 mode=mouseReporting app=claude → keys=none reason=mouseReporting-disables-pan
```

### 1b. Truth-at-source (the Kit rule)

A pure decider in `SemicolynKit` **cannot** call `DebugLog` (the Linux-tested tier forbids
`import UIKit`/App deps). So a pure decider **returns a small `…Decision` value carrying its
inputs + output + reason**, and the App-tier caller logs `decision.logLine` verbatim. The
logged line therefore reflects what the decider *actually saw*, closing the drift class of
bug (the filtered-`paneContexts` bug, where the caller's belief differed from the decider's
input). The `reason` is derived *inside* the decider (which branch fired), so it can never
disagree with the output.

### 1c. App-tier uniformity helper

For App-tier boundaries that call `DebugLog` directly (grid sizing, context poll), a tiny
free function renders the same format so every line is uniform:

```swift
func decisionLine(_ event: String,
                  inputs: [(String, String)],
                  outputs: [(String, String)],
                  reason: String? = nil) -> String
```

It returns the string only (caller passes it to `DebugLog.shared.log(.<cat>, …)`), so gating
stays autoclosure-cheap. Rendered as `event a=1 b=2 → x=9 reason=…`. Lives in Kit as a pure
string function so it is Linux-testable.

**Built and tested in this spec**, even though the gesture path does not consume it (the
gesture lines log `decision.logLine` + interpolation). Shipping it now — proven, ready — is
deliberate: a deferred helper with no consumer would quietly never be written. The follow-up
sweep (§4c) then just *calls* an already-tested helper.

## Section 2 — Applying the standard to the gesture / alt-scroll path

### 2a. Kit change (`Sources/SemicolynKit/Terminal/AltScrollMode.swift`)

Add a decision struct + a decider that returns it; keep the existing `altScrollKeys(...)` as
a thin wrapper so behavior and existing call sites/tests are unchanged.

```swift
public struct AltScrollDecision: Sendable, Equatable {
    public let keys: AltScrollKeys        // output
    public let mode: AltScrollMode        // input
    public let paneCommand: String?       // input
    public let reason: String             // e.g. "off", "auto:registered", "auto:unregistered",
                                          // "alwaysPageKeys", "autoPlusTitle:cmd",
                                          // "autoPlusTitle:title"
    /// Self-contained, rendered in Kit as a pure string (no pane id — the App adds that,
    /// since the Kit decider does not know the pane id).
    public var logLine: String {
        "mode=\(mode.rawValue) app=\(paneCommand ?? "nil") → keys=\(keys) reason=\(reason)"
    }
}

public func altScrollDecision(mode: AltScrollMode,
                              paneCommand: String?,
                              windowTitle: String?,
                              registry: AltScrollRegistry) -> AltScrollDecision

// Behavior-preserving wrapper (existing signature/tests unchanged):
public func altScrollKeys(mode:paneCommand:windowTitle:registry:) -> AltScrollKeys {
    altScrollDecision(...).keys
}
```

`keys` for a given `reason` is fixed by construction (each branch sets both), so `keys` and
`reason` cannot disagree.

### 2b. App change (`App/TerminalGestureController.swift`)

The `altScrollKeys` callback becomes an `altScrollDecision` callback (returns the decision,
not just the keys). The controller then emits **three self-contained lines per drag**, all
under `.gesture`, replacing the scattered `gr:*` / `altPan enabled=` lines. The pane id is
NOT repeated on each drag line: the mount closure logs it once on an adjacent
`alt-scroll pane=%N <decision.logLine>` line at snapshot time, and every drag line belongs to
that same pane/drag. The `imode=` key is the `InteractionMode`; it is intentionally distinct
from the `mode=` inside `<decision.logLine>` (which is the `AltScrollMode`), so the two never
collide on one line.

- **`.began`:**
  `drag-begin winner=<recognizer> imode=<InteractionMode> appCursor=<bool> <decision.logLine>`
  (`winner=` folds in the old `gr:winner` line; `<decision.logLine>` carries
  mode+app+keys+reason from the Kit decider verbatim.)
- **each emitting `.changed`:**
  `drag-move keys=<arrows|pageKeys> runs=<n> sent=<cells> total=<emittedCells>`
- **`.ended`:**
  `drag-end owner=<altPan|scrollPan> imode=<InteractionMode> emitted=<n> outcome=<scroll|pageKeys|arrows|none>`
  `outcome` is computed from what actually happened this drag (`altPan`: `pageKeys`/`arrows`
  when `emitted>0` else `none`; `scrollPan`: `scroll` in `.localScroll` else `none`), so
  `drag-end` alone answers "did this drag do what the mode intended": the exact signal the
  B-bug retest needs.

**Removed / folded:** `gr:<owner> began mode=`, `altPan enabled=`, `gr:altPan keys=`,
`gr:winner` -> subsumed by the three lines above.

## Section 3 — Session & user-action markers (replay without narration)

All at the `.lifecycle` tier (default-ON, low-volume). Decision lines say *what each drag
did*; markers say *what the tester did and when*, so a trace is self-narrating.

### 3a. Session marker (once, at session/attach start)

```
=== session-start build=<n> transport=<ssh|mosh|et> host=<alias> window=@<id> panes=<count> ===
```

Anchors every later line (build, window) so a pasted fragment is self-locating.

### 3b. User-action markers (a discrete tester intent, NOT a code consequence)

- `user-action: mode-switch <alt-scroll-mode>`  (e.g. picked PgUp/PgDn in Experimental)
- `user-action: zoom pinch scale=<f> → font=<pt>`  (also captures the D-bug continuous-zoom evidence)
- `user-action: settings-change <key>=<value>`
- `user-action: window-switch @<from> → @<id>`

Read top-to-bottom, a trace becomes a sentence:
`session-start … → user-action: mode-switch alwaysPageKeys → drag-begin … → keys=… → drag-end … outcome=select`
— no narration needed.

### 3c. Explicitly NOT logged (honest caveat)

Per-keystroke content (privacy-sensitive; never log key content) and per-frame render (too
high-volume; drowns signal). The standard is "every *decision's* inputs+output and every
*user intent*", not "every byte." This is why `input`/`render`/`predictor` default OFF.

## Section 4 — Category change, testing, scope boundary

### 4a. `gesture` -> default-OFF

Remove `.gesture` from `LogCategory.defaultEnabled` (leaving `lifecycle, connect, tmux,
seed`). The new drag lines are dense-but-self-contained, opt-in when debugging gestures —
same tier as `render`/`input`/`predictor`. Session/user-action markers stay visible by
default because they are at `.lifecycle`, not `.gesture`.

### 4b. Testing (Kit-testable logic gets real tests; App tier via device retest)

- **`AltScrollDecision`** — EP over all 4 `AltScrollMode` cases × {registered app,
  unregistered app, `nil` command}. Assert **exact** `keys` AND exact `reason` string, and
  that `logLine` contains the inputs. Boundary: `nil` `paneCommand` in `.auto` vs
  `.autoPlusTitle` (different branches). Negative: an unregistered command never yields
  `.pageKeys` in `.auto`.
- **`altScrollKeys(...)` wrapper** — round-trip: for every mode/input, assert it equals
  `altScrollDecision(...).keys` (guards the wrapper from drifting from the decider).
- **`decisionLine(...)`** — exact-format assertion (input order, `→`, output order, optional
  reason present/absent). Kit-testable (pure string function).
- **App-tier gesture lines / markers** — not Linux-testable; validated on device by the
  retest (the whole point), and App code compiles only on macOS CI.

Tests follow the repo testing standard (assert observable exact values; a negative test
asserts the *specific* failure — here, the *specific* wrong key family, not just "not
pageKeys").

### 4c. Scope boundary (NOT in this spec)

The other decision boundaries named in memory adopt the standard in a **follow-up sweep**,
each a small independent change. They *call* the already-built, already-tested App-tier
`decisionLine(...)` helper (§1c):

- tmux grid sizing (`ContainerView.layoutSubviews` / `noteClientSize` / `terminalGrid`)
- context poll -> `paneContexts`
- transport / Mosh-fallback decisions
- seed / reconcile decisions

This spec delivers the standard + the gesture path + markers, which is exactly what unblocks
the B/C/D retest.

## Deliverables

1. `AltScrollMode.swift`: `AltScrollDecision` + `altScrollDecision(...)` + behavior-preserving `altScrollKeys(...)` wrapper (Kit).
2. `decisionLine(...)` helper + short format doc-comment (Kit, pure string; built now, gesture path doesn't consume it — ready for the §4c sweep).
3. `TerminalGestureController`: three self-contained drag lines (`drag-begin`/`drag-move`/`drag-end`); `gr:winner` folded into `drag-begin`; callback switched keys -> decision.
4. Session + user-action markers at `.lifecycle` call sites (attach start; mode-switch; pinch-zoom; settings-change; window-switch).
5. `LogCategory.swift`: `.gesture` removed from `defaultEnabled`.
6. Kit tests: `AltScrollDecision` (EP+BVA+negative), wrapper round-trip, `decisionLine` format.
7. Retest note (in the plan / TODO): enable `gesture` (and any other needed category) before the scripted drag; markers make the trace self-narrating.

## Non-goals

- No new logging framework / stored-record accumulator.
- No per-keystroke or per-frame logging.
- No sweep of the non-gesture boundaries (deferred, 4c).
- No behavior change to alt-scroll routing (the wrapper preserves it); this is a logging +
  return-shape change only.
