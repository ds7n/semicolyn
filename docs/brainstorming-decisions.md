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
| Name | **Glymr** — Old Norse for "echo, resonance, ringing sound." Names what the product does (the predictor echoes your vocabulary back; commands ring across distance to a remote shell), not the role of who uses it. Pronounced /ˈglɪmr/ — "GLIM-er." Lowercase `glymr` in path / code contexts; capitalized `Glymr` as the proper noun. |
| Goal | Solve a personal annoyance (CLI / AI / security adjacent) |
| Differentiator | Make the iOS keyboard pleasant for terminal work |
| Security posture | Security-first: SE-default for new identities, per-host auth policy, no telemetry, local audit log, public-key always copyable |
| Brand palette | **"Bell bronze"** — bronze accent (`#D49A5C`) on cool-near-black (`#0E1116`), verdigris patina (`#5FA89C`) as success/tension color. Leverages the name's two readings (struck bell + glimmer-in-darkness). Avoids AI / terminal / Norse stereotypes. See `mockups/design-system.html`. |

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

### Snippets / macros (unified)

| Topic | Decision |
|---|---|
| Unified concept | **One concept: macro = a recorded sequence of input events.** Covers keystroke chords (`Ctrl+R`), literal strings (`kubectl `), mixed sequences (`Esc :wq Enter`), and tmux prefix combos. No separate "snippet" vs "macro" distinction. |
| Two surfaces | **Launcher** = searchable full list (flat, smart sort, toggle to disable). **Keybar** = pinned subset for one-tap access. |
| Optional placeholders | Placeholders + defaults + remembered last-used values per host are an optional per-macro property. Used by some launcher entries; usually unset on keybar items. |

### Keybar (accessory bar above iOS keyboard)

| Topic | Decision |
|---|---|
| v1 scope | **In-app accessory bar only.** iOS owns the letter keys; the 123 layer remains the fallback for any symbol not promoted to the keybar. Glymr owns the predictor strip + keybar pills + slots. |
| v2 question (deferred) | Custom `inputView` (Glymr-owned keyboard inside the app) — enables long-press alts on letter keys, held modifier chords, custom repeat rates, context-swap layouts. Not a system-wide keyboard extension. |
| Slot interaction | Three actions per slot: tap = primary, swipe-up = secondary, swipe-down = tertiary. Long-press = edit the slot (rebind, replace, pin a new macro). Each key shows the two swipe chars as small dim glyphs on the same key (top and bottom edges). |
| Modifier behavior | **Ctrl, Alt, Shift = sticky-for-one-keystroke.** Tap → armed for the next key, auto-disarms. **Ctrl additionally double-tap-to-lock** (Emacs chord case); tap again unlocks. Alt/Shift stay sticky-only (their swipe-based gestures don't support double-arming cleanly; iOS already provides caps-lock for Shift). Esc and Tab fire on tap (no sticky/toggle). |
| Arrow input | **Single Blink-style arrow-pad slot.** Touch and drag from center in any direction (↑↓←→) to fire that arrow. Replaces four discrete arrow keys. |
| Default slots (v0) | 10 slots: **core** (Esc, Ctrl/Alt/Shift, Tab, arrow-pad) + **convenience** (`/`, `\|`, `~`, `-`, `(`, `)`). Convenience slots are removable. Core slots are locked. Full layout: `mockups/keybar.html`. |
| Iteration plan | Defaults are a v0 best-guess. Public character-frequency data for shell typing on mobile doesn't exist. Plan: ship defensible defaults, make customization first-class, tune defaults in v1.5 from predictor's keystroke telemetry (with consent). |

### Window switching

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
| Engine | Probabilistic data structures (Count-Min Sketch for unigrams + bigrams, Bloom filter for membership). On-device, encrypted at rest, no cloud. |
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
| Bootstrap / auto-install | **Never.** Glymr does not drop binaries, run package managers, or sudo on user hosts. |
| Detection | Single `tmux -V` at connect; result decides `-CC` vs raw PTY. |
| What works in degraded mode | Connection, single shell, predictor, snippets, keybar (modifiers/arrows/Esc/Tab/Fn manual), iOS copy/paste, cursor placement, status banner. |
| What's off in degraded mode | Window pill, pane pill, context detection, function-key auto-engage. |
| Keybar layout (degraded) | Locked-left collapses left after pills are removed; no badge, no accent shift — pill absence is the indicator. |
| Connect-time banner | Reuses transient amber connection-status banner. Reoccurs every reconnect. No persistent chrome. |
| Suppression | **Per-host only.** Auto-offered as a one-tap action after 2–3 dismissals; global toggle rejected as a footgun. Per-host "Don't attempt tmux on this host" lives in connection settings (deferred). |
| Mid-session crash recovery | Drop to degraded immediately on same connection; show **persistent red banner** (the one documented exception to the transient-banner rule) with Reattach / Start new tmux / Dismiss. No auto-retry of `-CC`, no layout restoration, no false reassurance. |

**Full design**: see `docs/superpowers/specs/2026-06-14-degraded-mode-design.md`.

### Host management & settings access (entry point only — config model still deferred)

| Topic | Decision |
|---|---|
| Concurrency model | **Multiple simultaneous live connections.** Not single-foreground. |
| Top-level entry point | **Long-press Esc slot in the keybar** (~400ms). Opens picker sheet. Esc was previously a tap-only core slot; long-press was undefined — no overload, no conflict. |
| Visual hint | Small dim bronze **`≡`** glyph below the "Esc" label. Indicates "hold here for menu." |
| Engage feedback | Esc slot highlights bronze + scales slightly + light haptic on long-press engage. |
| Host chip / top bar | **None.** No persistent top-of-screen chrome for host status. Terminal extends right up to the DI safe-area edge. (Banner can still slide in from top when needed.) |
| Picker anchor | **Above the keybar** (near where the gesture happened), not top of screen. Keeps the user's eyes near their thumb. |
| Picker contents | **Live → Recent → + Connect to host… → ⚙ Settings.** Current host highlighted within Live group. |
| Definition of "live" | A connection is "Live" if it can be resumed **without re-auth**. Mosh stays live across backgrounding (server-side session). SSH stays live while foreground / in iOS bg grace. **SSH/mosh are unified in the UI** — user sees Live vs Recent, not protocol. Drops from Live → Recent happen automatically when the underlying session is killed. |
| Per-row swipe actions | **Live row:** `[Edit] [Disconnect]` (rightmost red; Disconnect closes session, keeps config, moves row to Recent). **Recent row:** `[Edit] [Delete]` (rightmost red; Delete removes the config entirely, with a confirmation prompt). |
| Per-row long-press | Context menu with the swipe actions **plus** Copy hostname, Duplicate, Connection details. |
| Banner placement | **Unchanged — banners stay at top of screen.** Independent of keyboard state. tmux-crash banner keeps action buttons in the banner itself (rare action, reach acceptable). |
| Settings entry | **Inside the picker sheet** as the last row. No separate settings button, gear icon, hamburger, or tab anywhere in the app. The picker is the **only** top-level handle. |
| Settings tree | Top level: **Hosts** (host config CRUD), **Identities & Keys** (SSH keypairs, biometric policy), **Security** (per-host auth policy, audit log, predictor pattern-exclude), **App preferences** (predictor, keybar, appearance), **About & Help**. |
| Editing a host (two paths) | (1) **Mid-session quick edit:** swipe row in picker → Edit. (2) **Deep curation:** Settings → Hosts → tap host → edit screen. |
| Dynamic Island handling rule | **A+C.** All top-edge chrome (chip-equivalents and banners alike) honors `safeAreaInsets.top` — placed flush below whatever the OS owns (DI / notch / status bar). Top-bar background tints around the DI so the cutout reads as part of our chrome rather than a hole. **No interactive UI in the flank** (Apple HIG, tap-collision). |
| Live Activities (DI background presence) | **Out of scope for v1.** Worth revisiting post-v1; chip's data model designed so a Live Activity could feed off it later. |

**Mockup**: see `mockups/host-management.html`. **Spec**: not yet written — the host config model itself (fields, identity refs, jump chains, port forwards, mosh/ssh, Tailscale routing, defaults inheritance), the CRUD flow, and the multi-connection switching semantics are still to brainstorm.

---

## Deferred / for future conversation

- **Keyboard / input UX (remaining sub-topics)** — predictor, keybar scope, keybar interaction model, default slots, modifier behavior, arrow cluster, customization, context detection, per-context layouts, function keys, and degraded mode are now locked. Still open:
  - **v2 custom inputView** — if/when promoted from v1.5+ feedback, design the letter-to-alt-symbol mapping and the held-modifier interaction.
- **Pill position customization** — left vs right in the keybar (handedness preference); a per-user setting. (Sub-item of the keyboard/input UX topic above.)
- **Settings / preferences surface (UI shape)** — entry point and top-level tree are locked (see Host management & settings access above); still open is the **detailed layout of each settings sub-screen** (App preferences, Security, etc.) — what controls live where, how nested, defaults, copy.
- **Host config model** — fields, defaults inheritance, identity references, jump-host chain shape, port forward representation, mosh/ssh toggle semantics, Tailscale routing. The data model the rest of the connection-management work hangs off. *Entry point and switching UI are locked; the config schema itself is the remaining work.*
- **Host CRUD flow** — create / edit / delete screens, validation, import/export (e.g., from `~/.ssh/config`), error states.
- **Multi-connection switching semantics** — what happens to the foreground connection when you switch? Does its tmux stay attached? Does mosh keep heartbeating? iOS background-task budget implications. *UI is locked; behavior under the hood is the remaining work.*
- **iPad navigation** — keybar pill model probably needs adaptation. iPad has more horizontal real estate; rethink whether pills should live elsewhere.
- **Layout templates for panes** (`even-horizontal`, `even-vertical`, `main-horizontal`, `main-vertical`, `tiled`) — deferred to v1.5.
- **iCloud sync scope** — hosts/snippets/identities — what syncs, what doesn't.
- **External keyboard support** — shortcut design for the hardware-keyboard case.
- **Monetization** — free / one-time / subscription / pro tier.
