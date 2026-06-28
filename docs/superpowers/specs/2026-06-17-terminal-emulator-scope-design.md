# Terminal emulator scope

**Date:** 2026-06-17
**Status:** Locked
**Resolves:** punch-list item #1 in `docs/final-review-punchlist.md`. Five sub-decisions; bell handling lives in [[2026-06-17-terminal-feedback-design]], the other four are below.

## Goal

Lock the terminal-emulator-facing behavior that an SSH stack pick partly depends on: what `TERM` Semicolyn advertises, what subset of escape sequences it implements, and how the user-facing surfaces (clipboard, title, mouse) compose with the rest of the design.

## Advertised TERM

`TERM=xterm-256color`. Same as Blink, Termius, Prompt 3, iTerm2, Alacritty.

- 256-color palette is the baseline.
- **Truecolor (`\x1b[38;2;R;G;Bm` and `\x1b[48;2;R;G;Bm`) is rendered opportunistically** when an app emits it. Modern shells, vim, tmux, bat, fzf, etc. all do — they probe `COLORTERM=truecolor` (which Semicolyn also sets) and emit 24-bit sequences.
- No fallback rewrite of true-color sequences to 256-color. If an app emits them, they render in 24-bit.

`COLORTERM=truecolor` is set as an environment variable in addition to `TERM`.

## OSC 52 — remote clipboard writes

**Policy:** allowed by default, per-host toggle to disable.

A script running on the remote can push text into the iOS clipboard via `\x1b]52;c;<base64>\x07`. This is what makes vim's `set clipboard=unnamed` reach the iOS clipboard, what `tmux save-buffer -` style scripts depend on, what `pbcopy`-replacement wrappers use.

- **Host-config field:** `semicolyn.osc52.allow: bool`, default `true`. Matches the `semicolyn.*` extension namespace established in [[2026-06-15-host-config-model-design]].
- **Host-CRUD surface:** single checkbox in the "Semicolyn behavior" section labeled **"Allow remote clipboard writes (OSC 52)"** with a one-line caveat: *"A program on this host can update your iOS clipboard. Turn off for untrusted hosts."*
- **When disabled:** the sequence is parsed and dropped. No error to the remote, no visible feedback in Semicolyn. The user can still copy by hand (long-press magnifier, `⌘C`, banner "Copy diagnostics").
- **No global toggle.** Per-host granularity is correct: clipboard trust is host-specific, not session-wide.
- **No first-use toast.** Default-allow with a quiet enable matches the user experience power users want. Security-conscious users flip the per-host toggle off; everyone else gets `yy` working.

### OSC 52 read sequences

The OSC 52 spec also defines a *read* sequence (`\x1b]52;c;?\x07`) that asks the client to send its clipboard back to the remote. **Semicolyn never honors this**, regardless of the `allow` toggle. The toggle controls writes only. Reads silently no-op. Sending the user's clipboard to a remote on demand is a separate security boundary that v1 does not cross.

## OSC 0 / OSC 2 — terminal title

**Captured per window, surfaced only in the Esc-pill picker Live group as a dim suffix.**

- Semicolyn tracks the most recent title emitted via `\x1b]0;<title>\x07` (icon + title), `\x1b]1;<title>\x07` (icon only — folded into title in Semicolyn), and `\x1b]2;<title>\x07` (title only).
- The Live-group picker row reads `build-01 — ~/src/semicolyn` with the title in dim text after an em-dash.
- **Truncation:** if `<window-name> + " — " + <title>` exceeds the row width, truncate the title with an ellipsis. Window name is never truncated.
- **Nowhere else.** No pane header, no window-switcher hover state, no banner injection.
- **Title lifetime:** the most recent title is held until the window is closed. Reconnect-with-tmux-control-mode restores the last-known title from server state if available; otherwise the title field is empty until the remote re-emits one.
- **Empty / control-character titles** are rejected; the row falls back to just the window name.

## Mouse mode passthrough

**Hybrid model:** mouse reporting is supported, and a pane with mouse mode active auto-suspends the cursor-placement halo and iOS-native long-press selection *for that pane only*.

### Supported modes

| Sequence | Mode |
|---|---|
| `\x1b[?1000h` / `l` | X11 mouse, press/release |
| `\x1b[?1002h` / `l` | X11 mouse, press/release + drag |
| `\x1b[?1003h` / `l` | X11 mouse, any-event (motion) |
| `\x1b[?1006h` / `l` | SGR extended encoding (modern, recommended) |
| `\x1b[?1015h` / `l` | URXVT extended encoding (legacy, accepted but not preferred) |

When any of these enable modes is received, the pane enters **mouse-active** state. The disable counterpart returns it to **mouse-inactive**.

### What happens in a mouse-active pane

- **Taps in the pane forward as mouse events** to the remote in SGR encoding (or URXVT if `?1015` was negotiated). Coordinates are translated from screen points to terminal cells.
- **Drag in the pane forwards as motion events** (under `?1002` / `?1003`).
- **Two-finger scroll** in the pane forwards as scroll-wheel events (`Button 4` / `Button 5`).
- **The cursor-placement halo gesture is suspended.** A tap doesn't grow a halo; it's a mouse click.
- **iOS long-press selection is suspended.** Long-press doesn't engage the magnifier; it's whatever the remote app makes of a long press.
- **All other gestures continue to work:** keybar slots, Esc pill, Pad, window/pane switching, predictor strip. Mouse mode is pane-content-local.

### Visual indicator

A small bronze dot (~4pt, `Color.theme.accent.primary` at 40% opacity) appears at the top-right interior corner of any mouse-active pane. Tells the user why their long-press isn't selecting. The indicator disappears when mouse mode is disabled.

### Escape path

If a user needs to copy text from a mouse-active pane:
- **Easiest:** disable mouse mode in the remote app (`set mouse=` in vim, `q` to quit `htop`).
- **In-app:** the keybar's Esc pill long-press picker gains no special row for this; the indicator is informational, not actionable. Adding a "force-disable mouse mode for this pane" action is deferred — users would want it but the v1.5+ threshold catches it without v1 cost.

### Multi-pane composition

Mouse mode is **per-pane**. One pane in `htop`, another pane in a shell — the shell pane still has cursor halo + long-press selection. The mode indicator only appears on panes that are actually mouse-active.

### Already-established interaction

The terminal-area window-switching swipe already auto-suspends "when focused pane has mouse mode active" per the locked window-switching decisions. That stays.

## Out of scope (v1)

- **Bracketed paste mode** (`\x1b[?2004h`). Probably should be supported (it's how shells distinguish typed vs pasted input — relevant for `Ctrl-V`-without-bracketing surprises). Marked as a future addition to this spec rather than designed now.
- **Sixel / iTerm2 inline image protocol / Kitty graphics protocol.** Out of scope. Semicolyn is a working SSH client first; image protocols are v1.5+ if demand surfaces.
- **Hyperlink protocol** (`\x1b]8;;<url>\x07`). Deferred. Worth doing eventually — terminal links are useful — but needs its own design pass on iOS routing semantics.
- **REP (CSI b)** and other rare sequences. Implementations are stack-dependent; whatever the chosen stack does is acceptable v1.

## Cross-spec consequences

- [[2026-06-15-host-config-model-design]] — gains the `semicolyn.osc52.allow` field in the `semicolyn.*` extension namespace. Default `true`.
- [[2026-06-15-host-crud-design]] — gains an "Allow remote clipboard writes (OSC 52)" checkbox in the "Semicolyn behavior" section.
- [[2026-06-15-multi-connection-switching-design]] — Live-group picker rows gain a dim title suffix (no schema change; the title field is runtime-only and not persisted).
- The "auto-suspend window-switch swipe when mouse mode active" line is now fully grounded by this spec (mouse mode is a real spec'd state, not a hypothetical).

## Related

- [[2026-06-17-terminal-feedback-design]] — bell handling, the other sub-decision from punch-list item #1.
- [[2026-06-17-design-tokens-design]] — `accent.primary` token used for the mouse-active indicator.
- [[2026-06-15-host-config-model-design]] / [[2026-06-15-host-crud-design]] — host-config schema and CRUD surface that gains the OSC 52 toggle.
