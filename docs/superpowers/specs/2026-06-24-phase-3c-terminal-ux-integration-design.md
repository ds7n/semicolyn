# Phase 3 Plan C — terminal UX integration design

**Date:** 2026-06-24
**Status:** Locked
**Type:** Integration / scoping design. The *behavior* is already locked in three specs; this doc records the *how* (architecture, seams, testability) and the scoping decisions made during the Plan C brainstorm.

**Behavior specs (locked, unchanged):**
- [[2026-06-17-terminal-feedback-design]] — bell (visual halo + haptic; no audio ever).
- [[2026-06-17-terminal-ux-additions-design]] — font size + pinch-zoom, URL tap, cursor style/blink, scrollback, resize policy, port-forward status.
- [[2026-06-17-terminal-emulator-scope-design]] — TERM/truecolor, OSC 52 clipboard, OSC 0/2 titles, mouse-mode passthrough + indicator.

## Key insight

SwiftTerm's `Terminal` engine **already parses** every sequence Plan C cares about (DECSCUSR, mouse modes `?1000/1002/1003/1006/1015`, OSC 52, OSC 0/1/2, true-color, URL detection). The corresponding `TerminalViewDelegate` callbacks already exist in both `App/TerminalScreen.swift` and `App/TmuxPaneContainer.swift` — but are **stubbed to no-ops** today: `bell`, `clipboardCopy`, `requestOpenLink`, `setTerminalTitle`, `scrolled`.

Plan C is therefore overwhelmingly **implementing those callbacks** + adding a few overlays/gestures + a settings model — *not* writing escape-sequence parsers. The tmux path feeds the same per-pane `TerminalView`s, so the same delegate hooks fire for control-mode panes (subject to which signals tmux surfaces as `%`-notifications vs. raw `%output` — a per-feature verification at plan time).

## Scoping decisions (this brainstorm)

1. **Stay the course.** Build all Plan C functionality now, *assuming the consuming UI exists*. Do **not** build throwaway UI (no temporary Settings screen, no temporary Esc-pill picker) that would be reworked when the real surfaces land.
2. **Settings via a model seam with reasonable defaults.** A `TerminalSettings` value type holds the spec'd defaults; behaviors read from it. The future *App preferences → Terminal* screen simply binds to it — no UI in Plan C.
3. **Title + port-forward status as observable seams.** Captured into observable state with no visible surface; the Phase-4 Esc-pill picker Live row reads them when built.
4. **No re-sequencing of the keybar.** The full keybar (Fn layout engine, context-detection promotions, predictor strip, customization) stays Phase 4.

## Architecture — testability split

Mirror the project's established pattern (`tmuxLaunchDecision` pure + thin App wiring; App-target FFI/UIKit code is **macOS-CI-verified only**, invisible to Linux `swift test`).

- **Pure decision logic → `SemicolynKit` (Linux-tested, XCTest):** the settings model + clamps, OSC 52 write-gate, title sanitization, URL scheme classification + wrapped-URL join, the bell halo/haptic state machine (injected clock), resize debounce (injected clock), DECSCUSR→style mapping.
- **Thin SwiftTerm/UIKit wiring → `App/` (macOS CI only):** delegate-callback bodies, the halo overlay, the mouse-active dot, the pinch gesture, pasteboard writes, URL routing into existing views.

## Unit breakdown

| Unit | Home | Pure? | Role |
|---|---|---|---|
| `TerminalSettings` (defaults + clamps) | SemicolynKit | ✅ | font 13pt (clamp 9–24), cursor `.block`, blink off, raw-PTY scrollback 5000 (presets 1000/2000/5000/10000/∞) |
| Bell state machine | SemicolynKit | ✅ | hold-at-peak until ~400ms quiet → 250ms fade; haptic ≤1 per ~500ms; drives the halo overlay + `UIImpactFeedbackGenerator(.soft)` |
| OSC 52 write-gate | SemicolynKit | ✅ | given host `semicolyn.osc52.allow` + payload → write-to-pasteboard or drop; **read sequence always no-op** |
| Title sanitize | SemicolynKit | ✅ | reject empty/control-char titles; publish latest per window to the title seam |
| URL classify + wrapped-join | SemicolynKit | ✅ | scheme ∈ {http,https,ssh}; join across a row break only when part1 ends mid-token & part2 starts col 0 |
| Resize debounce (~10Hz) | SemicolynKit | ✅ | coalesce `sizeChanged` bursts (rotation/keyboard) before `session.resize` |
| DECSCUSR map + cursor default | App (SwiftTerm) | partial (map is pure) | configure caret style/blink from settings; engine applies `\x1b[<n> q` overrides |
| Mouse-active dot + gesture suspend | App | — | read SwiftTerm `mouseMode`; show 4pt bronze dot (`accent.primary` 40%); suspend Semicolyn long-press selection |
| Pinch-zoom font (per-window) | App | — | pinch → `TerminalView.font` resize w/ clamp; persists for window lifetime |
| Scrollback config | App | — | set SwiftTerm buffer from settings in raw-PTY mode; tmux owns its own |
| Title seam | App/SemicolynKit | — | observable per-window title (no UI) |
| Port-forward status seam | SemicolynKit seam | — | observable establish/fail per declared forward (no UI; **runtime forward path must be verified at plan time**) |

## State seams (no UI, per decision)

- **`TerminalSettings`** — observable, defaults baked in; future Settings screen binds to it.
- **Per-window title** + **per-forward status** — observable; the Phase-4 Esc-pill picker reads them. Nothing rendered now.

## Dependency flags

- **Cursor-placement halo isn't built.** The mouse-mode spec says a mouse-active pane suspends the cursor-placement halo — but that halo is a Semicolyn gesture not yet implemented. Plan C wires the mouse-active *state + bronze dot* and the long-press-selection suspension, and leaves a **seam** for halo-suspension to hook when the halo lands. Not a no-op cop-out: the dot and selection-suspend are real and shippable.
- **Port-forward runtime path.** The Rust forwarding (Phase 1e) exists, but whether the establish/fail status is observable from the app connect path must be verified before committing the status-seam unit. If wiring the establishment is heavy, the status seam may narrow to "declared forwards, status unknown" until Phase 4.
- **tmux signal surfacing.** Confirm per feature whether bell/title/OSC 52 arrive in `%output` (→ SwiftTerm parses) or as tmux control-mode `%`-notifications (→ handled in `ControlModeParser`/`TmuxRuntime`).

## Sequencing (PR slices)

Thin, independently-testable slices:

1. `TerminalSettings` model + cursor default + scrollback config.
2. Bell — halo overlay + haptic (state machine first, Linux-tested).
3. OSC 52 write-gate + title seam (+ host-model `semicolyn.osc52.allow` field).
4. URL tap — classify/join (Linux-tested) + routing.
5. Mouse-active dot + resize debounce.
6. Pinch-zoom font.

Port-forward status seam slots in after (1) if the runtime path checks out, else defers.

## Out of scope (v1) / follow-ups

- **Accessibility review** — app-wide a11y pass (VoiceOver for terminal + keybar, Dynamic Type vs. fixed cell font, contrast of low-opacity overlays + bronze border, Reduce Motion for bell pulse / cursor blink, haptic opt-out, tap-target minimums). Tracked as a future TODO; best run once terminal UX + keybar/Settings UI exist.
- **Per-host / per-pane font persistence** beyond window lifetime — v1.5+.
- **Cursor color** setting — `terminal.fg` is the color in v1.
- **Ad-hoc runtime port-forwards** — v1.5+; v1 surfaces only host-config-declared forwards.
- **Bracketed paste, OSC 8 hyperlinks, sixel/iTerm2/Kitty image protocols** — per the locked specs, out of v1.
- **Audio bell** — rejected with prejudice.

## Model change

- `Sources/SemicolynKit/Model/HostExtensions.swift` gains `semicolyn.osc52.allow: Bool? = true` in the `semicolyn.*` namespace (alongside `predictor.*` / `tmux.*`). The host-editor **"Semicolyn behavior"** section (already exists) gains the OSC 52 checkbox — the one piece of Plan C UI that has a real home today.
