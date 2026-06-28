# Terminal UX additions — font size, URL tap, cursor, scrollback, resize, forwards

**Date:** 2026-06-17
**Status:** Locked
**Resolves:** post-final-review gap surfaced during walk-through — basic terminal-client features that no other spec covered. Bundled because each is small and they share a Settings → Terminal home.

## Scope

Six v1 features that any serious iOS SSH client must have but no Semicolyn spec mentioned:

1. Font size (with pinch-zoom, settings slider, hardware shortcuts)
2. URL tap-to-open
3. Cursor style + blink
4. Scrollback buffer policy
5. Resize policy on keyboard / rotation
6. Port-forward runtime status surface

## Settings home

All six features live under **App preferences → Terminal**, a new sub-section between Keybar and iCloud sync per [[2026-06-16-settings-sub-screens-design]]. Replaces the absence of a Terminal section; previously [[2026-06-17-terminal-feedback-design]] introduced **App preferences → Terminal feedback** as a sibling.

Reconcile: **rename Terminal feedback to Terminal**, and put the bell/feedback settings as a sub-section within. New layout:

```
App preferences
  Keybar                  >
  Terminal                >
    Font size
    Cursor
    Scrollback (raw-PTY mode)
    Feedback
      Visual bell
      Bell haptic
  iCloud sync             >
  Haptics                 >
```

## Font size

**Pinch-to-zoom on a pane** changes that pane's font size. iOS-native gesture; no conflict with the cursor-placement halo (which uses single-finger drag) or window-switching swipe (single-finger horizontal).

**App preferences → Terminal → Font size** slider sets the global default: range **9pt to 24pt** in 1pt increments. Default: **13pt** (matches the existing mockups' terminal-cell font).

**Hardware shortcuts** (gated on a HW keyboard, per [[2026-06-17-external-keyboard-design]]):

- `⌘+` — increase by 1pt (clamp at 24)
- `⌘-` — decrease by 1pt (clamp at 9)
- `⌘0` — reset to global default

Add these to the Cmd-shortcut map in `2026-06-17-external-keyboard-design.md` — was deferred there because "no font-size feature yet."

**Per-pane vs global.** Per-pane *override* persists for the lifetime of the window (pinch-zoom changes that window's size; closing and reopening loses it). The global setting is the default for new panes. No per-host font-size in v1; v1.5+ if anyone asks.

**Predictor strip + keybar** do *not* scale with terminal font. They remain at fixed system-text sizes for tap-target reliability.

## URL tap-to-open

Auto-detect URLs in rendered terminal output.

**Detected schemes (v1):** `http://`, `https://`, `ssh://`.

**Visual.** No persistent highlight in scrollback. On touch-down over a URL, a brief subtle underline appears under the URL — confirmation that it's tappable. Underline color: `Color.theme.accent.primary`.

**Lift to open.**
- **`http(s)://`** → opens in iOS's default browser handler (Safari unless the user has set another default).
- **`ssh://`** → opens the host picker prefilled with the parsed components (`ssh://user@host:port` → host CRUD form in *create* mode with `user`, `hostName`, `port` populated). User saves and connects in two taps.

**Gesture coexistence — touch-down decision pattern.** A tap that lifts on a URL within **250ms and ≤10pt drift** opens the URL. Longer touch, larger drift, or multi-touch falls through to the existing gestures (cursor halo, iOS long-press magnifier selection, mouse-mode pass-through).

**Wrapped URLs.** When a URL is split across two visual rows because the terminal wrapped it, join the parts across the row break **only when** the first part ends mid-token (no whitespace) and the second part starts in column 0. Otherwise treat them as separate strings — don't gamble.

**Mouse-mode panes.** URL tap is suppressed. Taps go through as mouse events per the [[2026-06-17-terminal-emulator-scope-design]] hybrid model.

## Cursor style + blink

Standard terminal config.

**Style options** (App preferences → Terminal → Cursor):
- **Block** *(default)* — solid filled cell
- **Underline** — bottom-edge bar
- **Bar** — left-edge vertical line

**Blink:** off by default. Toggle ON makes the cursor blink at ~530ms cycle.

**Global only in v1.** Per-pane settings deferred — vim users who want shape-per-mode get that via the next item.

**DECSCUSR honored.** When a remote app emits `\x1b[<n> q` (vim's `set guicursor`, etc.), the cursor style **temporarily** overrides the user's preference for that pane until the app resets it (`\x1b[0 q`) or the pane closes. Sequence mapping per the standard:

| Sequence | Effect |
|---|---|
| `\x1b[0 q` | reset to user default |
| `\x1b[1 q` | blinking block |
| `\x1b[2 q` | steady block |
| `\x1b[3 q` | blinking underline |
| `\x1b[4 q` | steady underline |
| `\x1b[5 q` | blinking bar |
| `\x1b[6 q` | steady bar |

**Cursor color** uses `Color.theme.terminal.fg`. No separate cursor-color setting in v1.

## Scrollback buffer

Two distinct modes:

### tmux control-mode panes

tmux owns the scrollback (`history-limit` in tmux configuration). Semicolyn reads from tmux when the user scrolls past the visible region. **No Semicolyn-side setting**; tmux is the source of truth. Defaulting tmux's `history-limit` is up to the user's `.tmux.conf` on the host.

### Raw-PTY (degraded) mode

Semicolyn is the sole owner of scrollback.

- **Default:** 5000 lines per pane.
- **User setting:** App preferences → Terminal → Scrollback (raw-PTY mode) — slider with five presets: **1000 / 2000 / 5000 / 10000 / unlimited**.
- The "unlimited" option shows a small caveat: *"Bounded only by available memory; iOS may terminate the app if memory pressure builds."*
- Lines older than the limit are evicted FIFO. Eviction is silent.
- Per-pane (each pane has its own buffer), not per-host.

**Memory cost note.** A line averages ~200 bytes (text + style runs), so 5000 lines is ~1MB per pane. 10000 is ~2MB. Honest, not alarmist.

## Resize policy

When the visible cell grid changes — keyboard show/hide, device rotation, pane split/merge, font-size change — Semicolyn sends a window-change to the SSH stack, which forwards `SIGWINCH` to the remote `pty`.

- **Debounced** to ~10Hz during rotation / resize animations. Avoids spamming the remote with intermediate sizes.
- **Scrollback re-flows.** Existing scrollback wraps to the new column count. No content is lost.
- **Active selection survives.** Anchor coordinates are translated to the new grid.
- **Mouse-mode coordinates translate** cleanly — the new grid size is what the remote app sees, so coords map without remote-side fixup.

**Device rotation** is the same code path. Portrait ↔ landscape ↔ upside-down (iPad) triggers a grid change → `SIGWINCH` → remote redraw. The keybar adapts via size-class branching (no separate spec; [[2026-06-17-ipad-scope-design]]'s "all v1 mockups must render reasonably at iPad size" constraint covers this).

**iPhone-landscape caveat.** With the software keyboard up in iPhone landscape, the visible cell rows drop dramatically — sometimes to single digits. That's a real ergonomic constraint, not a Semicolyn bug; we don't compensate. Documented in Tips & Gestures as "for landscape reading, dismiss the keyboard."

**Implementation note for the SSH-stack pick.** The chosen stack must expose window-change requests at any time, not just session open. `libssh2`: `libssh2_channel_request_pty_size`. Citadel / SwiftNIO SSH: equivalent. `Network.framework` SSH: unverified at spec time; if it doesn't expose runtime resize, the stack is the wrong pick.

## Port-forward runtime status

The host-config schema already supports `localForward`, `remoteForward`, and `dynamicForward`. This spec covers the runtime surface.

### Static-config forwards

When the connection establishes, Semicolyn requests each declared forward. Their status is surfaced in the **Esc-pill long-press picker Live row** — expanding the row reveals a small "Forwards" sub-section listing each forward on one line:

```
  ● build-01.example.com          (Live)
    └─ Forwards
        localhost:8080 → server:80          ●  ─
        localhost:5432 → db.internal:5432   ●  ─
        localhost:9090 → server:9090        ●  ─
        SOCKS :1080                         ●  ─
```

- `●` green = active and healthy
- `●` red = failed to establish (port-in-use, remote refused, etc.) — tap for the underlying error string
- `─` is an inline toggle; tap to disable a forward without disconnecting the session. Tapping again re-establishes.

**Order:** local, remote, dynamic — in the same order they appear in the host config.

**No banner for forward failures.** Inline status icon only. Forward failures rarely block the session itself, and surfacing them at the picker matches where the user goes to manage them. Avoids banner noise.

### Ad-hoc forwards (v1.5+)

Adding a temporary tunnel at runtime without editing the host record is **deferred to v1.5+**. v1 supports only forwards declared in the host config. Users with a one-off need edit the host record and reconnect.

This keeps v1's surface small. The picker's per-row layout has room for the "+ Add forward" affordance when v1.5 lands; no rework needed.

## Cross-spec consequences

- [[2026-06-17-terminal-feedback-design]] — Settings location shifts: **Terminal feedback** sub-section becomes a child of **Terminal**, alongside Font size / Cursor / Scrollback. No content change.
- [[2026-06-16-settings-sub-screens-design]] — App preferences gains a **Terminal** sub-section.
- [[2026-06-17-external-keyboard-design]] — Cmd-shortcut map gains `⌘+`, `⌘-`, `⌘0` for font size. Was deferred there with the note "no font-size feature yet."
- [[2026-06-17-terminal-emulator-scope-design]] — URL tap honors the mouse-mode auto-suspend pattern already established. DECSCUSR is new spec content but compatible with the existing escape-sequence policy.
- [[2026-06-15-multi-connection-switching-design]] — Esc-pill picker Live row gains an expandable Forwards sub-section. Schema unchanged; runtime UI only.
- [[2026-06-15-host-config-model-design]] — no schema change; existing `localForward` / `remoteForward` / `dynamicForward` fields drive the runtime surface.
- [[2026-06-14-degraded-mode-design]] — scrollback buffer in raw-PTY mode now has explicit policy (was implicit before).

## Out of scope (v1)

- **Per-pane / per-host font size override persistence.** Pinch-zoom within a window persists for window lifetime; nothing more.
- **Cursor color** — `terminal.fg` is the color. v1.5+ if anyone asks.
- **OSC 8 hyperlinks** (`\x1b]8;;<url>\x07<text>\x1b]8;;\x07`). The "real" terminal hyperlink protocol. Deferred — useful for `ls --hyperlink` output but adds parser and rendering surface that v1 doesn't need. v1.5+.
- **Hyperlink long-press preview** (Safari-style URL peek). Out of v1 — `lift-to-open` is the entire interaction.
- **Ad-hoc port forwards.** v1.5+.
- **mailto: and other URI schemes.** v1 covers `http(s)` and `ssh`. Add more when demand surfaces.
- **Predictor strip + keybar font scaling.** Fixed at system text sizes for tap-target reliability.

## Related

- [[2026-06-17-terminal-emulator-scope-design]]
- [[2026-06-17-terminal-feedback-design]]
- [[2026-06-17-external-keyboard-design]]
- [[2026-06-17-ipad-scope-design]]
- [[2026-06-15-host-config-model-design]]
- [[2026-06-15-multi-connection-switching-design]]
- [[2026-06-16-settings-sub-screens-design]]
- [[2026-06-14-degraded-mode-design]]
