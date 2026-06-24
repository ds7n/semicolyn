# Multi-connection switching — design

**Status:** locked
**Date:** 2026-06-15
**Related specs:** host-config-model (2026-06-15), host-crud (2026-06-15), identities-keys-management (2026-06-15), degraded-mode (2026-06-14), context-detection (2026-06-14)

## Summary

Neotilde supports multiple simultaneous live connections. This spec defines the runtime semantics: what happens to background connections, how iOS backgrounding affects them, when the client gives up and demotes a connection, how resume works for each protocol, and what the user sees in the picker and the connection-status banner across hosts.

The host management UI (long-press Esc picker, swipe actions, Live / Recent grouping) is already locked in the `host management & settings access` decisions. This spec defines the *under-the-hood behavior* that those UI states reflect.

## Scope

In scope:
- Connection lifecycle states and transitions
- App foreground / background / cold launch behavior
- Soft cap and memory-pressure demotion
- Mosh and SSH resume mechanics
- Picker visual treatment for awake vs sleeping
- Connection-status banner under multiple connections
- Disconnect-swipe semantics
- Auth-policy interaction on wake
- Recent group cap and ordering

Out of scope (deferred):
- "Notify on command done" — opt-in per-command completion signal; v1.5+
- Live Activities (Dynamic Island background presence) — designed to be additive later
- iPad-specific multi-connection chrome
- Importing / exporting `~/.ssh/config` (separate deferred topic)

## Posture clarification — security framing

The strong security story is **storage**, not per-use friction. Identities live in iCloud Keychain (E2EE-synced) or the Secure Enclave (hardware-bound). The user-facing gate is the **device unlock**. App-level Face ID is an **opt-in extra layer**, off by default — see `2026-06-16-settings-sub-screens-design.md`. Once the app is open, identities with `afterUnlock` or `never` auth policies are usable silently, including during reconnects after backgrounding. The `anyUse` policy is an **opt-in escape hatch** for users who deliberately want per-operation biometric friction on specific high-value identities — it is the only path that surfaces prompts on connection wake.

## State model

Every connection Neotilde is aware of lives in exactly one of four states.

| State | Picker placement | Client resources held | User action to use it |
|---|---|---|---|
| **Active** | Highlighted in Live group | Full: terminal rendering, input pipeline, tmux control-mode client attached, mosh client decoding frames | Already in use — this is the foreground session |
| **Live · Awake** | Live group, solid row, green dot | Sockets open; mosh client receiving frames; tmux client attached but pane rendering suspended | Tap = switch to foreground, instant |
| **Live · Sleeping** | Live group, dimmed row (lower opacity) + `zZ` glyph | Minimal: identity refs, last-known mosh resume token, tmux session id. No sockets open. | Tap = wake (may auth, may reconnect, may demote to Recent on failure) |
| **Recent** | Recent group, muted dot | No live state. Config record + last-disconnected timestamp. | Tap = full connection establishment (acts like + Connect for that host) |

### Transitions

- **Active ↔ Live·Awake** — flip on foreground switch. No cost beyond UI focus change.
- **Live·Awake → Live·Sleeping**:
  - App backgrounded past iOS background-task budget → SSH connections demote (TCP sockets get torn down by iOS suspension). Mosh connections remain conceptually Awake because the server holds them.
  - Soft cap reached (default cap = 8 live connections) → least-recently-foregrounded connection silently demotes to Sleeping.
  - Memory-pressure warning from iOS → LRU Live·Awake connections demote to Sleeping until pressure clears.
- **Live·Awake → Recent** — explicit Disconnect swipe (covers both protocols).
- **Live·Sleeping → Active** — wake attempt succeeds (becomes Active on user tap).
- **Live·Sleeping → Recent** — wake attempt fails (full failure, including mosh resume + fresh-bootstrap fallback failing, SSH reconnect failing, host unreachable, auth no longer accepted, tmux server gone on the host) → row drops to Recent with the standard amber/red banner explaining why.
- **Recent → Active** — user tap on a Recent row or "+ Connect to host" → full handshake, auth, session bootstrap. Same code path as first-time connect.

The defining distinction is: **Awake = "client still has resources for it"** (sockets open, or for mosh, frames still streaming). **Sleeping = "we've released client resources; we trust we can resume."**

## App lifecycle behavior

### Foreground → background

When the app moves to background, Neotilde calls `UIApplication.beginBackgroundTask` to receive iOS's standard background-execution window (~30s, OS-dependent). We do **not** attempt to use that window for special heroics; this is the same facility every iOS app gets, used here just so the app's own bookkeeping (state save, pending sync writes) completes cleanly.

During the background-task window:
- All sockets remain technically open. The user could foreground within a few seconds and find everything as they left it.
- No proactive demotion. We don't pre-emptively close anything.

When the background-task window expires (iOS suspends the app):
- SSH connections: TCP sockets are torn down by iOS suspension. Server-side tmux sessions remain alive (tmux persists across SSH disconnects by design). Neotilde remembers the tmux session id for later reattach.
- Mosh connections: the iOS-side mosh client is suspended. The mosh server on the host continues running; the session remains valid until the server's own inactivity timeout (`MOSH_SERVER_NETWORK_TMOUT`, often unbounded by default).

### Background → foreground

When the app comes back to foreground:

1. **Foreground connection** (the one the user was last looking at) is reattached eagerly:
   - Mosh: resume from token. If the server still holds the session, frames resume; otherwise fall through to fresh-bootstrap (see Resume mechanics).
   - SSH: open a fresh SSH connection, then `tmux attach -t <session-id>` to reattach to the same tmux session. Layout and scrollback are preserved by tmux server-side.
2. **All other live connections** sit in Live·Sleeping in the picker. They are not eagerly reconnected. They wake on user tap only.

This rule is the same regardless of how long the app was backgrounded (5 seconds or 5 hours). The user's expectation "the thing I was looking at is still there" is honored at maximum effort; other connections honor "we'll resume when you ask."

### Cold app launch

When the app launches fresh (after force-quit, OS reboot, or first install of the session):

1. Live state for SSH connections is **not** persisted across cold launch. SSH+tmux sessions from the prior run are placed in Recent, sorted by recency. The server-side tmux session may still be alive on the host, but the client has lost the SSH transport state needed to silently reattach; resuming will go through a fresh connect path.
2. Live state for mosh connections **is** persisted across cold launch as Sleeping. The resume token is durable; on wake, we try resume-then-bootstrap (same path as a sleeping mosh from any other cause).
3. The last-foregrounded mosh connection is **auto-resumed** on cold launch, putting the user back in the same terminal they last had open. If the auto-resume fails (server gone, network gone), the picker opens with the failed row showing the standard red dot.
4. SSH-only last-host is **never** auto-resumed on cold launch — it would be a fresh handshake, which we don't perform without user intent.

### Soft cap

The design target is 4–8 simultaneous live connections, optimized for the 1–3 common case. The soft cap applies to **simultaneously Awake** connections — those holding client sockets / receiving frames. The cap is **8 Awake** (Active is one of them). Connecting a 9th host silently demotes the least-recently-foregrounded existing Live·Awake connection to Live·Sleeping, freeing socket budget for the new one. The user sees the `zZ` glyph appear on that row but receives no nag, no prompt, no warning. The demoted connection can be woken at any time with a tap (subject to the standard resume mechanics).

Live·Sleeping connections do **not** count against the cap; they hold no sockets. There is no hard limit on Live·Sleeping count beyond the Recent group's eventual visibility cap.

This behavior is *not* exposed as a tunable setting in v1. The cap is a design constant.

### Memory-pressure handling

On iOS memory-warning (`didReceiveMemoryWarning` or equivalent), Neotilde demotes Live·Awake connections to Live·Sleeping in LRU order (least-recently-foregrounded first) until system pressure is relieved. Active and any connection foregrounded in the last ~10 seconds are protected from this sweep. No user-visible chrome appears during the sweep beyond the affected rows showing the `zZ` glyph next time the picker is opened.

## Resume mechanics

### Mosh resume

When waking a sleeping mosh connection:

1. Attempt to resume from the cached mosh-server endpoint + key. If the server still holds the session, frames resume and the row transitions Sleeping → Active. This is the cheap, common path.
2. If resume fails (server-side timeout fired, server rebooted, port mapping changed), fall through transparently to a fresh mosh bootstrap: SSH to the host, run `mosh-server new`, capture the new key + port, switch the mosh client to it. The user sees one "waking…" indicator that resolves to Active — they are not informed *which* path succeeded.
3. If the fresh bootstrap also fails, the row demotes to Recent and the standard amber/red banner explains the failure. The user can tap the Recent row to retry, which becomes a clean + Connect flow. Failure messages are specific where possible: **"`mosh-server` not found on host"** when the SSH-side bootstrap shell can't locate the binary (a common mosh-newbie surprise that deserves a tailored line rather than "host unreachable"), **"Authentication changed"** when SSH re-auth is now refused, and the generic "Host unreachable" otherwise.

### Mosh + Tailscale interaction

When the host is reached via Tailscale (`tailscale.required = true` in the host config, or simply a `100.64.x.x` / MagicDNS hostname), mosh's UDP roaming continues to work because Tailscale's userspace networking re-routes packets across the iOS network change transparently — from the mosh server's view, the source endpoint remains the Tailscale-assigned address regardless of which underlying physical interface (WiFi → cellular, etc.) the iOS device is on.

Two cases where this falls apart and the connection drops to Recent with the standard amber/red banner:

- **Tailscale itself goes down on the device** (user signed out, exit-node lost, app revoked Network Extension permission). The 100.64 address is no longer routable; mosh has no path to the host. Banner says "Tailscale unreachable" per the existing `tailscale.required` framing.
- **iOS suspends Tailscale's Network Extension long enough that its session lapses** (rare; the NEPacketTunnelProvider runs in its own process and is fairly resilient). Mosh appears to be roaming but actually has no underlying transport. The standard mosh resume → bootstrap → drop path handles this; the failure surfaces as "host unreachable."

In the happy path the user experience is the same as roaming over public internet: the mosh session resumes, the screen catches up, no special UX.

### SSH + tmux resume

When waking a sleeping SSH connection:

1. Open a fresh SSH connection using the stored identity.
2. Run `tmux attach -t <session-id>` to reattach to the same tmux server-side session.
3. If the SSH connect succeeds but the tmux attach fails (session id no longer exists — tmux was killed, host rebooted with no session restore), the row demotes to Recent with a red banner ("tmux session gone"). The user can tap Recent to start a fresh tmux on the same host.
4. If SSH itself fails, demote to Recent with the standard auth/unreachable banner.

This matches the locked degraded-mode behavior: a mid-session tmux loss surfaces clearly rather than being silently papered over.

## Picker visual treatment

(Mockup: `mockups/drafts/multi-connection-banner.html` — focused on the banner question, but the picker treatment shown there is the locked treatment for this spec.)

- **Live group** — one header "Live"; both Awake and Sleeping rows live under it.
  - Awake rows: solid opacity, green health dot.
  - Sleeping rows: lower opacity (~60%), small `zZ` glyph after the host name, plus the colored dot reflecting last-known health.
  - Active row (the foreground session): highlighted with bronze tint background.
- **Recent group** — second header "Recent"; muted-grey dot; cap = **10 entries**, sorted by last-disconnected (most recent first). Overflow surfaces a single tappable "See all hosts" row that pushes to Settings → Hosts.
- **+ Connect to host…** and **⚙ Settings** rows close the sheet, as locked.

Per-row swipes (already locked in host management):
- Live row: `[Edit] [Disconnect]`. Disconnect closes the session client-side and moves the row to Recent.
- Recent row: `[Edit] [Delete]` (Delete confirms).

### Activity indicators

No "new output since last viewed" activity dot on Live rows. Dots carry **connection-health semantics only** (green = healthy, amber = degraded, red = broken, muted = inactive/Recent). Per-host activity awareness is not a v1 problem; the window-switching activity badge is intentionally a per-session affordance, not a per-host one. A "notify on command done" affordance is deferred to v1.5+.

## Connection-status banner under multiple connections

The locked banner rule is preserved: **transient banner at top of screen, only when something is wrong with the foreground session, slides in / out as state changes.** Background-connection trouble does **not** raise the foreground banner.

Background-connection health surfaces only through the **picker row dot**: amber on a Live·Sleeping or Live·Awake row indicates degraded health on that connection; red indicates broken / about-to-demote-to-Recent. The picker is the user's natural surface for "what's everything doing right now" — they open it when they want to switch *or* adjust, so it does double duty.

If the user switches to a connection whose row was amber/red, the foreground banner appears immediately on switch, reflecting that session's state, per the standard locked banner rule.

## Disconnect semantics

The per-row `Disconnect` swipe action (Live rows) performs a **client-only abandon**:
- Mosh: the client stops processing the resume token; the mosh server on the host is **not** explicitly killed. It will time out naturally on its own schedule. Within that window, reconnecting from Recent will resume the same server-side session (a happy surprise for the "I disconnected by mistake" case).
- SSH+tmux: the SSH connection is closed cleanly; the tmux server-side session is **not** killed. Reconnecting from Recent within the lifetime of the tmux server will reattach to the same session (preserved layout, scrollback).

If the user wants definitive server-side cleanup, they can run `exit` (or `tmux kill-session`, or `mosh-server` PID kill) inside the shell before Disconnect. This is not exposed as a UI action in v1.

## Auth-policy interaction on wake

Identity auth policies (locked in host-config-model): `never` / `afterUnlock` / `anyUse`.

- **`never`** — no biometric prompt at any point. Wake is silent.
- **`afterUnlock`** — biometric once per app-unlock window. If the app is currently unlocked, wake is silent. If not, the app-unlock biometric runs first (same as launching the app), then wake proceeds silently.
- **`anyUse`** — biometric on every key use. Wake **does** trigger a Face ID prompt, because reconnecting consumes the identity. The prompt's context message is "Wake connection to <host>". User cancellation falls through to demotion to Recent (no row left in an indeterminate state).

For users on the default `afterUnlock` policy (expected to be the vast majority), wake is a silent operation. The `anyUse` prompt-on-wake is the price paid by users who explicitly opted into that friction.

## Open / deferred items

- **"Notify on command done" affordance** — explicit per-command completion notification for long-running commands; designed separately, v1.5+.
- **Live Activities** for Dynamic Island background presence — out of scope for v1; the per-connection state model is designed so an Activity could feed off it later (especially for backgrounded mosh that's still receiving notable events).
- **Per-host overrides for cap behavior** — pinning a connection so it can never be LRU-demoted is an interesting power-user request; defer until/unless real usage shows the soft cap biting users.
- **Cross-host snippet / launcher state** — out of scope here; the launcher does not currently expose per-host history. When it does, the question of whether sleeping connections contribute to it will need its own decision.
- ~~**Audit log entries for state transitions**~~ — audit log dropped from v1 in `2026-06-16-icloud-sync-scope-design.md`. No schema needed. The code-level stub for a future Pro audit log would emit lifecycle events as no-op hooks in v1.

## Acceptance summary

The user experience this spec defines:

- Up to ~8 simultaneous live connections, transparently managed.
- Switching between connections is instant for the awake set; sleeping connections wake on tap with a brief loading state.
- Foreground experience is unchanged across multi-connection: the banner still reflects only what the user is looking at.
- Mosh genuinely roams across iOS backgrounding and even cold app launch — the user can quit Neotilde, come back hours later, and find their mosh session right where it was.
- SSH is honest about its limitations: it degrades on background past iOS's budget, reconnects on foreground for the active session, and offers fast tmux-session reattach for the rest.
- The picker is the cross-host awareness surface; the banner is the active-session surface; the two never collide.
