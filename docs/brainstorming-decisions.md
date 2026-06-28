# Brainstorming Decisions

Running notes from the design brainstorm. Will fold into a formal spec when the windows/panes/cursor/host story is complete.

## Concept

iOS SSH/mosh client. **Reason to exist:** terminal work feels native on a touch device, especially around the iOS keyboard ergonomics that other clients fight against.

Two complementary input mechanisms central to the differentiation:

- **Context-aware key bar** — toolbar above keyboard morphs based on what's running (shell, vim, tmux, less). *Detection mechanism deferred.*
- **Snippet / macro launcher** — flat list, smart sort, parameterized commands with placeholders, defaults, and per-host remembered values.

---

## Locked decisions

### Product positioning

| Topic | Decision |
|---|---|
| Name | **semicolyn** — a respell of *semicolon* (`;`, the shell's command separator that chains one command into the next). Lowercase `semicolyn` in path / code contexts; capitalized `Semicolyn` only as the proper noun at sentence start. (Naming journey: Glymr → neotilde (2026-06-24, forced off the LIVE registered GLYMR trademark) → **semicolyn** (2026-06-28); see `docs/2026-06-28-naming-decision-semicolyn.md`.) |
| Goal | Solve a personal annoyance (CLI / AI / security adjacent) |
| Differentiator | Make the iOS keyboard pleasant for terminal work |
| Security posture | Security-first: SE-default for new identities, per-host auth policy, no telemetry, public-key always copyable. (Audit log dropped from v1 entirely per `2026-06-16-icloud-sync-scope-design.md`; code-level stub reserved for a future Pro compliance feature.) |
| Brand palette | **"Neon Midnight"** — coral accent `#FF6F5E` (the orange-red glow of neon) on darker blue-near-black `#07090E`, verdigris `#5FB0A2` as success/tension color, error `#E5455E`. Bell-only glow (accent solid at rest; anti-CP2077). Bell-bronze kept as a Pro-cosmetic alternate. See `mockups/specs/design-system.html` and `docs/superpowers/specs/2026-06-25-neon-midnight-theme-design.md`. |

### Connections & sessions

| Topic | Decision |
|---|---|
| Connection scope | SSH + mosh + jump hosts + port forwards + Tailscale-aware |
| Session engine | **tmux control mode (`tmux -CC`)** — like iTerm2. Persistent remote sessions; native tabs/panes in the app UI |
| tmux UX tiers | (1) Non-tmux user sees clean tabs/panes; tmux runs silently. (2) tmux user gets app-driven integration. (3) Purist can disable per-host. |
| Concurrency | Multiple windows + multiple panes, with tmux-style splits |

### Credentials & security

| Topic | Decision |
|---|---|
| Credential storage | **Native only** — iOS Keychain + Secure Enclave. **No 3rd-party password-manager integration.** Matches Blink / Termius / Prompt 3. |
| Security posture framing | **Storage is the security story, not per-use friction.** Keys live in iCloud Keychain (E2EE-synced) or Secure Enclave (hardware-bound). The user-facing gate is the **device unlock**. App-level Face ID is an **opt-in extra layer**, off by default — revised in `2026-06-16-settings-sub-screens-design.md` (Notes / Mail / Messages don't gate themselves on an unlocked phone; Semicolyn doesn't either by default). Per-use biometric (`anyUse`) remains the opt-in escape hatch for per-operation friction on specific high-value identities. (Original locked-decision in `2026-06-15-multi-connection-switching-design.md` said app-level Face ID was the default gate; that's superseded.) |

### Snippets / macros (unified)

| Topic | Decision |
|---|---|
| Unified concept | **One concept: macro = a recorded sequence of input events.** Covers keystroke chords (`Ctrl+R`), literal strings (`kubectl `), mixed sequences (`Esc :wq Enter`), and tmux prefix combos. No separate "snippet" vs "macro" distinction. |
| Two surfaces | **Launcher** = searchable full list (flat, smart sort, toggle to disable). **Keybar** = pinned subset for one-tap access. |
| Optional placeholders | Placeholders + defaults + remembered last-used values per host are an optional per-macro property. Used by some launcher entries; usually unset on keybar items. |

### Keybar (accessory bar above iOS keyboard)

> **Layout, customization, and gesture-ownership rules revised in `2026-06-15-keybar-customization-design.md`.** Default locked-left is now Esc pill · Pad · Modifier · Tab (fuses the previous Esc + Win pill, and arrow-pad + Pane pill, into two special widgets). Long-press = edit-slot shortcut removed; long-press is now a bindable gesture on custom slots. Almost every slot is reorderable / removable / movable across the locked-vs-scroll divider via Settings → Keybar. Reverse-bar (locked-right) toggle added.

| Topic | Decision |
|---|---|
| v1 scope | **In-app accessory bar only.** iOS owns the letter keys; the 123 layer remains the fallback for any symbol not promoted to the keybar. Semicolyn owns the predictor strip + keybar pills + slots. |
| v2 question (deferred) | Custom `inputView` (Semicolyn-owned keyboard inside the app) — enables long-press alts on letter keys, held modifier chords, custom repeat rates, context-swap layouts. Not a system-wide keyboard extension. |
| Slot interaction | Three actions per slot: tap = primary, swipe-up = secondary, swipe-down = tertiary. Long-press = edit the slot (rebind, replace, pin a new macro). Each key shows the two swipe chars as small dim glyphs on the same key (top and bottom edges). |
| Modifier behavior | **Ctrl, Alt, Shift = sticky-for-one-keystroke.** Tap → armed for the next key, auto-disarms. **Ctrl additionally double-tap-to-lock** (Emacs chord case); tap again unlocks. Alt/Shift stay sticky-only (their swipe-based gestures don't support double-arming cleanly; iOS already provides caps-lock for Shift). Esc and Tab fire on tap (no sticky/toggle). |
| Arrow input | **Single Blink-style arrow-pad slot.** Touch and drag from center in any direction (↑↓←→) to fire that arrow. Replaces four discrete arrow keys. |
| Default slots (v0) | 10 slots: **core** (Esc, Ctrl/Alt/Shift, Tab, arrow-pad) + **convenience** (`/`, `\|`, `~`, `-`, `(`, `)`). Convenience slots are removable. Core slots are locked. Full layout: `mockups/specs/keybar.html`. |
| Iteration plan | Defaults are a v0 best-guess. Public character-frequency data for shell typing on mobile doesn't exist. Plan: ship defensible defaults, make customization first-class, tune defaults in v1.5 from predictor's keystroke telemetry (with consent). |

### Window switching

> **Superseded by `2026-06-15-keybar-customization-design.md`.** The standalone Window pill is gone — its role folds into the fused **Esc pill** (swipe-h = prev/next window, swipe-up = quick window picker, swipe-down = new window with confirm, long-press = unified picker including window list). Terminal-area horizontal swipe remains as a secondary path.

| Topic | Decision |
|---|---|
| Affordance | A single **pill** in the keyboard accessory bar (keybar). Stays in same spot when keyboard hidden. |
| Pill content | Window title only (truncate at ~7 chars with ellipsis). No position indicator, no dots. |
| Pill gestures | tap = next, swipe right = next, swipe left = previous, long-press = picker |
| Secondary path | Single-finger horizontal swipe **anywhere in the terminal area** also switches windows (Safari-tabs-style). |
| Safety valves | (1) Auto-suspend terminal swipe when focused pane has mouse mode active. (2) User setting to globally disable. |
| Cycling | Wraps in both directions. Light haptic tick (`UIImpactFeedbackGenerator.light`) on wrap; no visual chrome. |
| Picker | Vertical list expanding upward from the pill. Drag finger up to highlight; release on a row to switch; release back on pill or outside = cancel. Each row: title + `•` activity badge if new output since last viewed. |
| Picker at scale | Past top of screen, hold finger near top edge → auto-scroll. At **≥15 windows**, filter bar auto-appears at top of list (type to filter). |

### Pane management

> **Superseded by `2026-06-15-keybar-customization-design.md`.** The standalone Pane pill is gone — its role folds into the fused **Pad** (drag = arrow keystrokes, tap = zoom toggle, long-press = arm pane mode + bronze overlay, long-press + swipe-h/v = horiz/vert split, long-press + release = Swap/Close menu). Zoom indicator moves from the keybar to the focused pane's corner-index badge (gains a `⊕` glyph when zoomed). Pane-focus behavior (tap inactive pane = focus) unchanged.

| Topic | Decision |
|---|---|
| Management surface | A **second pill** in the keybar next to the window pill. Terminal area kept clear so iOS-native text selection is preserved. |
| Pill content | Adaptive: `+` when 1 pane, `▦` when 2+ panes, `▦` with amber dot when one pane is zoomed. |
| Pill gestures | **Tap** = zoom toggle (or default-split when 1 pane). **Horizontal swipe** = horizontal split. **Vertical swipe** = vertical split. **Long-press** = menu. |
| Default split (tap on `+`) | Horizontal split — new pane appears below the existing one. |
| Long-press menu | Split horizontally · Split vertically · Swap with next · Close pane. *(Layout templates deferred to v1.5.)* |
| Pane focus | **Tap inactive pane** in terminal area = focus moves. Tap is consumed by focus-switch; not sent to remote as click. Active pane has accent border + corner index badge. |
| Zoom behavior | Tap pane pill = zoom focused pane fullscreen. Other panes hidden. Pill's amber dot persists as indicator. Tap pill again to unzoom. To switch panes while zoomed: unzoom first, or use menu's "Swap with next". |
| Many panes on iPhone | **tmux-faithful** — show all panes proportionally, even when cramped. No auto-zoom. User manages by zooming or closing. |
| Split terminology | UI uses vim convention: horizontal split = horizontal divider line (top/bottom). Vertical split = vertical divider line (left/right). Under the hood: `tmux split-window -v` for our "horizontal", `-h` for our "vertical". User never sees tmux flags. |

### Predictive input

| Topic | Decision |
|---|---|
| North star | **Input that learns the user's vocabulary, never silently rewrites it.** iOS silent autocorrect is off, always. Predictive suggestions are explicit (user must tap a chip to accept). |
| Surface | **Thin auto-hiding row above the keybar** (~24pt). Hidden when no suggestion clears the confidence floor. Slides in/out on ~150ms spring. Visually distinct from keybar keys. Cannot reflow the keybar. |
| Engine | Probabilistic data structures (Count-Min Sketch for unigrams + bigrams, Bloom filter for membership). On-device, encrypted at rest. **Sketches sync via CloudKit + client-side AES, default ON, opt-out** — the synced data is a lossy frequency fingerprint (not recoverable text), encrypted E2EE. See `2026-06-16-icloud-sync-scope-design.md`. |
| Storage layout | Hot `today.sketch` + pre-aggregated rolling sketches (7d/30d/90d) + sealed dailies + pinned seed. Queries are O(1): `today ⊕ rolling_<window> ⊕ seed_pinned`. |
| Seeding | Bundled seed from carapace + tldr + curated dotfiles aggregates. **Pinned, not merged** into user's learned sketches — keeps the privacy story clean and lets seed update across app releases without contaminating user data. |
| Deference | **Per-prefix gating** — when ≥`top_k` confident learned candidates exist for a prefix, seed entries hide for that prefix entirely. **Per-token weighting** — seed entries always rank below comparable learned entries (`seed_weight ≈ 0.5`). No global cliff; deference is continuous and automatic. |
| Fallback | When predictor is master-off, iOS native autocorrect/suggestions take over. In normal operation, iOS suggestions never fire — our row is the only suggestion surface. |
| Privacy | Layered: master off · read-only mode · per-host incognito · pattern-exclude list (with built-in defaults targeting secret-shaped strings). Transparency screen + wipe button + retention window setting (default 90 days). |

**Full design**: see `docs/superpowers/specs/2026-06-13-predictor-design.md`.

### Connection status

| Topic | Decision |
|---|---|
| Surface | **Transient banner at the top of the screen** (Blink-style). Slides down on problem, slides back up on resolution. No persistent dot, no status bar real estate. |
| Visibility rule | **Only visible when something is wrong.** Healthy connection = no banner at all. Inspired by Blink's behavior. |
| States to show | Disconnected · reconnecting (mosh roaming) · high latency / degraded · auth failure · host unreachable. Healthy state explicitly does **not** show a banner. |
| Reconnecting label | **Time since last successful frame / heartbeat**, counting up live (`last seen 4s ago` → `12s` → `1m 20s`). Anchors the user's expectation: how stale is the terminal they're looking at? |
| Dismissal | Auto-dismisses when state returns to healthy. User can swipe to dismiss persistent issues (e.g., "I know it's still degraded, stop reminding me"); re-appears if state changes. |
| Detailed status | Tap the banner → expanded view (latency, last roam, mosh frame counts, etc.). *Detailed design deferred.* |

### Cursor placement

| Topic | Decision |
|---|---|
| Gesture model | **Drag from a halo around the cursor.** ~60pt halo, faintly visible always (~15% opacity), brightens on touch. Outside the halo, existing gestures (focus / scroll / window-switch / selection) behave normally. |
| Movement model | **Delta-based (mouse-like), never joystick.** Cursor moves by `finger_delta × gain(speed)`. Stops when finger stops; no momentum, no position-based continuous scrolling. |
| Gain curve | Near 1:1 below ~600 pt/s finger speed (precision zone). Accelerated above, capped at ~3× (long-jump zone). |
| Loupe | Magnifier rides **above the cursor** (not the finger) — user watches the cursor land while their finger can be anywhere on screen. |
| Commit | Lift = commit. Tap inside halo without movement = no-op (no accidental commits). Synthesized arrow keystrokes are streamed to the remote as the cursor moves. |
| Vertical dead-zone | Under **1.5 cells** of cumulative vertical travel, motion is clamped to horizontal-only. Prevents the shell-history footgun (a stray Up arrow swapping the readline buffer). Cross the threshold and vertical unlocks for the rest of the gesture. |
| Cursor offscreen | While scrolled into scrollback, a `⌖` indicator parks at the bottom edge of the active pane. Touching it engages the drag; first movement auto-scrolls back to the live cursor. |
| Mouse-mode passthrough | Halo still works when `set mouse=a` / less / htop is active — we synthesize arrow keys, not mouse events. No collision with taps elsewhere in the pane being passed through as mouse. |
| iOS selection conflict | While iOS-native selection handles are visible, cursor-drag is suppressed. Dismiss selection to re-arm. |
| Haptics | Light tick on engage and lift. No haptics during drag (would feel buzzy under acceleration). |
| Multi-pane | Halo only on the focused pane. Drag clamped to that pane's geometry. |

### Text selection / copy & paste

| Topic | Decision |
|---|---|
| Selection gesture | **Long-press in a pane** = iOS-native text selection (magnifier loupe, drag handles, copy menu). Identical UX to Notes / Safari. |
| Selection scope | Per-pane. Selection can't cross a pane divider — matches desktop tmux. |
| Design constraint | All pane and window management lives on keybar pills so the terminal area stays available for selection / scrollback. |

### Context detection

| Topic | Decision |
|---|---|
| Scope | **Foreground process per pane**, including REPLs (vim/nvim, less/more/man, python/node, psql/mysql, sqlite3, redis-cli, htop/top/mc, …). Modal sub-states (vim insert vs normal) and shell-command-line prediction deferred to v2. |
| Signal source | **`pane_current_command` from tmux control mode.** Zero host cooperation required — works on any host the user can SSH to. |
| Anti-flap | Asymmetric per-pane state machine: **engage at 250ms dwell, disengage at 1500ms dwell.** Brief excursions (`:!`, `:sh`) don't reflow the bar. |
| Keybar structure | Bar splits into **locked left section** (window pill · pane pill · arrow-pad · Esc) + **horizontally scrollable right section** (Ctrl/Alt/Shift · Tab · promotions · defaults · Fn). |
| Promotion model | Per context, a curated set of **symbols** is pushed to the front of the scroll region, directly after Tab. Defaults push right but remain reachable via pan. Letters are never promoted (iOS already provides them). |
| Promoted slot visual | **Bronze tint fill (~12%) + 1pt bronze top-edge accent.** Glyph contrast preserved. Distinct from pressed / modifier-armed / focus-halo / connection states. |
| Authoring | Bundled JSON defaults for ~8 apps. JSON-file customization in v1; in-app editor v1.5. User can register new processes. |
| Override | Long-press pane pill → "Pin to defaults" / "Pin to *current context*." Global kill-switch in settings. Unknown processes silently fall back to defaults (no nag). |
| Shared signal | Per-pane `currentContext` observable on the session model. Keybar is v1's only consumer; predictor / launcher / pill-badge can subscribe later without re-architecture. |

**Full design**: see `docs/superpowers/specs/2026-06-14-context-detection-design.md`.

### Function keys

| Topic | Decision |
|---|---|
| Surface | **Fn slot in the keybar toggles "F-key mode" on the scrollable region** — F1–F12 appear in place of `[promotions, defaults]`. Locked region unchanged. Matches the layer-toggle pattern used by Blink, Termius, a-Shell. |
| Fn slot location | **End of the scroll region by default, not always visible.** Heavy users live in auto-engaging contexts; everyone else gets it out of the way. Customizable. |
| Fn state machine | **Caps-lock semantics.** Tap = Armed (one-shot, fires next F-key then reverts). Double-tap = Locked (until tapped again). Tap-while-locked = Off. |
| Auto-engage | In `htop`, `top`, `mc` the context detection state machine auto-locks Fn on entry, returns to Off on exit. Same 250/1500 thresholds. |
| User override per episode | If the user single-taps Fn off during an auto-engaged episode, `fnUserOverride = true` for that episode — auto-engage will not relock until the next visit to that context. |
| Range | F1–F12. F13–F24 not surfaced. |
| Mutual exclusion | Fn mode and symbol promotions both transform the scroll region; they're mutually exclusive on display. No conflict in the v1 bundled lists. |

**Full design**: see `docs/superpowers/specs/2026-06-14-function-keys-design.md`.

### Degraded mode & tmux requirements

| Topic | Decision |
|---|---|
| Minimum tmux | **3.0** (2019). Below = degraded mode. No partial-version support. |
| "Raw passthrough" as a feature | **Non-goal.** No user-facing toggle, no power-user mode. Degraded mode is a fallback, not a taste preference. |
| Bootstrap / auto-install | **Never.** Semicolyn does not drop binaries, run package managers, or sudo on user hosts. |
| Detection | Single `tmux -V` at connect; result decides `-CC` vs raw PTY. |
| What works in degraded mode | Connection, single shell, predictor, snippets, keybar (modifiers/arrows/Esc/Tab/Fn manual), iOS copy/paste, cursor placement, status banner. |
| What's off in degraded mode | Window pill, pane pill, context detection, function-key auto-engage. |
| Keybar layout (degraded) | Locked-left collapses left after pills are removed; no badge, no accent shift — pill absence is the indicator. |
| Connect-time banner | Reuses transient amber connection-status banner. Reoccurs every reconnect. No persistent chrome. |
| Suppression | **Per-host only.** Auto-offered as a one-tap action after 2–3 dismissals; global toggle rejected as a footgun. Per-host "Don't attempt tmux on this host" ships in the v1 host-config schema as `semicolyn.tmux.attemptControlMode` (see `2026-06-15-host-config-model-design.md`) and is exposed in the host-CRUD "Semicolyn behavior" section. |
| Mid-session crash recovery | Drop to degraded immediately on same connection; show **persistent red banner** (the one documented exception to the transient-banner rule) with Reattach / Start new tmux / Dismiss. No auto-retry of `-CC`, no layout restoration, no false reassurance. |

**Full design**: see `docs/superpowers/specs/2026-06-14-degraded-mode-design.md`.

### Host management & settings access (entry point)

| Topic | Decision |
|---|---|
| Concurrency model | **Multiple simultaneous live connections.** Not single-foreground. |
| Top-level entry point | **Long-press Esc slot in the keybar** (~400ms). Opens picker sheet. Esc was previously a tap-only core slot; long-press was undefined — no overload, no conflict. |
| Visual hint | Small dim bronze **`≡`** glyph below the "Esc" label. Indicates "hold here for menu." |
| Engage feedback | Esc slot highlights bronze + scales slightly + light haptic on long-press engage. |
| Host chip / top bar | **None.** No persistent top-of-screen chrome for host status. Terminal extends right up to the DI safe-area edge. (Banner can still slide in from top when needed.) |
| Picker anchor | **Above the keybar** (near where the gesture happened), not top of screen. Keeps the user's eyes near their thumb. |
| Picker contents | **Live → Recent → + Connect to host… → ⚙ Settings.** Current host highlighted within Live group. |
| Definition of "live" | A connection is "Live" if the client trusts it can resume (re-auth may still apply per identity policy — an `anyUse` identity on a Sleeping mosh row will still prompt Face ID on wake). Mosh stays live across backgrounding (server-side session). SSH stays live while foreground / in iOS bg grace. **SSH/mosh are unified in the UI** — user sees Live vs Recent, not protocol. Drops from Live → Recent happen automatically when the underlying session is killed. |
| Per-row swipe actions | **Live row:** `[Edit] [Disconnect]` (rightmost red; Disconnect closes session, keeps config, moves row to Recent). **Recent row:** `[Edit] [Delete]` (rightmost red; Delete removes the config entirely, with a confirmation prompt). |
| Per-row long-press | Context menu with the swipe actions **plus** Copy hostname, Duplicate, Connection details. |
| Banner placement | **Unchanged — banners stay at top of screen.** Independent of keyboard state. tmux-crash banner keeps action buttons in the banner itself (rare action, reach acceptable). |
| Settings entry | **Inside the picker sheet** as the last row. No separate settings button, gear icon, hamburger, or tab anywhere in the app. The picker is the **only on-screen** top-level handle. Hardware Cmd-shortcuts (`⌘,` and friends, per `2026-06-17-external-keyboard-design.md`) are off-screen and don't count as affordances; they're the power-user equivalent of the same picker routes. |
| Settings tree | Top level: **Hosts** (host config CRUD), **Identities & Keys** (SSH keypairs, biometric policy), **Security** (App lock, predictor controls, host fingerprints), **App preferences** (keybar, iCloud sync, haptics), **About & Help**. Final v1 layout per `2026-06-16-settings-sub-screens-design.md`. |
| Editing a host (two paths) | (1) **Mid-session quick edit:** swipe row in picker → Edit. (2) **Deep curation:** Settings → Hosts → tap host → edit screen. |
| Dynamic Island handling rule | **A+C.** All top-edge chrome (chip-equivalents and banners alike) honors `safeAreaInsets.top` — placed flush below whatever the OS owns (DI / notch / status bar). Top-bar background tints around the DI so the cutout reads as part of our chrome rather than a hole. **No interactive UI in the flank** (Apple HIG, tap-collision). |
| Live Activities (DI background presence) | **Out of scope for v1.** Worth revisiting post-v1; chip's data model designed so a Live Activity could feed off it later. |

**Mockup**: see `mockups/drafts/host-management.html`. CRUD flow + multi-connection switching semantics still deferred.

### Host config model

| Topic | Decision |
|---|---|
| Design posture | **`ssh_config(5)`-faithful in naming and semantics**, strict subset of OpenSSH's expressive power, lossless import/export with `~/.ssh/config` as a design goal. Semicolyn extensions namespaced (`mosh.*`, `tailscale.*`, `semicolyn.*`). |
| Inheritance | **Single global Defaults record + per-host overrides.** Equivalent to OpenSSH's `Host *` block, no wildcards. `undefined = inherit`, `null/[]` = explicit override to "none" (distinction baked in so future groups/patterns are additive). |
| Stable ID | **UUID v4** at create time; immutable; internal only. User-facing identifier is `label` (free-form, soft-unique — warn-on-duplicate, allow save). Export to `~/.ssh/config` sanitizes label → alias at write time. |
| Required fields | `id` (UUID), `label`, `hostName`. Everything else optional → inherits from Defaults → built-in fallback. |
| Auth refs | **Ordered `identities: IdentityRef[]`** (matches OpenSSH `IdentityFile` repeated-line model) + optional `passwordRef`. `preferredAuthentications` order controls attempt sequence. Auth policy is identity-level only in v1 (host-level confirmation deferred). |
| Jump chain | **Mixed `proxyJump: JumpHop[]`** — each hop is `{kind: "ref", hostId}` or `{kind: "inline", hostName, port?, user?, identities?}`. Matches OpenSSH `ProxyJump alias,user@host:port,…`. Cycles refused at save. Deleting a referenced jumphost is refused with a "used by X, Y" message. |
| Port forwards | All three OpenSSH types modeled with faithful shapes: `localForwards[]`, `remoteForwards[]`, `dynamicForwards[]`. |
| OpenSSH option scope | **Tier 1** (always visible): connection basics, identities, jump chain, port forwards. **Tier 2** ("Advanced" disclosure): `serverAliveInterval/CountMax`, `compression`, `strictHostKeyChecking`, `forwardAgent` (default false), `preferredAuthentications`. **Tier 3** (Ciphers/MACs/Kex/HostKey/GSSAPI/etc.) deferred — no escape hatch in v1. |
| Mosh | **`mosh: { enabled, serverPath?, udpPortRange?, predictionMode? }`** — modeled as an SSH-bootstrap option, not a separate transport, because mosh actually is one. Defaults: `enabled=false`, `udpPortRange=[60000, 61000]`, `predictionMode="adaptive"`. |
| Tailscale | **`tailscale: { required, tailnet? }`** — awareness flag only; OS handles routing. When `required=true` and Tailscale is down, connection-status banner says "Tailscale required" instead of generic unreachable. Tailscale SSH (auth via tailnet identity) deferred to v1.5+. |
| Semicolyn per-host extensions (v1) | **`semicolyn.predictor.incognito`** (don't learn from this host) and **`semicolyn.tmux.attemptControlMode`** (skip `-CC` probe per-host). Everything else stays global in v1. |
| Identity model | **First-class entity, not embedded** (forced by iOS storage — SE keys can't be embedded, iCloud Keychain keys outlive any specific host). Two flavors at creation: **`iCloudKeychain`** (default — synced E2EE across devices, device-portable) or **`secureEnclave`** (opt-in "enhanced" — hardware-bound, single device). Host create flow can create inline so users never have to visit "Identities & Keys" for the basic path. |
| Auth policy enforcement | Identity-level only in v1, via iOS `SecAccessControl`: `never` / `anyUse` (biometric every use) / `afterUnlock` (biometric once per unlock). |
| Storage backbone | **iCloud Keychain (E2EE)** = keys, passwords, passphrases, `known_hosts` entries, host-config encryption key. **Secure Enclave** = opt-in device-bound identities. **CloudKit Private DB + client-side AES-256-GCM** = host records, Defaults record, identity metadata (32-byte key in iCloud Keychain → effective E2EE regardless of user's ADP setting). **Local only** = recent connections, live session state. |
| `known_hosts` | iCloud Keychain, synced. Trust-on-first-use on one device propagates to all. Per-host list (multiple entries supported for rotation windows). Mismatch UX: banner + modal with old/new fingerprints and *Trust new* / *Trust on this device only* / *Cancel*. |
| Forward-compat | Schema designed so future additions are additive: groups/tags (Q1 deferred option), pattern matching (deferred), Tier 3 options, host-level confirmation policy, per-host snippets/keybar/context overrides. None of these require breaking v1 records. |

**Full spec**: see `docs/superpowers/specs/2026-06-15-host-config-model-design.md`. CRUD flow + multi-connection switching semantics are separate deferred items.

### Host CRUD flow

| Topic | Decision |
|---|---|
| Form shape | **Single scrollable form, same for create and edit.** No wizard, no tabs. Nine sections: Basics · Auth · Connection · Jump chain · Port forwarding · Mosh · Tailscale · Semicolyn behavior · Delete host (edit-only). |
| Default expansion | New host: Basics + Auth expanded; rest collapsed. Edit host: a section auto-expands iff it carries a non-default value. Save with errors: any flagged section auto-expands. Not persisted across opens. |
| Conditional fields | **Show + explain, never hide.** `mosh.enabled = true` → `serverAlive*` rows grayed out with tooltip ("Mosh has its own keepalive"); port-forward, forwardAgent, and Tailscale sections show inline caveat banners under their headers. No field is ever fully hidden by conditional rules. |
| Identity sub-flow | Half-sheet from bottom with **three tabs**: **Pick existing** (list of stored identities with flavor + biometric badges), **Create new** (algorithm / storage flavor / biometric policy / display name), **Import existing** (paste PEM/OpenSSH blob + optional passphrase + flavor + policy). Post-create/import shows public key with Copy/Share/AirDrop for manual install. |
| ssh-copy-id auto-install | **Deferred to v1.5.** v1 = manual paste only. |
| Password-manager integration | **Locked out (storage backend).** iOS has no SSH-agent IPC primitive; cross-vendor app key access doesn't exist. iCloud Keychain (Apple's PM backend) IS our default storage. **Import existing key** path covers the "I generated my key in 1Password" case. |
| Validation timing | **Hybrid.** Required-field markers (bronze `•`) live; Save button disabled until `label` + `hostName` set. **Content validation** (cycle detection, label duplicates, no-user-anywhere, malformed forward, stale passwordRef) runs **on Save tap**. Flagged sections auto-expand. |
| Soft- vs hard-block | Duplicate label = soft (allow override with "Save anyway"). No user anywhere = soft on save, hard on connect. Jump cycle = hard. Malformed forward = hard. Stale passwordRef = hard. |
| Cancel | Action sheet if changes exist ("Discard changes? Keep editing / Discard"). Silent dismiss otherwise. **No auto-draft in v1** (v1.5 candidate). |
| Quick-edit vs deep-edit | **Same form, different presentation.** Quick-edit (picker swipe) = half-sheet. Deep-edit (Settings → Hosts → tap) = full-screen push. Identical fields, validation, expansion rules. |
| Delete | Two entry points: picker swipe and form-bottom row (edit mode). Confirmation sheet on both. |
| Refused-if-referenced delete | If host is a `proxyJump` ref target, delete refused with a tappable list of dependents ("Used as jumphost by: prod-db, staging-api"). Tapping a dependent navigates into its editor with Jump chain pre-expanded. No cascade. Identity records are never deleted by host delete. |
| Defaults editor | Same form shell; no `label`/`hostName`/Delete; all sections collapsed by default; each row shows **inherit unset** vs **set** state; **swipe-left to Clear override** (revert to system fallback). Entry: dedicated row at top of Settings → Hosts. |

**Full spec**: see `docs/superpowers/specs/2026-06-15-host-crud-design.md`. **Mockup**: `mockups/specs/host-crud.html`.

### Identities & Keys management surface

| Topic | Decision |
|---|---|
| Scope | **Inventory + standalone create.** No rotation wizard in v1 (deferred until `ssh-copy-id` auto-install lands in v1.5). Without auto-install, rotation is a checklist with a hand-wave in the middle. |
| List sort | Alphabetical by `displayName`. No search, no filter, no sort toggle. Settings-screen stability matters more than recency. |
| Row anatomy | Display name + algorithm + fingerprint-prefix on left; flavor chip (`iCloud` muted / `SE` bronze) + usage indicator on right; chevron to detail. `Used by N` or `Unused` (italic, further muted) for cleanup affordance. |
| Swipe actions | **None.** Delete reachable only from the detail screen — destructive operations don't belong on swipe gestures. |
| Empty state | Centered key glyph + "No keys yet" + single CTA opening the create/import half-sheet. |
| Detail screen edits | Display name (inline, commit on blur, soft-unique). Auth policy (3-segment: `Never` / `Per-unlock` / `Per-use`) commits immediately. **No biometric on settings changes** — app-level unlock is the security gate (matches Blink / Termius / Secretive / 1Password / iOS Passwords). |
| Public key / fingerprint | Both shown in monospace with inline Copy. Clipboard only in v1 — QR / Share / AirDrop deferred. |
| "Used by" drill-down | Push to filtered host list (same component as `Settings → Hosts`). `Unused` row still pushes to an empty state — back-reference contract is symmetric. |
| Delete (unreferenced) | Bottom-anchored destructive button → action sheet from bottom. Confirm row in top group, Cancel in bottom group — geometry guards against muscle-memory double-tap. No biometric. Body copy varies: iCloud mentions cross-device removal, SE bolds irreversibility (in red). |
| Delete (referenced) | Refusal pattern mirrors host CRUD jumphost delete. Surface the back-references as a tappable "Show hosts using this key" navigation row; no destructive option offered. |
| What gets deleted | Both the `Identity` metadata record AND the underlying private key material (Keychain item / SE handle). No orphaned key material. |
| Create/Import sub-flow | Same half-sheet as host CRUD inline create. Standalone entry hides the `Pick existing` tab (no-op there); attached entry from host CRUD shows all three tabs. |
| Import sources | Paste + Files app picker. **No Share Extension in v1.** Imported keys always land in iCloud Keychain (SE cannot accept external key material — flavor selector absent). Passphrase consumed on decrypt and discarded. |
| Tab label | **"Create new"** (formerly "Mint new" — renamed throughout for plain language). |
| Entry points | `Settings → Identities & Keys` (list), plus tappable identity refs from host CRUD (push directly to detail). |

**Full spec**: see `docs/superpowers/specs/2026-06-15-identities-keys-management-design.md`. **Mockup**: `mockups/specs/identities-keys.html`.

### Multi-connection switching semantics

| Topic | Decision |
|---|---|
| State model | Four-state lifecycle: **Active · Live·Awake · Live·Sleeping · Recent**. Awake = client holds sockets / mosh frames; Sleeping = client released resources, trusts can resume; Recent = no live state at all. |
| App backgrounding | Standard `beginBackgroundTask` only — no entitlement heroics. After iOS suspends: SSH connections demote to Sleeping (TCP gone); mosh stays conceptually Awake (server holds the session). |
| Foreground return | Eagerly reattach the foreground connection only (mosh resume or SSH reconnect + `tmux attach`). Other connections sit as Sleeping until tapped. |
| Cold launch | Mosh state persists across cold launch as Sleeping; SSH does not (rolls to Recent). Auto-resume the last-foregrounded mosh on cold launch. |
| Soft cap | 8 simultaneously Awake. 9th connect silently LRU-demotes an existing Awake to Sleeping. Sleeping count is unbounded. |
| Memory pressure | LRU sweep of Awake → Sleeping until iOS pressure clears. |
| Mosh resume | Resume token first; transparent fallback to fresh `mosh-server` bootstrap if server expired. Drop to Recent only on full failure. |
| Disconnect swipe | Client-only abandon — mosh server times out naturally, tmux session preserved on host. Reconnect within window resumes same session. |
| `anyUse` policy on wake | Honored literally — Face ID prompt fires on waking a sleeping session whose identity is `anyUse`. |
| Banner under multi-connection | Banner remains single-subject (foreground only). Background-connection health surfaces as a picker-row dot (amber/red) — no banner intrusion. |
| Picker visual | Live group shows Awake (solid, green dot) and Sleeping (lower opacity + `zZ` glyph) under one header. Recent group capped at 10, sorted by last-disconnected. |
| Activity indicators | **No** per-host new-output dot. Dots carry connection-health semantics only. "Notify on command done" deferred to v1.5+. |

**Full spec**: see `docs/superpowers/specs/2026-06-15-multi-connection-switching-design.md`. **Mockup**: `mockups/drafts/multi-connection-banner.html`.

### Keybar layout, customization, gesture-ownership (revisit)

| Topic | Decision |
|---|---|
| Default locked-left | **Esc pill · Pad · Modifier · Tab** (4 items). Esc pill fuses the old Esc slot + Window pill; Pad fuses arrow-pad + Pane pill. Modifier and Tab are regular slots, movable to scroll by the user. |
| Esc pill gestures | Tap = Esc · swipe-h = window prev/next · swipe-up = quick window picker · swipe-down = create new window (confirm) · long-press = unified picker (windows · hosts · Connect · Settings). |
| Pad gestures | Drag = arrow keystrokes · tap = zoom toggle · long-press = arm pane mode (bronze overlay) · long-press + swipe-h = horiz split · long-press + swipe-v = vert split · long-press + release = Swap/Close menu. |
| Zoom indicator | Lives on the focused pane (corner-index badge gains `⊕`), not in the keybar. |
| Constraints | Esc pill and Pad cannot leave the locked region. All other slots are reorderable, removable, and movable across the locked-vs-scroll divider. |
| Customization surface | Settings → Keybar — single editable list with a draggable divider between locked (above) and scroll (below). Per-row swipe-delete. "+ Add" for macros or new custom slots. |
| Custom slot bindings | Each gesture (tap / swipe-up / swipe-down / long-press) binds to a macro. Horizontal swipes on user slots **deferred to v1.5+** to avoid pan-collision. Long-press-to-edit shortcut removed; edit moves to Settings. |
| Reverse-bar option | Settings → Keybar → Layout direction: Locked-left / **Locked-right** (left-handed / preference toggle). Pure layout mirror; gesture semantics unchanged. |
| Gesture ownership | **Touch-down location decides** which recognizer claims the gesture. Esc pill and Pad own their bounds (Blink-style); pan engages from anywhere else. |
| Macro creation | Record mode (start recording, type the sequence, stop) or Template mode (literal string + inline modifier chord tokens). Created in Launcher or via "Record new" from a slot binding. |

**Full spec**: see `docs/superpowers/specs/2026-06-15-keybar-customization-design.md`. **Mockup**: `mockups/drafts/esc-pill.html`.

### iCloud sync scope

| Topic | Decision |
|---|---|
| Organizing principle | **Configuration syncs. Behavior / history doesn't** — except predictor sketches, which sync because they're structurally lossy (CMS/Bloom) and the cross-device value is too high to bury. |
| Macro library | Syncs via CloudKit + client-side AES-256-GCM, default ON. Per-macro "don't sync" flag for sensitive entries. |
| Keybar customizations | Sync via CloudKit + AES — custom slots, slot order, divider position, reverse-bar toggle. |
| Predictor sketches | **Sync via CloudKit + AES, default ON, opt-out per device.** Revises the predictor spec's "no cloud" promise. Sketch blobs are multi-MB so CloudKit (not Keychain). |
| Audit log | **Dropped from v1 entirely.** No user-facing surface, no quiet collection. Code-level stub reserved for a future Pro compliance feature. |
| New-device restore | Implicit via sync — no separate "restore from iCloud" button. Sign into iCloud → install Semicolyn → synced state populates. |
| Snapshot time-travel | Deferred to v1.5+ (point-in-time rollback to a prior sealed daily). |
| Sync status surface | None in v1 (CloudKit transparent). Add later if usage shows confusion. |

**Full spec**: see `docs/superpowers/specs/2026-06-16-icloud-sync-scope-design.md`.

### First-host onboarding & Tips & Gestures

| Topic | Decision |
|---|---|
| Posture | **No forced walkthrough, no JIT tooltips.** Coach marks, spotlight overlays, animated callouts all rejected. Semicolyn-specific gesture vocabulary is documented in one voluntary reference screen, openable from two entry points. |
| Empty state (no hosts) | Centered **"Add your first host"** CTA (bell-bronze, large tap target) + one-line micro-copy *("You'll need a hostname, username, and either a password or key.")* + dim secondary row: **Settings · Tips & Gestures**. Keybar hidden (nothing to act on). Empty state disappears once any host exists; does not return on later "all hosts deleted." |
| Esc-pill picker (post-connection) | Existing rows (Live → Recent → + Connect → ⚙ Settings) gain **? Tips & Gestures** as a new bottom row. Same destination as the empty-state link. Always present — no badge, no "unread" indicator. |
| Screen format | Single scrollable page. Top-anchored close button. Six sections: **The keybar · The Esc pill · The Pad · Context-aware promotions · Modifiers · Fn keys.** Each section = short prose + one small static SVG diagram. Identical content from both entry points; no first-time-vs-returning branching. |
| Visual treatment | Static SVG inline per section. No animation, no autoplay, no looping clips. Bronze accent strokes on cool-dark fill. |
| State tracking | **None.** No read state, no analytics, no CloudKit sync of "have you seen this." Entry points symmetric and permanent (or, for empty state, until first host). |
| Label rationale | **"Tips & Gestures"** chosen over "Getting Started" (temporally wrong once user has started), "Help" (negative connotation), "Guide" (sounds like a full manual). Telegraphs content honestly; "Tips" leaves room to add non-gesture material later without relabeling. |
| Cut from tooltips | Predictor row (self-explanatory by existing); keybar swipe-up/down secondaries (covered by keybar orientation paragraph; dim glyphs on each key already telegraph affordance). |
| Out of scope (v1) | JIT tooltips, demo PTY / sample session, prefilled example host, multi-page swipe tour, unread badges, localisation. |

**Full spec**: see `docs/superpowers/specs/2026-06-16-first-host-onboarding-design.md`. **Mockup**: `mockups/specs/first-host-onboarding.html`.

### Settings sub-screens (Security · App preferences · About & Help)

| Topic | Decision |
|---|---|
| Scope | The three remaining sub-screens after Hosts and Identities & Keys. Each kept narrow; power-user knobs deferred. |
| Security: App lock | **Opt-in, off by default** — revises the prior "Face ID once per session" framing. When enabled, sub-row exposes **Re-lock timeout** (Immediately / 1m / 5m / 15m; default 5m). Live sessions on re-lock are **hidden, not killed** (killing a mosh would defeat its purpose). Lock view = full-screen sheet with Semicolyn mark + Unlock button. Falls through to device passcode on Face ID cancel (standard `LAContext`). |
| Security: Predictor | **Two controls only.** Master toggle (default ON; off = pause, not delete — sketches persist on disk and in iCloud sync) + **Wipe all learning** (destructive, action-sheet confirm). Wipe clears today + rolling + sealed dailies; **the bundled seed survives**. Pattern-exclude, retention window, incognito hosts review all deferred to v1.5+. |
| Security: Host fingerprints | Drill-down titled **"Host fingerprints"** (avoids `known_hosts` jargon). Flat alphabetical list, hostname + algorithm or key count, swipe-to-forget per entry. No global forget-all, no search, no sort toggle. |
| App preferences: Keybar | Single drill-down row, passes through to the editable list specced in `2026-06-15-keybar-customization-design.md`. No new UI. |
| App preferences: iCloud sync | Three category toggles (**Macros · Keybar customizations · Predictor sketches**), all default ON per the iCloud sync scope spec. Toggling off stops bidirectional sync for that category; existing local data untouched. Footer caption telegraphs the on-device encryption story. Per-macro "don't sync" flag lives on the macro itself, not here. |
| App preferences: Haptics | Single global toggle, default ON. Off disables cursor engage/lift tick, window-switch wrap tick, long-press feedback, modifier-engage feedback. No per-event tuning in v1. |
| App preferences cuts | No **Appearance** section (one palette in v1 — no light mode, no theme picker). No **Connection defaults** entry (Defaults editor lives under `Settings → Hosts`). No **Predictor display tuning** (confidence floor / row position — defaults from predictor spec carry v1). |
| About & Help | Five rows: **Tips & Gestures** (secondary path to the same screen the Esc-pill picker opens) · **Privacy statement** (plain-English drill-down; storage-is-the-security framing, sync scope, no telemetry) · **Open source** (alphabetical OSS list with licenses, generated at archive time) · **Send feedback** (`MFMailComposeViewController` with version/build pre-filled; fall-back to copyable email if no Mail set up) · **Semicolyn 1.0.0 (1234)** read-only row, tap to copy. |
| About & Help cuts | No **Terms of Service** (no account, no service). No **Rate the app** (friction-y). No **Changelog** (defer until v1.5 has content). |
| Cross-cutting | All destructive actions use the same action-sheet idiom as Identity delete (destructive row in top group, Cancel in bottom group). Footer captions used sparingly — only Predictor toggle, iCloud sync group, App lock when on. No badges, no "new" pips anywhere in Settings. |

**Full spec**: see `docs/superpowers/specs/2026-06-16-settings-sub-screens-design.md`. **Mockup**: `mockups/specs/settings-sub-screens.html`.

### Pro / paid scope

| Topic | Decision |
|---|---|
| Posture | Semicolyn ships into an established category (Blink, Termius, Prompt 3, …). Monetization is **secondary to product quality**. The product is for users; payment is for users who *want* to support development. **No feature that defines the product sits behind a paywall.** |
| Qualification rule | **A feature qualifies as Pro only if it is cosmetic, optional, or a thank-you. The moment "I need Pro to do X" is a real sentence, the feature is wrong for Pro.** Test future feature ideas against this. |
| Monetization model | **Free + one-time Pro purchase.** Single non-consumable in-app purchase via StoreKit, Family Sharing on. Price band $5–10 USD (exact decided pre-launch). **No subscription, no Pro+, no Ultimate tier, no trial mode, no time-limited free Pro.** Resolves the README's open `Monetization` thread. |
| v1 Pro inventory | Three cosmetic / vanity perks: (1) **alternative app icons** via `setAlternateIconName`; (2) **alternative color themes** (light up the moment a second palette is actually designed — v1 ships bell-bronze only); (3) **Supporter badge** in About & Help, visible only to the user. That's the entire inventory. |
| Entry point | **One row at the top of About & Help.** Reads "Semicolyn Pro" when free, "Semicolyn Pro — thanks!" when active. Tapping pushes to a plain settings-style upgrade screen (not a modal, not a full-screen takeover). |
| Upgrade screen rules | Anchor sentence: *"Semicolyn is, and will stay, free to use in full."* Included list is **exact** — no vague "and more!" Restore purchase + Family Sharing notice visible without being buried. No countdown, no urgency, no "limited time." |
| Visibility | **No upsell prompts anywhere else in the app.** Not in onboarding, not after the Nth connection, not on any preference change. No "Pro" lock icons on any feature (there are no features to lock). The About row is the only entry point. |
| Enterprise (deferred) | **Explicitly out of v1.** Candidate features captured but not designed: **audit log** (compliance — stub already at data layer), **team-shared host configs** (most natural subscription candidate if there ever is one — needs backend), **MDM-friendly configuration**, **centralized policy enforcement**, **SSO into the app**, **sealed org-curated snippet packs**, **concurrent-device licensing / seat management**, **premium support**. None designed; revisit when a real customer asks. Even in an enterprise tier, the qualification rule still applies — enterprise features must be things that *only make sense in an org context*, not solo features pay-walled. |

**Full spec**: see `docs/superpowers/specs/2026-06-16-pro-paid-scope-design.md`. **Mockup**: `mockups/specs/pro-paid.html`.

### Connection-status banner expanded view

| Topic | Decision |
|---|---|
| Trigger | Tap any transient banner state (reconnecting · high latency · auth failure · host unreachable · disconnected). **tmux-crashed banner is out of scope** — already has inline actions, never expands. |
| Layout | **Expand in place** — the banner grows downward; terminal scrolls under. One mental model: the banner *is* the connection-status surface. Auto-collapses when the underlying state returns to healthy. Beats half-sheet (two concepts for one thing) and full-sheet (heavy interruption for a status check). |
| Two templates | (1) **"Live in trouble"** (amber) — reconnecting / high latency. Stats grid + inline RTT graph (60s rolling, min/max overlay) + actions. mosh-specific rows (frames sent/acked, last roam, network) hide for SSH; SSH-specific keepalive row appears. (2) **"Connection failed"** (red) — auth failure / host unreachable / disconnected. Fault details (DNS / TCP / method / identity / attempts) + red-tinted error strip with the underlying error string verbatim + actions. No graph. |
| Template 1 actions | **Retry now** (primary, amber) · Copy diagnostics · **Disconnect** (destructive). |
| Template 2 actions | **Retry** (primary, red) · **Edit host** (pushes to host CRUD) · Copy diagnostics · **Disconnect** (destructive). |
| Dismissal | Four ways out: tap header to collapse · swipe up on the bottom grab-handle (the handle shows a `↑` chevron — banner came from the top, so up = away) · auto-collapse when state returns to healthy · swipe up on the collapsed banner to dismiss (already-locked persistent-issue dismiss). Consistent rule: **up = away**, never down. |
| Copy diagnostics | JSON snapshot of visible fields + `copiedAt` timestamp + app version/build + iOS version + device model + banner state + (Template 2) underlying error string. **No redaction** — user explicitly chose to copy. Light haptic + small auto-fading "Copied" toast at the bottom of the expanded panel. |
| Live updating | Fields refresh once per second while open. Header stamp and `Last seen` row share an observable so they never disagree. RTT graph appends one sample per second, drops oldest past 60s, no inter-sample animation. |
| Obscured terminal | Accepted — user tapped a "something is wrong" banner; covering the terminal underneath is fine. |
| Out of scope (v1) | Per-state custom layouts beyond the two templates · editable thresholds · full roam-history log (deferred to v1.5+) · "Switch network" inline action (iOS doesn't allow it programmatically) · "Change identity" inline action (Edit host covers it) · ShareSheet for diagnostics (Copy is enough) · iPad adaptation · localisation. |

**Full spec**: see `docs/superpowers/specs/2026-06-16-banner-expanded-design.md`. **Mockups**: `mockups/drafts/banner-expanded-layouts.html` (three layouts compared) · `mockups/specs/banner-expanded-templates.html` (both templates rendered with example states).

### iPad scope (v1)

| Topic | Decision |
|---|---|
| Posture | **Universal iPhone + iPad binary, iPad-compatible not iPad-native.** Same UX rendered in a single iPad window, size-class-aware so nothing looks wrong at iPad size. No iPad-specific affordances. |
| In v1 | Software keyboard works the same way as iPhone (incl. floating mini and split keyboard). External keyboard supported regardless of device. Every v1 mockup must render reasonably at iPad size; layouts that break need a size-class branch in the same spec. |
| Deferred to v1.5+ | `UISceneSession` multi-window (Stage Manager / Split View), landscape-specific layouts (wider keybar, side-by-side panes), trackpad / pointer integration. Apple Pencil not considered. |
| Revisit trigger | Quantitative iPad share of v1 active users + qualitative feedback that iPad ergonomics block real work. |

**Full spec**: see `docs/superpowers/specs/2026-06-17-ipad-scope-design.md`.

### External keyboard support

| Topic | Decision |
|---|---|
| Trigger | Bluetooth / USB-C keyboard on iPhone, Magic Keyboard / Smart Keyboard Folio on iPad. iOS suppresses the software keyboard; Semicolyn adapts. |
| Keybar | Stays visible as **compact floating bar** (Esc pill · Pad · Modifier · Tab) above the home indicator. Predictor strip governed independently. App preferences toggle to hide keybar entirely. |
| Passthrough | Letters / numbers / symbols / arrows / Tab / Esc raw-byte to the terminal. **Ctrl / Option / Shift become real held modifiers** — no sticky dance. The headline win of HW keyboard support. |
| Esc handling | Magic Keyboards mostly lack Esc — documented in Tips & Gestures: use iOS Settings → General → Keyboard → Hardware Keyboard → Caps Lock → Escape. In-app Esc rebind deferred to v1.5. |
| Cmd shortcuts | **18 actions / 20 shortcuts.** `⌘T` new window, `⌘W` close, `⌘1…9` switch, `⇧⌘[`/`⇧⌘]` prev/next window, `⌘[`/`⌘]` prev/next pane, `⌘D`/`⌘\|` vertical split, `⇧⌘D`/`⌘-` horizontal split, `⌘F` find, `⌘K` clear, `⌘C`/`⌘V` copy/paste, `⇧⌘N` new connection, `⇧⌘R` reconnect, `⇧⌘P` macro launcher, `⌘,` settings, `⌘?` Tips & Gestures, `⌘+`/`⌘-`/`⌘0` font size. iOS auto-renders the discoverability HUD via `UIKeyCommand`. |
| "Only handle" rule | The on-screen Esc-pill picker remains the only on-screen handle to Settings. Hardware Cmd-shortcuts (`⌘,` and friends) are off-screen and don't violate that rule. |
| Macro vs shortcut collision | **System shortcut wins.** Macros are touch-surface bindings; Cmd-shortcuts route through `UIKeyCommand` at a higher layer. No warning in v1. |
| Deferred | In-app Esc rebind, custom Cmd-shortcut remap, scrollback nav shortcuts, hardware F-row passthrough. |

**Full spec**: see `docs/superpowers/specs/2026-06-17-external-keyboard-design.md`.

### Color theming plumbing

| Topic | Decision |
|---|---|
| API shape | **Single-layer semantic-token public API.** UI code reads `Color.theme.surface.bg`, `Color.theme.bell.edge`, etc. — nested namespace via structs, idiomatic SwiftUI. Never hex literals in consumer code. |
| Theme file shape | Each theme is one Swift file. Inside it: `private let` palette constants with human-readable names (`bronze500`, `coolDarkAnchor`, `patina500`), mapped into a `Theme(...)` value of semantic tokens. Palette constants are file-private; only the semantic `Theme` is exported. Two semantic tokens that share a color reference the same private constant — drift-proof. |
| Active theme | Held in a SwiftUI environment value. Runtime switching, no rebuild. v1 ships only `bellBronze`. Pro picker plumbing exists but is gated by entitlement and hidden when only one theme is registered. |
| Mockup HTML | Existing mockups stay at palette-level CSS variables (reference artifacts, not consumer code). New mockups going forward use semantic CSS var names mirroring the registry. No retrofit pass. |
| Out of scope (v1) | ANSI 16-color terminal palette theming (separate axis, deferred — Solarized/Dracula/Gruvbox-style alt palettes are a future Pro perk). Light mode. User-authored themes. Per-host theme overrides. |

**Full spec**: see `docs/superpowers/specs/2026-06-17-design-tokens-design.md`.

### Terminal feedback (bell)

| Topic | Decision |
|---|---|
| Visual bell | **Halo pulse** on the pane that rang. `bell.edge` token (Bell Bronze maps to `bronze500`), ~3–4pt blur radius outward from the pane border, single 700ms ease-in/out (250 / 200 / 250), 30–35% peak opacity. Outline only, no interior fill. No traveling sweep. |
| Rapid-bell behavior | Halo doesn't re-trigger from zero; holds at peak until the bell stream goes quiet for ~400ms, then fades. A busy `tput bel` loop produces one held glow, not strobing. |
| Multi-pane | Halo appears on **the pane that rang**, not always the focused pane. Lets background-task users see which pane finished. |
| Haptic | `UIImpactFeedbackGenerator(style: .soft)` — Apple's gentlest impact. Rate-limited ~500ms. Respects the App preferences → Haptics master toggle. |
| Defaults | Visual ON, haptic OFF. |
| Audio | **Rejected with prejudice.** No sound option, ever. iOS users expect notifications from notifications; a remote `\x07` playing a ding is alien. |
| Settings | App preferences → Terminal → Feedback. |

**Full spec**: see `docs/superpowers/specs/2026-06-17-terminal-feedback-design.md`.

### Terminal emulator scope

| Topic | Decision |
|---|---|
| Advertised TERM | `TERM=xterm-256color` + `COLORTERM=truecolor`. 256-color baseline, opportunistic 24-bit rendering when apps emit `\x1b[38;2;R;G;Bm` / `\x1b[48;2;R;G;Bm`. Same as Blink / Termius / Prompt 3 / iTerm2 / Alacritty. |
| OSC 52 (clipboard) | **Allowed by default, per-host toggle to disable.** `semicolyn.osc52.allow` in the schema, default `true`. Disabled means the write sequence is parsed and dropped silently. **Read sequences (`\x1b]52;c;?\x07`) never honored regardless of the toggle** — sending the user's clipboard to a remote is a separate boundary v1 doesn't cross. |
| OSC 0/2 (title) | Captured per window, surfaced only in the **Esc-pill picker Live group as a dim suffix** (`build-01 — ~/src/semicolyn`). Title truncates first, window name never. Nowhere else. |
| Mouse mode | **Hybrid.** Modes 1000 / 1002 / 1003 / 1006 / 1015 supported. In a mouse-active pane: taps forward as mouse events (SGR encoding), drag forwards as motion, two-finger scroll forwards as wheel events. **Cursor halo and iOS long-press selection auto-suspend in that pane only.** Bronze 4pt indicator at the pane's top-right interior corner. All other gestures (keybar, Esc pill, etc.) work. Mouse mode is per-pane. |
| Closed-set policy | Semicolyn's negotiation list contains only classified algorithms / sequences. New ones wait for an app update. |
| Out of scope (v1) | Bracketed paste (likely-add), Sixel / iTerm2-inline-image / Kitty graphics, OSC 8 hyperlinks. |

**Full spec**: see `docs/superpowers/specs/2026-06-17-terminal-emulator-scope-design.md`.

### Terminal UX additions

| Topic | Decision |
|---|---|
| Font size | Pinch-to-zoom changes the active pane's font size (lifetime of window). App preferences → Terminal → Font size slider, 9–24pt in 1pt increments, default **13pt**. Hardware shortcuts `⌘+` / `⌘-` / `⌘0`. Predictor strip + keybar **do not** scale (fixed at system text sizes for tap-target reliability). |
| URL tap-to-open | Auto-detect `http://`, `https://`, `ssh://`. Brief underline on touch-down confirms tappable; **lift within 250ms and ≤10pt drift opens**. `ssh://` opens host picker prefilled. Wrapped URLs join across the row break only when first part ends mid-token. Suppressed in mouse-mode panes. |
| Cursor | Three styles: **Block** (default), Underline, Bar. **Blink off** by default. DECSCUSR (`\x1b[<n> q`) honored — vim's runtime cursor-shape sequences temporarily override per pane. Cursor color uses `terminal.fg` token. |
| Scrollback | tmux mode: tmux owns `history-limit`. Raw-PTY mode: default **5000 lines per pane**, slider to 1000 / 2000 / 5000 / 10000 / unlimited (with memory caveat for unlimited). |
| Resize policy | `SIGWINCH` on visible-grid change incl. rotation (portrait↔landscape↔upside-down). Debounced to ~10Hz. Scrollback reflows; selection translates; mouse coords translate. iPhone-landscape-with-keyboard-up is documented as cramped, not compensated for. |
| Port-forward status | Static-config forwards surface in the Esc-pill picker Live row as expandable rows with green / red status dot + inline toggle to disable without disconnecting. No banner for failures (per-forward, not per-connection). Ad-hoc forwards (without editing the host record) deferred to v1.5+. |
| Settings home | App preferences → Terminal: Font size · Cursor · Scrollback (raw-PTY mode) · Feedback. |

**Full spec**: see `docs/superpowers/specs/2026-06-17-terminal-ux-additions-design.md`.

### SSH host-key trust UX

| Topic | Decision |
|---|---|
| Default policy | `strictHostKeyChecking = ask`. Explicit user confirm on first trust, explicit user confirm on key change. Tier 2 schema lets a power user set `accept-new` or `no` per host. |
| First-trust modal | Host label + key type + SHA256 fingerprint + body line ("Verify this matches what your administrator gave you"). Actions: **Trust & Connect** (primary, bronze) / Cancel. No biometric — device unlock is the gate. |
| Mismatch modal | Red header strip ("⚠ Host key changed"). Body shows Last seen vs Now offering fingerprints. Three actions: Cancel · Edit host (for "I aimed at the wrong server") · Replace key & connect (**requires secondary action-sheet confirm**, matches identity-delete pattern). |
| Per-algorithm | Each (host, key type) trusted independently. Key change on ed25519 doesn't invalidate the rsa-sha2-512 entry. |
| Storage | iCloud Keychain `known_hosts` per `host-config-model`. Multi-device sync means device B doesn't re-prompt for hosts device A already trusted. |
| Forget-and-retry path | Settings → Security → Host fingerprints → swipe-to-forget. After forget, the next connection fires first-trust as if brand new. |
| Out of scope (v1) | SSHFP DNSSEC, CA-signed host certs (separate concern from client cert auth), `known_hosts` bulk import. |

**Full spec**: see `docs/superpowers/specs/2026-06-17-host-key-trust-design.md`.

### SSH algorithm allowlist

| Topic | Decision |
|---|---|
| Model | **Four-tier closed-set.** Semicolyn only negotiates classified algorithms; unclassified wait for an app update. |
| Tier 1 — silent | Modern + post-quantum. KEX: `sntrup761x25519`, `mlkem768x25519`, `curve25519-sha256`, `ecdh-nistp{256,384,521}`, `dh-group{16,18}-sha512`. HostKey: `ed25519`, `rsa-sha2-{512,256}`, `ecdsa-nistp{256,384,521}` + their cert variants. Cipher: `chacha20-poly1305`, `aes-gcm`, `aes-ctr`. MAC: SHA-2 with ETM preferred. |
| Tier 2 — per-host opt-in, no warning | `semicolyn.allowLegacyAlgorithms`. Adds: `dh-group14-sha256`, `dh-gex-sha256`, `aes-cbc`. |
| Tier 3 — per-host opt-in, **warns every connect** | `semicolyn.allowDeprecatedAlgorithms`. Adds: `dh-group14-sha1`, `dh-gex-sha1`, `ssh-rsa` (SHA-1 + cert variant), `hmac-sha1`. First connect with Tier 3 = modal; subsequent = persistent amber banner reusing the expanded-template chrome. |
| Tier 4 — never offered | `arcfour*`, `3des-cbc`, `blowfish-cbc`, `cast128-cbc`, `hmac-md5`, `ssh-dss`, `dh-group1-sha1`. No toggle, no override path in v1. |
| Override granularity (v1) | Two per-host toggles. Fine-grained per-algorithm control (Tier 3 host-config schema option) stays deferred to v1.5+. |
| Maintenance | Review triggers baked into the spec: every OpenSSH major release, every Semicolyn major release, on any published practical attack. No separate process doc. References: Mozilla SSH guidelines, OpenSSH release notes, NIST SP 800-52 / 800-57. |

**Full spec**: see `docs/superpowers/specs/2026-06-17-ssh-algorithms-design.md`.

### SSH certificate auth (client-side, v1)

| Topic | Decision |
|---|---|
| Scope | Client-side cert presentation. Semicolyn does **not** issue, sign, or generate certs — that's the user's CA's job. |
| Schema | Identity gains optional `cert.{blob, cachedMetadata}`. Additive; existing records without `cert` unchanged. `cachedMetadata` regenerated on import. |
| Import | The existing "Import existing" tab of the identity half-sheet gains an optional **Certificate (optional)** row below the private-key field. Validates that the cert's underlying pubkey matches the imported key; Save disabled on mismatch. |
| Identity detail | New collapsible **Certificate** section: keyId, principals, validity window, CA fingerprint, critical options, extensions. `cert` chip on the identity list + amber `expires Nd` / red `expired` chip when within 14 days. |
| Auth flow | Cert present + not expired → `<cert> + <key>` to the SSH stack. Cert present + expired → connect refused; **no silent fallback** to bare key (would surprise the user — their CA-signed identity suddenly auths as a different user). No cert → existing bare-key behavior. |
| Algorithm allowlist intersection | Cert variants of currently-allowed signature algos are in Tier 1 (`ed25519-cert-v01`, `rsa-sha2-{512,256}-cert-v01`, `ecdsa-nistp{256,384,521}-cert-v01`). `ssh-rsa-cert-v01` is behind the Tier 3 toggle. |
| `forwardAgent` removal | **`forwardAgent` removed entirely from the schema.** Semicolyn does not support agent forwarding. Multi-hop via `ProxyJump` (already in Tier 1). Git-on-remote: deploy keys or session-scoped creds. In-app ephemeral agent deferred to v1.5+ if demand warrants. |
| Out of scope (v1) | Rotation wizard (v1.5 alongside `ssh-copy-id`), auto-renewal from CA APIs, Semicolyn-side cert generation, per-host cert overrides, PEM/DER format conversion. |

**Full spec**: see `docs/superpowers/specs/2026-06-17-ssh-cert-auth-design.md`.

### Jump-host chain authentication

| Topic | Decision |
|---|---|
| Hard constraint | SE `anyUse` policy requires a fresh biometric per signing op. Cannot be coalesced. A chain with two `anyUse` hops will, by necessity, prompt twice. UX is framing around an unavoidable fact. |
| 0 or 1 `anyUse` in chain | **Silent.** No summary modal. Single-prompt case is expected behavior. |
| ≥2 `anyUse` in chain | **Pre-flight summary modal** before any socket opens. Lists target + each `anyUse` hop with its identity label. Continue / Cancel. After Continue, Face ID prompts fire serially as each hop authenticates. |
| Mid-chain cancellation | User cancels iOS-native biometric → Semicolyn closes the in-flight SSH socket and any earlier-hop sockets, marks the connection failed, fires the existing connect-failed banner with "Authentication cancelled at hop {n}." |
| Partial-success state | None. A chain either fully establishes or fully fails. |
| Caching | None. No "don't ask again" affordance. The whole point of `anyUse` is no caching. |

**Full spec**: see `docs/superpowers/specs/2026-06-17-chain-auth-design.md`.

### tmux session naming + multi-device

| Topic | Decision |
|---|---|
| Naming | `semicolyn-<accountHash>` where `accountHash` = first 8 hex chars of SHA-256 over the iCloud-Keychain-backed CloudKit key already used by the storage backbone. Stable across reboots / reinstalls; identical across devices on the same Apple ID; different across different Apple IDs. |
| Default behavior | **Shared session per Apple ID.** Devices signed into the same Apple ID share the session — start vim on iPad, switch to iPhone, keep typing. Both clients attached via `tmux -CC`; tmux mirrors. |
| New picker swipe actions | **Disconnect & end session** kills server-side tmux (action-sheet confirm) and boots other attached devices with a "Session ended from another device" banner. **Connect in new session** opens a one-off `semicolyn-<accountHash>-<short-uuid>`; produces a separate picker entry labeled `<host> · alt N`. |
| Per-host configurability | None. Naming convention is the same on every host. |
| Raw-PTY mode | Opts out — no session abstraction; each device's connection is independent. |
| Stale alt sessions | Persist on the host until manually ended (Disconnect & end session, or raw SSH + `tmux kill-session`). **No automatic GC in v1.** |
| Apple ID change | Old session orphans on the host; new Apple ID gets a new `accountHash`. Documented in Tips & Gestures. |

**Full spec**: see `docs/superpowers/specs/2026-06-17-tmux-session-design.md`.

### Screen-capture protection

| Topic | Decision |
|---|---|
| Posture | Calibrated for SSH-client norms, **not banking-app paranoia**. Terminal recording / mirroring is a common legitimate use case (screencasts, demos, pair programming). |
| App-switcher overlay | **Always on, no toggle.** On background, swap to a Semicolyn-branded view (bronze mark on `surface.bg`) before iOS captures the switcher thumbnail. Cheap, standard, no downside. Differentiator vs Blink / Prompt 3. |
| Screen-recording blank | App preferences → Security toggle, **default OFF**. When on and `UIScreen.isCaptured` is true, terminal panes blank with a small caption; keybar / predictor strip / chrome stay visible. The user who *wants* to mirror to TV is the default; the user who *needs* the protection flips the toggle. |
| Screenshot toast | **Skipped.** iOS provides detection but not blocking; a toast that says "you can't actually prevent screenshots" is performative. |
| Privacy framing | About & Help → Privacy is honest about what Semicolyn does and what iOS will not let any app do. |
| Out of scope (v1) | Secure-text-field screenshot hacks (fragile, defeats user expectations). Per-pane sensitive flag (v1.5+ candidate; explicitly **not** a Pro perk — Pro is cosmetic, not security). |

**Full spec**: see `docs/superpowers/specs/2026-06-17-screen-capture-protection-design.md`.

### Privacy statement

| Topic | Decision |
|---|---|
| Placement | About & Help → Privacy statement (full-screen push, scrollable plain prose). Same content mirrored to the App Store privacy section and `semicolyn.app/privacy`. In-app page is canonical. |
| Headline | Semicolyn collects **nothing**: no analytics, no telemetry, no crash reporting, no usage tracking, no advertising identifiers, no third-party SDKs that collect any of the above. No Semicolyn account. |
| Storage | Documents the backbone: iCloud Keychain / Secure Enclave for identities; CloudKit Private DB + client-side AES for host records / macros / keybar customizations / known-hosts metadata; local-only for recents and live state. |
| iCloud sync | Per-category toggles (macros / keybar customizations / predictor sketches). E2EE-equivalent for all synced categories regardless of Advanced Data Protection setting. |
| Third parties | None. Only network requests are SSH/mosh to user-configured hosts plus iOS-level iCloud sync. |
| Screen capture | Matches the screen-capture-protection spec. Honest about iOS's lack of a screenshot-block API. |
| Identity survival | iCloud Keychain identities survive reinstall via sync; SE identities are bound to this device and this install and are destroyed on uninstall. |
| Rating | 17+ (App Store) because Semicolyn connects to arbitrary remote servers we cannot moderate. |
| Change notice | Material data-handling changes ship with a one-time in-app notice at next launch. |
| Contact | `hello@semicolyn.app`. |
| Out of scope (v1) | Localized translations (English only in v1), region-specific phrasing (GDPR-/CCPA-specific carve-outs — substance covered by the no-collection posture), cookie policy (no website state). |

**Full spec**: see `docs/superpowers/specs/2026-06-17-privacy-statement-design.md`.

---

## Deferred / for future conversation

- **Keyboard / input UX (remaining sub-topics)** — predictor, keybar scope, keybar interaction model, default slots, modifier behavior, arrow cluster, customization, context detection, per-context layouts, function keys, degraded mode, **external keyboard**, and **iPad scope** are now locked. Still open:
  - **v2 custom inputView** — if/when promoted from v1.5+ feedback, design the letter-to-alt-symbol mapping and the held-modifier interaction.
- **iPad-native surfaces** — multi-window via `UISceneSession` (Stage Manager / Split View), landscape-specific layouts (wider keybar, side-by-side panes as a layout option), trackpad / pointer integration reconciling Magic Keyboard pointer with the touch-oriented cursor halo. v1 ships iPad-compatible (single window, size-class-aware) per `docs/superpowers/specs/2026-06-17-ipad-scope-design.md`.
- **In-app hardware-Esc rebind** — deferred to v1.5; v1 uses iOS's system-wide Caps-as-Esc remap. Per `docs/superpowers/specs/2026-06-17-external-keyboard-design.md`.
- **Custom Cmd-shortcut remapping** — deferred to v1.5+; v1 ships a fixed 18-action map.
- **Scrollback navigation shortcuts (⌘Home / ⌘End)** — deferred; revisit when scrollback ergonomics get their own pass.
- **Layout templates for panes** (`even-horizontal`, `even-vertical`, `main-horizontal`, `main-vertical`, `tiled`) — deferred to v1.5.
- **SSH identity / cert rotation wizards** — depends on `ssh-copy-id` auto-install (also v1.5). Cert auth ships in v1, but rotation flow waits for the auto-install primitive per `2026-06-17-ssh-cert-auth-design.md`.
- **In-app ephemeral SSH agent** — supports `forwardAgent`-style use cases. Removed from v1 schema; revisit in v1.5+ if demand warrants. Multi-hop bastions use `ProxyJump` (already in v1).
- **Ad-hoc port forwards** — adding a temporary tunnel at runtime without editing the host record. v1 supports only host-config-declared forwards. v1.5+.
- **ANSI 16-color terminal palette theming** — Solarized / Dracula / Gruvbox-style alt palettes. Likely a future Pro perk alongside alternative color themes. Separate axis from the UI chrome theming plumbed in `2026-06-17-design-tokens-design.md`.
- **OSC 8 hyperlinks** (the "real" terminal hyperlink protocol). Useful for `ls --hyperlink` output but adds parser + rendering surface that v1 doesn't need. v1.5+.
- **Bracketed paste mode** (`\x1b[?2004h`). Likely-add to a future minor release; relevant for shells distinguishing typed vs pasted input.
- **Image protocols** (Sixel / iTerm2 inline / Kitty graphics). Out of v1; v1.5+ if demand surfaces.
- **Per-pane sensitive flag** for screen-capture protection (blank only marked panes during capture). v1.5+ candidate; explicitly not a Pro perk.

### Rejected from v1 (v1.5+ candidates pending demand)

- **Importing from `~/.ssh/config`** — debated and dropped. The friction of getting the file onto iOS roughly equals manual entry, and Semicolyn's host CRUD form is fast. Fallback plan if users grumble: a simple "paste comma/newline-separated hostnames" bulk-add tool. Full import (mapping rules, Match/Include, IdentityFile resolution, post-import review) revisitable if real demand surfaces.
- **Exporting to `~/.ssh/config`** — dropped alongside import. Lossy roundtrip with Semicolyn extensions; low priority. Revisit only after import is reconsidered.
