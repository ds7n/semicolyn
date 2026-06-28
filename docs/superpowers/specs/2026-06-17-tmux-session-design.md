# tmux session naming + multi-device policy

**Date:** 2026-06-17
**Status:** Locked
**Resolves:** punch-list item #6 in `docs/final-review-punchlist.md`.

## Goal

Define how Semicolyn names its tmux sessions and what happens when the same user signs into the same Unix account on the same host from multiple iCloud-paired iOS devices.

## Naming

Sessions are named `semicolyn-<accountHash>` where `accountHash` is a stable 8-character lowercase hex derived from the user's iCloud account identity.

**Derivation.**
`accountHash = first 8 chars of SHA-256(iCloud-account-bound key from CloudKit private DB)`. The source value is the same 32-byte key that backs the CloudKit-stored host record encryption (per [[2026-06-15-host-config-model-design]]'s storage backbone). It exists on every signed-in device; it's stable across re-logins to the same Apple ID; rotating it would already require a host-config re-keying event.

**Properties.**
- Stable across reboots, reinstalls, and OS upgrades — the underlying key is iCloud-Keychain-persisted.
- Same on every device signed into the same Apple ID.
- Different when the user signs out and signs in with a different Apple ID.
- Truncated to 8 chars: collision probability with another `semicolyn-*` session on the same Unix user is negligible in practice (8 hex = 2^32 space; you'd need ~65k other Semicolyn users sharing this Unix account to hit a 50% birthday-paradox collision).

**Examples.** `semicolyn-a3f7c2e9`, `semicolyn-1b4d8201`. The prefix `semicolyn-` makes the session obviously Semicolyn-owned for anyone inspecting `tmux ls` server-side.

## Default behavior: shared session per Apple ID

When the user connects to a host from device A and the session `semicolyn-<accountHash>` does not exist server-side, Semicolyn creates it via `tmux new-session -d -s semicolyn-<accountHash>` and attaches via control mode.

When the user later connects from device B (same Apple ID), Semicolyn sees the session exists and attaches via `tmux -CC attach-session -t semicolyn-<accountHash>`. **Both clients are now attached to the same session.**

This is exactly what tmux is designed for. Cross-device continuity is the point.

**Behavior with two devices attached:**
- Keystrokes from either device land in the active pane.
- Screen updates mirror to both devices.
- Window / pane creation by either device shows up on the other in real time.
- Both devices see the same tmux state machine (active window, active pane, layout).
- If one device backgrounds and the iOS bg-grace expires, that device's TCP drops. The server-side tmux session is unaffected; the still-connected device keeps using it. When the backgrounded device returns, it re-attaches.

**Multi-device works without any per-device toggling.** The user doesn't have to opt in.

## Picker entries vs tmux sessions

The Esc-pill picker entry maps to a (host, session) pair, not to a (host) alone. In the default case there's one entry per host because every connection targets the shared `semicolyn-<accountHash>` session.

When the user invokes "Connect in new session" (below), a *new picker entry* is created for the same host, targeting a one-off session. The picker now shows two rows for that host — labeled `<host-label>` and `<host-label> · alt 1`. Subsequent "Connect in new session" actions produce `· alt 2`, `· alt 3`, etc. The base entry (no "alt") is the shared session.

## Picker swipe actions

The Esc-pill picker's per-row swipe menu, established in [[2026-06-15-multi-connection-switching-design]], gains two new actions on Live rows (the existing **Edit** and **Disconnect** stay):

### Disconnect *(existing)*

Closes the client-side TCP / mosh transport. Server-side tmux session preserved. Reattach is fast — control mode reconnects in well under a second on a healthy network.

### Disconnect & end session *(new)*

Confirms via iOS action sheet:

> **End session on `<host>`?**
> Closes Semicolyn's connection AND kills the tmux session server-side.
> Any windows, panes, and running processes inside the session are terminated.
>
> [ End session ] ← red
> [ Cancel ]

On confirm, Semicolyn runs `tmux kill-session -t semicolyn-<accountHash>` (or the alt-N variant for non-default sessions) before closing the transport. If the user has other devices currently attached to the same session, they're booted with a banner: *"Session ended from another device."*

### Connect in new session *(new)*

For the rare case where the user wants isolation from the existing shared session — e.g., to spawn a quick scratch session without polluting the persistent one.

On invoke, Semicolyn opens a new connection to the same host using a one-off session name: `semicolyn-<accountHash>-<short-uuid>` where `<short-uuid>` is a 4-character hex tag. A new picker entry appears labeled `<host-label> · alt N`. The new session is independent: no cross-device sharing with the default session, no cross-device sharing with other alt sessions.

Available via the swipe menu on *any* row for that host (Live or Recent). Also available from the "+ Connect…" path: a long-press on the host in the connect picker reveals a "Connect in new session" alternative. Tap is the default behavior (shared session).

## Edge cases

- **Stale alt sessions.** A one-off session left behind by an old "Connect in new session" stays on the server until the user explicitly ends it or restarts the Unix tmux server. v1 surfaces it as a separate picker entry (no special UI for cleanup). Worst case a heavy user accumulates a few `· alt N` rows over time. **No automatic GC in v1.** v1.5+ candidate.
- **Concurrent first-connect from two devices.** Device A and device B both try to create `semicolyn-<accountHash>` simultaneously. tmux's `new-session -d` is atomic; the second one will see the session already exists and attach instead. No race condition surface beyond "second device picks up an empty fresh session."
- **Apple ID change while session exists.** The user signs out of Apple ID and signs in with a different one. `accountHash` changes. The old session stays orphaned on the host until the user explicitly cleans it up (would require connecting under the old Apple ID, or manually `tmux kill-session` via raw SSH). Acceptable; documented in Tips & Gestures.
- **Host doesn't have tmux** (raw-PTY mode per [[2026-06-14-degraded-mode-design]]). This whole spec doesn't apply — raw PTY has no session abstraction. Each device's connection is independent.
- **User has `tmux` set up with a custom `default-shell`, hook scripts, or other `.tmux.conf` config.** Semicolyn respects it — `tmux new-session -d -s <name>` invokes the user's config normally. No override.

## What this is *not*

- **Not a way to share between two different Apple IDs.** Different IDs → different `accountHash` → different sessions. There's no "share with another user" feature.
- **Not a session manager.** Semicolyn doesn't list all tmux sessions on the host; it only knows about the ones it created (encoded in the picker entries). A user who wants to attach to a hand-created session uses `tmux attach -t othername` from raw SSH, not Semicolyn.
- **Not per-host configurable.** The naming convention is the same on every host. v1 doesn't expose a "session-name override" per host config.

## Cross-spec consequences

- [[2026-06-15-multi-connection-switching-design]] — picker swipe-action set expands from `[Edit] [Disconnect]` to `[Edit] [Disconnect] [Disconnect & end session]` on Live rows. The long-form "Connect in new session" action lives in the same swipe menu's overflow. Picker rows may now show `· alt N` suffixes.
- [[2026-06-14-degraded-mode-design]] — explicitly notes that raw-PTY mode doesn't participate in this spec.
- [[2026-06-15-host-config-model-design]] — no schema change. Session naming is runtime-only.
- [[2026-06-16-first-host-onboarding-design]] — Tips & Gestures gets one new sentence: *"When you're signed into the same Apple ID, Semicolyn shares one tmux session per host across your iPhone and iPad. Start vim on iPad, switch to iPhone, keep typing."*

## Related

- [[2026-06-15-multi-connection-switching-design]]
- [[2026-06-14-degraded-mode-design]]
- [[2026-06-15-host-config-model-design]]
- [[2026-06-16-first-host-onboarding-design]]
