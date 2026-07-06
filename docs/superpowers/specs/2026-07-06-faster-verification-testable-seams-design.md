<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Faster Verification via Testable Seams + Snappiness Guardrails

**Date:** 2026-07-06
**Status:** Design — awaiting user review
**Relates to:** the CI/TestFlight slow loop (~40 min/issue); the Humble-Object / `tmuxLaunchDecision`-pure pattern already established in `Sources/SemicolynKit/`.

## Problem

A single App-tier behavioral bug currently costs a ~40-minute round-trip: the macOS CI job (~18 min) only checks that the App target *compiles*, and everything behavioral is discovered on-device via TestFlight. This makes TDD and quick iteration impossible for App-tier work.

**Root cause, quantified (audit 2026-07-06):** the 8,267-line App tier is ~86% *genuinely* Apple-coupled (SwiftUI/UIKit/SwiftTerm/`@Published`) and only ~5% (~420 lines) pure/extractable — and most high-value decision logic (`tmuxLaunchDecision`, `moshBranchOutcome`, auth branching, `validateHostForm`, `CursorDragEngine`, OSC-52 policy) is *already* in Kit. The remaining pain is:
1. A small set of pure decision units still trapped inside Apple-coupled files (the exact bug classes that hurt: index wrap, cursor geometry, title clobber, mosh fallback).
2. A 1000-line `ConnectionViewModel` with ~20 `@Published` properties observed by 7 views (391 accesses) — a SwiftUI re-render risk.
3. The predictor sitting **synchronously on the keystroke send path**, coupling send latency to predictor cost.

**Non-goal:** a "systematic sweep of all 49 files" — the audit shows ~85% of that effort would find nothing to move. The correct move is surgical.

## Guiding principle

**Humble-Object seam, formalized (the app already follows it ~86%; we close the gap):**

- **View tier (`App/`)** — SwiftUI/UIKit/SwiftTerm, `@Published`, gestures, first-responder, pasteboard. Stays. Locally untested by design; macOS-CI-verified.
- **Decision tier (`Sources/SemicolynKit/`)** — pure `data → data` functions + value-type state machines. Everything new that is pure lands here. Linux `swift test`, real TDD.
- **Rule (the "View-only gate"):** an App file contains wiring + Apple types only. Pure branch/math/parse/validation is a bug — it belongs in Kit.

**User-action-first, side-effects-forked:** any per-interaction side-effect that is *observational* (predictor learning, context polling, diagnostics, title tracking) must not sit between the user's action and its primary effect. It observes a copy, off the interaction's executor.

**Extraction is runtime-zero-cost:** Kit is statically linked into the app — no bridge, no IPC, no serialization. Moving a function from `App/` to `Kit/` produces identical machine code. Snappiness is protected by *forking + measurement*, never by keeping logic in the View.

## Plan A — Extraction + tests + View-only gate (mostly Linux-testable)

### A1. Extract the one genuinely-trapped pure unit

**Reality check (verified against Kit 2026-07-06):** the initial audit read App excerpts, not the whole Kit, and *overcounted*. Four of the five candidate units are **already extracted and tested** in Kit:

| Candidate | Status |
|---|---|
| `cursorHaloPlacement` / cell geometry | ✅ `Sources/SemicolynKit/Terminal/CursorHaloGeometry.swift` + `CursorHaloGeometryTests` |
| `arrowEvents` (cursor→arrow encoding) | ✅ `Terminal/CursorArrowStream.swift` + `CursorArrowStreamTests` |
| `titleToPublish` (title-clobber policy) | ✅ `Tmux/ActivePaneTitle.swift` + `ActivePaneTitleTests` |
| `moshBranchOutcome` (mosh exit classify) | ✅ `Mosh/MoshBranchOutcome.swift` + `MoshBranchOutcomeTests` |
| `KeyboardCommand` enum + dispatch | ✅ enum in `Keybar/KeyboardCommand.swift` + `KeyboardCommandTests`; `perform()` is thin wiring (`tmux?`/`presentedSheet`), not extractable logic |

The app is already better-layered than the audit implied. **The only genuinely-trapped pure unit** is the window-step wrap-around math (still inline at `ConnectionViewModel.stepWindow`, no Kit function exists — grep for `WindowNavigation`/`stepIndex` returns nothing):

| New Kit unit | From | Test focus (EP + BVA + negative) |
|---|---|---|
| `WindowNavigation.stepIndex(current:delta:count:)` | `ConnectionViewModel.stepWindow:251` | count 0/1/2; delta ±1; idx at 0 and count−1; wrap direction correct; count≤1 → identity |

The App tier calls the pure function and *acts* on the result (selects the window). The unit gets a dedicated test file; tests assert observable expected values, and every negative/boundary test asserts the *specific* expected index (per the repo testing standard).

### A2. View-only gate (anti-regression)

A `lint`-tier script (Linux, fast) scans `App/**.swift` for pure-logic smells that belong in Kit (free-function arithmetic, value-returning `switch` over domain enums, parsing) and fails with a pointer to Kit. Tuned low-false-positive via an allowlist of wiring patterns (`@ViewBuilder`, `Binding` transforms, `@objc` gesture handlers, `body`).

**Fallback if too noisy:** downgrade from a hard CI gate to a documented convention + a line in the code-review checklist. Decision deferred to implementation once we see the false-positive rate on the current tree.

## Plan B — ViewModel split + PredictorActor + measurement (App-tier churn, macOS-CI-verified)

### B1. Split the god-ViewModel

`ConnectionViewModel` → three focused `ObservableObject`s so a mutation only invalidates its own subtree:

- **`SessionCoreModel`** — connection state, prompts, banners → `SessionView`.
- **`TmuxViewModel`** — `tmuxState`, windows, titles, pane contexts → pane container + tab strip.
- **`PredictorViewModel`** — suggestions, fn-state, keybar → the 5 Keybar views (currently over-observing the whole VM).

A thin coordinator owns the three and the shared connection lifecycle. Views migrate from observing the monolith to observing their slice.

### B2. Fork the predictor off the keystroke path (`PredictorActor`)

**Current (wrong) ordering** — `sendTerminalInput` calls `observePredictorInput(bytes)` *before* writing the byte, and `observePredictorInput` runs synchronous per-keystroke work ending in `refreshPredictorSuggestions()` (called twice per invocation, every keystroke). Send latency is coupled to predictor cost.

**Target — user-action-first, producer/consumer:**

```
sendTerminalInput(bytes):
  1. write(bytes)                    // SEND — sacred, never blocked (mosh/tmux/raw)
  2. if !secret && !optedOut:        // cheap classify on main
        anchor = snapshotEchoAnchor()  // grid read — main-actor, cheap
        await predictor.enqueue(bytes, anchor)   // O(1) handoff, returns
```

`PredictorActor` is a Swift `actor` — its mailbox IS the FIFO, its executor IS the separate consumer, and actor isolation preserves the per-line token/echo ordering invariant for free (no hand-rolled queue/thread/Sendable plumbing).

**Pipeline split by what each stage needs** (the SwiftTerm grid is `@MainActor`-bound, so the consumer cannot read it):

| Stage | Needs main? | Runs where |
|---|---|---|
| Produce: secret/opt-out filter, echo-anchor snapshot, enqueue | anchor yes; rest no | Main (cheap; already there) |
| Consume: token tracking, `engine.record`, vocab update | **No — pure Kit** | **`PredictorActor`, off main** |
| Echo-confirm: did the char echo on the grid? | **Yes — reads grid** | Main, deferred (already a ~40 ms hop) |
| Publish: update `@Published suggestions` | Yes (SwiftUI) | Main, **coalesced** |

The FIFO carries **already-echo-classified tokens**, not raw grid-dependent bytes. `refreshPredictorSuggestions()` is **coalesced** (trailing debounce) so a typing burst recomputes suggestions once, not per keystroke — likely the single biggest jank reducer.

**Concurrency-correctness obligations:** `PredictorEngine` state moves behind the actor (or the actor owns it); the echo-anchor is captured per-call (existing invariant, preserved); ordering across a line's tokens is guaranteed by the actor's serial mailbox. The grid-reading echo-confirm remains a deferred main-actor step and is the one part that cannot move off-actor — documented as such.

### B3. Measurement (make "snappy" a number)

First perf instrumentation in the app — `os_signpost` intervals on:
- (a) per-keystroke **input → write** latency (the sacred path);
- (b) `@Published` fire count per frame (validates the B1 split);
- (c) tmux poll cost.

Plus a short `docs/` note on capturing an on-device Instruments trace. This gives the CI/TestFlight loop a *perf* thing to rubber-stamp and turns sluggishness from a fear into a watched metric.

## Testing

- **Local, ~2 min, Docker `swift test`:** all Plan-A units + the `PredictorActor` consume/ordering logic (actor logic is Kit-pure and Linux-testable). The exact bug classes that cost device round-trips (index wrap, cursor geometry, title clobber, mosh fallback, command dispatch) become regression tests.
- **CI still owns:** App compile, Simulator layout, interaction — but now *rubber-stamps* known-good logic instead of *discovering* logic bugs.
- **Tests are real:** EP + BVA on every boundary; negative tests assert the specific failure (e.g. "background pane title → nil", "pre-first-frame exit → `.sshFallback`"), never merely "no crash" / "is-ok".

## Sequencing & risk

- **Plan A first** (extraction + tests + gate) — low risk, mostly Linux-verified, delivers TDD on the proven-pain bug classes immediately.
- **Plan B second** (split + PredictorActor + measurement) — higher App-tier churn, macOS-CI-verified only, concurrency-correctness surface. Gate B on A landing green.
- **Riskiest piece:** the View-only gate's grep heuristic (A2) — has a documented downgrade path. Second-riskiest: `PredictorActor` ordering vs. the existing L1 echo invariants (B2) — mitigated by moving the *pure* consume stage only and keeping the grid read deferred-on-main.

## Out of scope

- Cloud/physical Mac procurement (separate decision; Docker-OSX ruled out — Apple EULA + no nested-virt on CI).
- Simulator snapshot testing / XCUITest for layout & interaction layers (a possible future spec once the seam + measurement land).
- Refactoring the ~1,100-line `HostEditorSections.swift` (100% SwiftUI bindings — correctly Apple-coupled, nothing to extract).
