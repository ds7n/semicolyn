# Degraded mode & tmux requirements

**Status:** Locked — 2026-06-14
**Supersedes:** "Raw passthrough mode" item in deferred list

## Summary

Semicolyn's headline features (window/pane pills, context detection, function-key auto-engage) ride on tmux control mode (`tmux -CC`). When tmux is missing, too old, or crashes mid-session, the app must keep working — as a competent plain SSH client — without pretending the lost features are still there. This spec defines the minimum tmux version, the degraded-mode behavior matrix, the connect-time UX, and the mid-session crash recovery flow.

This is **not** a "raw passthrough" feature for power users. There is no setting labeled "raw mode," no toggle to opt into a stripped-down experience for taste. Degraded mode is a fallback the app enters automatically when tmux isn't available, and the user can choose to make that fallback quieter on a per-host basis.

## Non-goals

- **No auto-install / bootstrap of tmux.** Semicolyn never drops binaries on a user's host, never runs package managers, never sudoes. If tmux isn't there, we degrade.
- **No partial-tmux support.** Either the host has tmux ≥ 3.0 and we use control mode, or we use raw PTY. We do not maintain a feature-by-version matrix below 3.0.
- **No state restoration after tmux crashes.** We do not try to recreate window/pane layouts from memory after a crash. The shells and their state are gone; pretending otherwise is worse than honest loss.
- **No power-user "raw" toggle.** Users who want raw SSH access have other clients (Blink, Termius, Prompt 3). Semicolyn's product story is tmux-native.

## Minimum tmux version: 3.0

Locked at **tmux 3.0** (released 2019).

Rationale:
- 3.0 is the natural "modern tmux" cutoff. Every actively-maintained distro since ~2020 ships ≥3.0 (Ubuntu 20.04+, Debian 11+, RHEL/Alma 9+, Alpine 3.12+, current Homebrew).
- Control-mode protocol and `display-message -p` formatting we depend on stabilize at 2.9; we round up to 3.0 to dodge per-point-release bugs.
- A box stuck on tmux 2.x is almost certainly frozen on other dimensions too — degraded mode is the right answer, not a compatibility shim.

### Detection at connect time

| Host state | Action | Banner |
|---|---|---|
| tmux ≥ 3.0 | Start `tmux -CC` normally | None |
| tmux < 3.0 | Skip `-CC`, raw PTY | Amber, transient: "tmux 2.x detected — needs 3.0+ for full features; running as plain SSH" |
| tmux not installed | Skip `-CC`, raw PTY | Amber, transient: "tmux not found — running as plain SSH" |
| Per-host "skip tmux check" enabled | Skip `-CC`, raw PTY | None |

Detection is a single `tmux -V` invocation in the SSH session before deciding whether to spawn `-CC`. Cheap, one round trip.

## Degraded-mode behavior matrix

When we cannot or do not start `tmux -CC`, the app runs against a raw PTY. The following matrix is the contract for what works in each mode:

| Feature | Normal (`-CC`) | Degraded (raw PTY) |
|---|---|---|
| Connection (SSH/mosh/jump host/Tailscale/port forwards) | ✅ | ✅ |
| Single shell session | ✅ | ✅ |
| Window pill (switch / list / create) | ✅ | ❌ hidden |
| Pane pill (split / nav / zoom / close) | ✅ | ❌ hidden |
| Context detection (vim / python / psql / etc. promotions) | ✅ | ❌ off |
| Function-key auto-engage (htop / top / mc) | ✅ | ❌ off |
| Function-key manual mode (Fn slot toggle) | ✅ | ✅ |
| Keybar locked-left (arrow-pad, Esc) | ✅ | ✅ (collapsed left) |
| Keybar scroll region (Ctrl/Alt/Shift, Tab, defaults, Fn) | ✅ | ✅ |
| Predictor (suggestions + on-device learning) | ✅ | ✅ |
| Snippets / launcher | ✅ | ✅ |
| iOS-native copy/paste | ✅ | ✅ |
| Cursor placement (halo + loupe drag) | ✅ | ✅ |
| Connection status banner | ✅ | ✅ |
| Mosh resume / persistence | ✅ | ✅ (mosh only) |
| Session survives app backgrounding | ✅ via mosh+tmux | ⚠️ mosh only — single shell, no multi-window restore |

### Keybar layout in degraded mode

The locked-left section is normally `[win pill][pane pill][arrow-pad][Esc]`. In degraded mode, both pills are removed and the remaining elements **collapse left** — arrow-pad and Esc shift into the vacated space and the scroll region gets more room. Empty placeholders look broken; promoting a different element into that slot would introduce a third layout state to design and explain.

### Edge case: detached tmux already on the host

If a user connects to a host where they already have a detached tmux session and we are in degraded mode (e.g., they suppressed the tmux check for this host), we drop them at the raw shell. We do not auto-attach. The user can run `tmux attach` themselves and live in tmux's native UI; we are not in the loop.

## Connect-time UX

When degraded mode is entered at connect:

- **Banner:** the existing top-of-screen transient banner (Blink-style, amber for degraded), auto-dismissing after the standard ~3s.
- **Reoccurs on every reconnect** to the same host. Each session is a fresh "this host is degraded" event.
- **No persistent indicator anywhere else in the chrome.** The absence of the window/pane pills in the keybar is the strongest possible signal — adding a badge, accent color shift, or status dot is redundant clutter.

### Per-host suppression

A user with a fixed set of hosts they know don't run tmux should not be nagged forever. Two affordances:

- **Auto-offer suppression:** after the banner has fired and been dismissed 2–3 times for the same host, the next banner adds a one-tap **"Suppress for this host"** action. No upfront settings menu needed.
- **Manual override in host config:** a per-host **"Don't attempt tmux on this host"** option that skips the version-check round trip entirely and goes straight to raw PTY. For users who know the answer ahead of time. Shipped in v1 as `semicolyn.tmux.attemptControlMode` per [[2026-06-15-host-config-model-design]]; exposed in the host-CRUD "Semicolyn behavior" section per [[2026-06-15-host-crud-design]].

Suppression is always **per-host**. A global "never warn me about tmux" toggle is a footgun — disable it once, six months later you're confused why a new host doesn't show pills. Per-host matches the actual mental model: "I know *this box* doesn't have tmux."

## Mid-session tmux crash recovery

Rare but real: tmux can die mid-session (OOM kill, `tmux kill-server` from elsewhere, segfault). The user is mid-task, the SSH/mosh transport is still alive, the shells inside tmux are gone.

### Detection

The control-mode channel closes unexpectedly (EOF on `-CC` stream) while the underlying SSH/mosh connection remains healthy.

### Recovery flow

1. **Drop to degraded mode immediately** on the same connection. No re-auth, no reprompt. Pills disappear, scroll region collapses left, user gets a fresh raw shell on the same host. This is variant **C** of "where do we send them": auto-drop to keep them moving, with explicit recovery affordances visible.
2. **Show the crash banner** — red, top of screen. **This is the one banner that does NOT auto-dismiss.** It persists until the user dismisses it or chooses an action. Every other banner in the app is transient; this is the documented exception, called out so the banner pattern stays consistent everywhere else.
3. **Banner content:** "tmux session ended — your shell is still running." Plus action buttons:
   - **Reattach** — runs `tmux attach`. Useful if the server-side session somehow survived (e.g., a client was killed but the server is still up). Rare but cheap to offer.
   - **Start new tmux** — runs `tmux -CC new-session`. Fresh slate, back in normal mode.
   - **Dismiss** — stay in degraded mode for the rest of this connection.

### What we explicitly do NOT do

- **No auto-retry of `-CC`.** If tmux just crashed, the input that killed it may still be in the buffer; banging on it immediately risks a crash loop. Recovery is manual only.
- **No layout restoration.** We do not try to recreate the old window/pane layout in a fresh tmux session. The *contents* (scrollback, running processes, env state) are gone; recreating empty shells in the old layout implies a recovery that didn't happen and is worse than honest loss.
- **No "your work is safe" reassurance.** Anything running inside the crashed tmux is gone. mosh+tmux normally protects against connection loss; tmux dying is the one failure mode neither layer covers. We do not pretend otherwise.

## Related decisions

- [[2026-06-14-context-detection-design]] — context promotions depend on `pane_current_command` via `-CC` notifications; off in degraded mode.
- [[2026-06-14-function-keys-design]] — auto-engage in `htop`/`top`/`mc` uses context detection and is therefore off in degraded mode; manual Fn-slot toggle is input-layer and still works.
- Host config model — owns the per-host `semicolyn.tmux.attemptControlMode` field and the suppression state for the connect-time banner.

## Open questions deferred to other specs

- Exact wording, color, and timing of the banners — to be tuned alongside the existing connection-status banner work in `mockups/specs/features.html` (transient banner) and `mockups/specs/banner-expanded-templates.html` (expanded view).
- Whether to surface a host-level indicator anywhere outside the keybar (e.g., a small "raw" badge on the host in a future host picker) — defer to the deferred **multi-connection / host switching** topic, which is where any host-list UI will be designed.
