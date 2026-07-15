<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# App-aware alt-screen scroll + Experimental settings — design

**Date:** 2026-07-15
**Status:** approved (brainstorm), pending implementation-plan
**Follows:** the alt-screen own-pan scroll fix (PR #94, main `187a67f`) which made an
alt-screen drag reach the foreground app as key input. This spec decides *which* keys.

## Problem

An alt-screen drag now synthesizes **arrow keys** to the foreground app (the xterm
"Alternate Scroll" model — matches iTerm2, Windows Terminal, WezTerm). Pagers/editors
(`less`, `vim`, `htop`) bind arrows to scroll, so they scroll correctly (device-confirmed,
build 49).

But a cluster of **full-screen AI-CLI TUIs bind arrows to prompt history**, so a drag
navigates history instead of scrolling, and the app shows a hint like *"Scroll wheel is
sending arrow keys · use PgUp/PgDn to scroll"*:

- **Claude Code** (`claude`) — custom Ink fork; issues anthropics/claude-code #65833,
  #66601, #70724.
- **Gemini CLI** (`gemini`) — Ink; google-gemini/gemini-cli #13256, #17389, #13149.
- **OpenAI Codex** (`codex`) — Rust/Ratatui (NOT Ink); openai/codex #2836.
- **Qwen Code** (`qwen`) — Ink.

This is a UX *pattern* shared across TUI frameworks (Ink AND Ratatui exhibit it), **not a
library** we can detect. There is no runtime signal for "this app binds arrows to history"
and no escape sequence that identifies the TUI library. The only observable per-pane signal
is the **running command name**, and that is reliable **only under tmux**
(`pane_current_command`; verified in our own device logs as `%0 claude`). Raw-SSH/mosh have
no per-pane process signal — only the OSC window title, which for these apps is dynamic
(`"myrepo: fixing auth"`), directory-prefixed, task-derived, user-customizable
(`CLAUDE_TITLE_PREFIX`), and often absent — too brittle to drive a native-feeling default.

**Goal:** make scroll feel native in these apps where we can do it reliably (tmux), keep the
xterm-standard arrows everywhere else, and expose the brittle/blunt options as clearly-marked
opt-ins rather than silent defaults.

## Non-goals

- Detecting the TUI library (impossible; and library ≠ behavior — Codex proves it).
- User-editable JSON registry override (YAGNI for v1; the bundled set covers the known
  cluster and adding an app is a one-line Kit change + test. Future extension point mirrors
  `PromotionCatalog`.)
- Fixing the Claude-side issue (it is Anthropic's; our #94 fix is xterm-standard-correct).
- Alt-scroll sensitivity/lines-per-gesture tuning (deferred).

## Architecture overview

Two tiers, per the repo rule:

- **Kit (Linux-tested, pure):** the registry, the mode enum, the decision function, and the
  PgUp/PgDn byte encoder. All correctness lives here.
- **App (macOS-CI-only, thin wiring):** one snapshot input threaded into the existing
  alt-screen drag path, plus the Settings UI (a new Experimental section) and persistence.

## 1. Core logic (Kit — `Sources/SemicolynKit/Terminal/`)

### `AltScrollRegistry`

```swift
public struct AltScrollRegistry: Sendable {
    /// Apps whose alt-screen binds arrows to prompt-history → want Page keys.
    /// Extensible: adding one is a one-line change + a test.
    public static let bundledDefault = AltScrollRegistry(
        pageKeyApps: ["claude", "gemini", "codex", "qwen"])

    public let pageKeyApps: Set<String>   // lowercased process names

    /// Exact process-name match, case-insensitive. `"claude-wrapper"` does NOT match
    /// (exact token, not substring) — a false match would send Page keys to an app that
    /// wanted arrows, which feels broken.
    public func wantsPageKeys(command: String?) -> Bool

    /// Word-boundary, case-insensitive token match against an OSC title (title mode only).
    /// `"myrepo — claude: fix"` matches; `"unclaudely"` / `"vim README"` do not.
    public func wantsPageKeys(title: String?) -> Bool
}
```

### `AltScrollMode` + decider

```swift
public enum AltScrollMode: String, Sendable, CaseIterable {
    case off             // always arrows (xterm standard)
    case auto            // arrows, except a registered app in a tmux pane → page keys  [DEFAULT]
    case alwaysPageKeys  // every alt-screen drag → page keys (breaks less/vim line-scroll)
    case autoPlusTitle   // auto, plus best-effort OSC-title match on non-tmux (brittle)
}

public enum AltScrollKeys: Sendable { case arrows, pageKeys }

/// Pure decision the App snapshots once at drag `.began`.
/// - paneCommand: tmux `pane_current_command` for this pane; nil on raw/mosh.
/// - windowTitle: OSC 0/2 title; only consulted in `.autoPlusTitle`.
public func altScrollKeys(mode: AltScrollMode,
                          paneCommand: String?,
                          windowTitle: String?,
                          registry: AltScrollRegistry) -> AltScrollKeys
```

Decision table:

| mode | result |
|---|---|
| `.off` | `.arrows` |
| `.auto` | `.pageKeys` iff `registry.wantsPageKeys(command: paneCommand)` (nil command → arrows) |
| `.alwaysPageKeys` | `.pageKeys` |
| `.autoPlusTitle` | `.auto`'s result, OR `.pageKeys` if `registry.wantsPageKeys(title: windowTitle)` (command still wins when present) |

### Page-key encoding

`AltScreenScroll.arrows(totalDy:cellHeight:emittedCells:)` keeps its Δy→count logic
unchanged. The App picks the encoder by the snapshotted `AltScrollKeys`:

- `.arrows` → existing `encodeArrowRun(run, applicationCursorKeys:)` → `ESC[A` / `ESC[B`
  (or `ESC O A/B` under DECCKM).
- `.pageKeys` → new `encodePageKeyRun(run)` → `ESC[5~` (PgUp) / `ESC[6~` (PgDn). Direction:
  finger-down (+Δy, "reveal above") → **PgUp** (scroll back), matching the arrow convention.
  Page keys are not affected by DECCKM.

The per-emit clamp (`maxCellsPerEmit`) still bounds a flick; one "cell" of drag =
one PgUp/PgDn press (coarser than arrows by nature — that is the app's paging granularity).

## 2. App wiring (App — thin, macOS-CI-only)

In `TerminalGestureController`:

- **Snapshot once at `.began`** (in `beginDrag`, alongside `dragMode`/`dragAppCursor`):
  `dragScrollKeys = callbacks.altScrollKeys()`. A single drag cannot switch key-type
  mid-flight.
- **`.changed`** emits `dragScrollKeys == .pageKeys ? encodePageKeyRun(run) : encodeArrowRun(run, …)`.
- New `Callbacks` member: `altScrollKeys: () -> AltScrollKeys`.

Both mounts supply the callback, resolving via the pure decider:

- **tmux (`TmuxPaneContainer`):** closes over the pane's `PaneID`; `paneCommand =
  TmuxRuntime.paneContext(pane)`; `windowTitle = vm.terminalTitle`.
- **single-pane (`TerminalScreen`, raw/mosh):** `paneCommand = nil`; `windowTitle =
  vm.terminalTitle`. So `.auto` → arrows there; `.autoPlusTitle` can still match on title.

`mode` + `registry` come from the settings store. `@MainActor` isolation: the callback runs
in the gesture context — follow the `MainActor.assumeIsolated` convention for any
`@MainActor`/UIKit reads (see the recurring-trap note in project memory).

Symmetry: this is one more begin-time snapshot input beside the existing
`currentMode`/`applicationCursorKeys` — no new subsystem.

## 3. Settings & storage

### Persisted setting

`AltScrollMode` (default `.auto`) added to the terminal settings model in Kit (enum +
default), surfaced in the App via `@AppStorage`-backed binding, mirroring `cursorStyle` /
`scrollbackLines`.

### New `Settings → Experimental` section

A new top-level settings screen (mirrors the existing `DiagnosticsSettingsView` pattern),
headed "Advanced — may be unreliable":

```
Experimental
├─ Alt-screen scroll   (single-select radio — mutual exclusion by construction)
│    ( ) Off — standard arrow keys
│    (•) Auto — AI CLIs scroll with Page keys                 [default]
│         Claude, Gemini, Codex, Qwen in tmux use PgUp/PgDn instead of
│         arrows (which they read as prompt history).
│    ( ) Always Page keys
│         ⚠ Every full-screen app gets PgUp/PgDn; breaks line-scroll in less/vim.
│    ( ) Auto + window-title match (SSH/Mosh)
│         ⚠ Also guesses the app from the window title on non-tmux sessions.
│           Unreliable — titles are dynamic and may misfire.
└─ Diagnostics    →   (relocated here from top-level Settings)
     master logging enable · per-category toggles · syslog sink
```

### Diagnostics relocation

Top-level `SettingsView` is a `List` of `row(...)` entries keyed by a `SettingsSection` enum
(currently `.appearance` / `.terminal` / `.privacy` / `.diagnostics`). The relocation:
add a `.experimental` case + its top-level `row` (→ `ExperimentalSettingsView`), and **remove
the top-level `.diagnostics` row** — Diagnostics becomes a `NavigationLink` inside
`ExperimentalSettingsView` instead. `DiagnosticsSettingsView` is **unchanged internally**;
only its entry point moves — reached from Experimental instead of top-level Settings. This relocation also lets us **revert the
temporary `.keybar`-default-ON hack** (`LogCategory.defaultEnabled`, added by the #4/#5
sizing-diagnostics build): the sizing logs return to opt-in (default OFF) under
Experimental → Diagnostics like every other category.

### Registry

`AltScrollRegistry.bundledDefault` in Kit; no user override in v1.

## 4. Testing

Risk tier: **Core** (user-facing interaction logic; no security surface) → EP + BVA +
good-and-bad per partition, exact-value assertions, no tautologies.

### Kit (Linux, XCTest)

`AltScrollDeciderTests` — `altScrollKeys(...)`:
- **EP, per mode × signal:** `.off` → arrows even with `paneCommand:"claude"`; `.auto` →
  pageKeys for `"claude"`, arrows for `"bash"`, arrows for `nil`; `.alwaysPageKeys` →
  pageKeys for `nil` / `"bash"` / `"claude"`; `.autoPlusTitle` → pageKeys on title match when
  command is `nil`, and command wins when both present.
- **BVA / adversarial (anti-tautology heart):** empty + whitespace command → arrows;
  case-insensitivity (`"Claude"`, `"CLAUDE"`); **substring false-positive guards** —
  `"claude-wrapper"` command must NOT match (exact token), title `"unclaudely"` must NOT
  match (word boundary). These fail if matching is naive `contains`.

`AltScrollRegistryTests` — `wantsPageKeys(command:)` exact + case-insensitive;
`wantsPageKeys(title:)` token/word-boundary; 4 bundled defaults present; unregistered app
absent.

`AltScreenScrollKeyEncodingTests` — reuse existing Δy→count coverage; assert
`encodePageKeyRun` emits exact `ESC[5~` / `ESC[6~` bytes with correct direction
(finger-down → PgUp); assert arrow-vs-page selection routes to the correct encoder. Exact
expected byte arrays, never "non-empty".

### App tier (macOS-CI-only)

Recognizer wiring + settings binding are compile-validated on the macOS CI job. The
begin-time snapshot behavior isn't unit-tested (App tier), but the pure decider it calls is
fully covered. **Device retest** confirms end-to-end: a drag in a Claude tmux pane → PgUp/PgDn
→ transcript scrolls; a drag in `less` → still arrows → line-scrolls.

## Files touched

**Kit (new):** `AltScrollRegistry.swift`, `AltScrollMode.swift` (+ decider),
`encodePageKeyRun` (in the existing arrow-encoder file). **Kit (edit):** terminal settings
model (add `AltScrollMode` + default). **Kit (tests):** the three test files above.

**App (edit):** `TerminalGestureController.swift` (snapshot + encoder branch + callback),
`TerminalScreen.swift` + `TmuxPaneContainer.swift` (supply `altScrollKeys` callback), a new
`ExperimentalSettingsView.swift`, settings-tree entry point moves for Experimental +
Diagnostics, `LogCategory.swift` (revert temp `.keybar` default-on).

## Risks / mitigations

- **False page-keys feel broken.** Mitigated by exact/word-boundary matching (no substring),
  tmux-only reliable signal by default, and the whole feature being a labeled radio the user
  can set to `.off`.
- **Title mode brittleness.** Contained: opt-in `.autoPlusTitle` only, with an inline ⚠
  disclaimer; never the default.
- **`pane_current_command` staleness (~1 Hz poll).** Up to ~1s after launching the app
  before it's detected; acceptable for a scroll gesture. Snapshot-at-`.began` keeps a single
  drag consistent.
- **App-tier compile (no local Swift).** macOS CI is the gate; watch the `@MainActor`
  isolation trap on the new callback.
