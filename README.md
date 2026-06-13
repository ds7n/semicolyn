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

**Unresolved / needs more brainstorm:**
- **Keyboard / input UX** — predictor portion locked; remaining areas still open (accessory bar contents, modifiers, symbols, function keys, customization, per-context layouts)
- Pill position customization, host switching, iPad navigation, context detection, layout templates, iCloud sync, external keyboard, monetization, final name

See `docs/brainstorming-decisions.md` for the full locked-decisions table and the deferred list.

## Layout

- `docs/brainstorming-decisions.md` — every locked decision, organized by topic; deferred items at the bottom
- `docs/superpowers/specs/` — detailed subsystem specs (start: `2026-06-13-predictor-design.md`)
- `mockups/index.html` — visual mockups of UX decisions (open in browser); annotated with gesture overlays. Sections: window switching, pane management, cursor placement, connection status banner
- `README.md` — this file

## Resuming next session

1. Open `mockups/index.html` in a browser for the visual record
2. Skim `docs/brainstorming-decisions.md` "Locked decisions" to recall state
3. Pick a topic from "Deferred / for future conversation"; remaining keyboard/input UX areas (accessory bar contents, modifiers, symbols) are the natural next thread now that cursor and predictor are locked
