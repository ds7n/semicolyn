# Glymr

iOS SSH/mosh client. Differentiator: terminal work that feels native on a touch device — context-aware key bar, smart snippet launcher, tmux control mode as the session engine for persistent, native tabs and panes, security-first credential handling.

> The name **Glymr** is Old Norse for *"echo, resonance, ringing sound"* — what the predictor does (echoes your vocabulary back) and what a remote command does (rings across distance to another shell).

## Status

**Phase:** Brainstorming. No code yet.

**Locked so far:**
- Concept, product positioning, security posture
- Connection scope (SSH + mosh + jump hosts + port forwards + Tailscale)
- Session engine: tmux control mode (`tmux -CC`)
- Credential storage: native iOS Keychain / Secure Enclave only — no 3rd-party password-manager integration
- Snippet model (flat list, smart sort, parameterized)
- **Window switching:** pill in keybar + four gestures (tap/swipe/long-press picker), terminal-area swipe as secondary path
- **Pane management:** second pill in keybar + four gestures, terminal area kept clear for iOS-native text selection
- **Copy/paste:** iOS-native (long-press in pane → magnifier → copy menu), per-pane selection
- **Cursor placement:** 60pt halo around the cursor, delta-based mouse-like drag (no joystick), loupe above cursor, vertical dead-zone to protect against shell-history surprise
- **Connection status:** transient banner from the top of the screen, only when something is wrong (Blink-style); amber for degraded, red for broken
- **Predictive input:** on-device learning vocabulary backed by probabilistic data structures (CMS + Bloom); thin auto-hiding suggestion row above the keybar; bundled seed (carapace + tldr + curated dotfiles) that defers per-prefix as the user gains signal. Full spec: `docs/superpowers/specs/2026-06-13-predictor-design.md`
- **Brand palette:** "Bell bronze" — bronze accent on cool-dark, with verdigris patina as a secondary color. Sidesteps AI/terminal/Norse stereotypes. See `mockups/ux-directions.html` (#brand section) for swatches and applied examples.
- **Keybar scope (v1):** in-app accessory bar above iOS's native keyboard. iOS owns the letters; the keybar carries window/pane pills + iOS-absent keys (Esc, Tab, Ctrl/Alt/Shift, arrows) + convenience defaults. Custom inputView with long-press alts on letter keys deferred as a potential v2.
- **Keybar interaction model:** three actions per slot (tap = primary, swipe-up = secondary, swipe-down = tertiary), long-press = edit. Dim swipe chars rendered on the same key. Ctrl/Alt/Shift sticky-for-one-keystroke; Esc/Tab fire on tap. Arrow keys collapsed into a single Blink-style drag-from-center pad.
- **Keybar default slots (v0 draft):** 10 slots — Esc · Ctrl/Alt/Shift · Tab · arrow-pad · `/` · `\|` · `~` · `-` · `(` · `)`. Tagged core vs convenience; convenience slots are removable. Full spec: `mockups/keybar-v1.html`. Expect telemetry-driven revision in v1.5.
- **Macros / snippets unification:** keybar items and launcher snippets are one concept — "a recorded sequence of input events" (a keystroke chord, a typed string, or a mix). Launcher is the searchable full list; keybar is the user's pinned subset. Placeholders are an optional per-item property.

**Unresolved / needs more brainstorm:**
- **Keyboard / input UX (remaining)** — function keys, per-context layout swaps, raw passthrough mode, custom inputView (v2) and its letter-to-alt mapping
- Pill position customization, host switching, iPad navigation, context detection, layout templates, iCloud sync, external keyboard, monetization

See `docs/brainstorming-decisions.md` for the full locked-decisions table and the deferred list.

## Layout

- `docs/brainstorming-decisions.md` — every locked decision, organized by topic; deferred items at the bottom
- `docs/superpowers/specs/` — detailed subsystem specs (start: `2026-06-13-predictor-design.md`)
- `mockups/ux-directions.html` — locked UX directions: window switching, pane management, cursor placement, connection status banner, brand palette
- `mockups/keybar-scope.html` — three options for the keyboard scope decision (accessory bar / custom inputView / hybrid)
- `mockups/keybar-v1.html` — v0 draft of the keybar default slot layout, with rendered iPhone frame and rationale
- `README.md` — this file

## Resuming next session

1. Open the mockup files in a browser for the visual record
2. Skim `docs/brainstorming-decisions.md` "Locked decisions" to recall state
3. Pick a topic from "Deferred / for future conversation"; remaining keyboard/input UX threads (function keys, per-context layouts, raw passthrough) or context detection are natural next
