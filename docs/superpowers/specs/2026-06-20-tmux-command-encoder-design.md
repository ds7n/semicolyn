# tmux command encoder

**Date:** 2026-06-20
**Status:** Locked
**Phase:** 3 (terminal core) — the outbound counterpart to the Phase 3a control-mode parser and the Phase 3b session model. Linux-testable pure logic.

## Goal

Define the pure, value-in/string-out encoder that turns Semicolyn's intents
(open a window, split a pane, resize, switch, send keystrokes, end the session)
into the exact `tmux` control-mode command lines Semicolyn writes back over the
SSH channel. This is the inverse of [[2026-06-20-tmux-control-mode-parser-design]]:
the parser reads `%`-prefixed notifications *from* tmux; the encoder writes plain
command lines *to* tmux's control-mode stdin.

The session controller / `-CC` handshake orchestration (when to send which
command, reattach sequencing) is a **separate later slice** — this slice is only
the stateless encoding of individual commands. It owns no I/O and no state.

## Control-mode command framing

In `tmux -CC` control mode, the client sends commands the same way it would type
them at the tmux command prompt: **one command per line, terminated by a single
`\n`**. tmux parses the line with its normal command-string lexer (whitespace
splits arguments; `"`/`'`/`\` quote). Every command Semicolyn sends is correlated to
a `%begin`/`%end`/`%error` block in the reply stream (handled by the parser).

**Framing rule for this encoder:** each function returns a single command line
**without** the trailing `\n`. The transport layer (controller slice) appends
exactly one `\n` when it writes. The encoder guarantees its output contains **no
`\n` and no `\r`** — newline framing is structural and must never be forgeable
from an argument value (see *send-keys* below).

## Argument safety model

Two classes of argument, two trust levels:

1. **tmux object IDs** (`%N` pane, `@N` window, `$N` session) — from
   [[TmuxIDs]], always sigil + unsigned integer. No metacharacters possible;
   emitted verbatim as `%`/`@`/`$` + decimal.
2. **Free-form values** — only two exist: the **session name** (for
   `kill-session`) and the **key payload** (for `send-keys`). Both are handled
   so that no input value can alter command structure:
   - **Session name** — Semicolyn only ever names sessions `semicolyn-<accountHash>` or
     `semicolyn-<accountHash>-<uuid>` per [[2026-06-17-tmux-session-design]], i.e.
     `[a-z0-9-]+`. The encoder **validates** the name against that safe charset
     and returns `nil` (fail closed) for anything else, rather than quoting. A
     name that can't appear in practice is a programming error, not a runtime
     condition to paper over.
   - **Key payload** — encoded as hex bytes via `send-keys -H` (below), so the
     payload never reaches tmux's quoting lexer at all.

## send-keys: hex encoding (the one real decision)

`send-keys` carries arbitrary terminal input — letters, UTF-8, control bytes
(`Esc`, `Ctrl-C`), pasted blobs. Three candidate encodings:

| Option | Form | Verdict |
|---|---|---|
| Literal `-l` + shell quoting | `send-keys -t %0 -l "rm -rf /"` | Rejected — requires bullet-proof quoting of attacker-influenced bytes through tmux's lexer; a single missed edge (embedded `"`, `\`, newline) is a command-injection / framing break. |
| Key-name tokens | `send-keys -t %0 C-c Enter` | Rejected as the primary path — lossy for raw bytes and UTF-8; tmux re-interprets tokens. |
| **Hex bytes `-H`** | `send-keys -t %0 -H 72 6d 1b` | **Chosen.** Each byte → two lowercase hex digits, space-separated. No quoting, no metacharacters, no framing risk; round-trips arbitrary bytes including `0x0a`/`0x0d` exactly. |

**Decision: `send-keys -t %N -H <hh hh …>`** with every input byte rendered as a
zero-padded two-digit lowercase hex token. The byte sequence is the UTF-8 (or raw
control-byte) encoding the caller already holds — the encoder takes `[UInt8]`,
not `String`, so the caller owns text→bytes and the encoder owns bytes→wire. An
**empty** byte array returns `nil` (a no-op send is a caller bug, not a command).

This is the security-first choice consistent with the project's posture: literal
terminal input can never escape its argument position because it is never in
argument-text form on the wire.

## Command set (this slice)

All functions are pure `static` methods on a `TmuxCommand` namespace. Commands
that validate free-form input return `String?` (`nil` = invalid input, fail
closed); the infallible ID-only commands return `String` (see *Validation*).
`target` arguments take the typed IDs from [[TmuxIDs]]; the encoder renders their
sigils.

| Intent | Signature → output |
|---|---|
| New window | `newWindow()` → `new-window` |
| Split pane | `splitWindow(target: PaneID, direction: SplitDirection)` → `split-window -h\|-v -t %N` |
| Resize pane | `resizePane(target: PaneID, width: Int, height: Int)` → `resize-pane -t %N -x W -y H` |
| Select window | `selectWindow(target: WindowID)` → `select-window -t @N` |
| Select pane | `selectPane(target: PaneID)` → `select-pane -t %N` |
| Zoom pane | `zoomPane(target: PaneID)` → `resize-pane -Z -t %N` |
| Kill pane | `killPane(target: PaneID)` → `kill-pane -t %N` |
| Send keys | `sendKeys(target: PaneID, bytes: [UInt8])` → `send-keys -t %N -H hh …` |
| Kill session | `killSession(name: String)` → `kill-session -t <name>` |

### SplitDirection — naming the divider, not the axis

"Split vertically" is famously ambiguous (iTerm's ⌘D vs tmux's `-v` mean opposite
divider orientations). To avoid the trap, the enum names the **resulting divider /
arrangement**, and the spec pins the tmux flag:

- `.sideBySide` → new pane to the **right**, a **vertical divider** → tmux **`-h`**
- `.stacked` → new pane **below**, a **horizontal divider** → tmux **`-v`**

UI gesture/shortcut mapping (per [[2026-06-17-external-keyboard-design]]'s
⌘D=vertical-split, ⌘-/⇧⌘D=horizontal-split) is resolved in the keybar/input
slice, which chooses a `SplitDirection` case; the encoder stays UI-agnostic.

### Validation (fail-closed)

- `resizePane`: `width`/`height` must be `≥ 1`; else `nil` (returns `String?`).
- `sendKeys`: empty `bytes` → `nil` (returns `String?`).
- `killSession`: name must match `^[a-z0-9-]+$` and be non-empty; else `nil`
  (returns `String?`).
- **All other commands take only typed IDs and cannot fail → non-optional
  `String`.** The optionality of a return type carries information: a `String?`
  signals "this can reject input." Forcing the infallible ID-only commands to
  `String?` for cosmetic uniformity would push a meaningless `nil` branch onto
  every call site. So the signature tracks fallibility: `String?` exactly when
  validation can fail, `String` otherwise.

## Out of scope (later slices)

- **Session controller / handshake** — `new-session -d -s …`, `attach-session
  -t … -CC`, reattach sequencing, command↔`%begin` correlation, ret/timeout.
- **Higher-level orchestration** — which command to send for a given gesture,
  debouncing resize (`SIGWINCH` 10 Hz per [[2026-06-17-terminal-ux-additions-design]]),
  the degraded raw-PTY path (no tmux commands at all).
- **SwiftTerm / SwiftUI rendering** — macOS-gated.
- **`send-keys` key-name convenience layer** — if a future caller wants
  symbolic keys, it converts to bytes itself; the wire stays hex.

## Related

- [[2026-06-20-tmux-control-mode-parser-design]] — inbound counterpart
- [[2026-06-20-tmux-session-model-design]] — state the commands mutate
- [[2026-06-17-tmux-session-design]] — session naming charset
- [[2026-06-17-external-keyboard-design]] — split/shortcut UI mapping
- [[2026-06-17-terminal-ux-additions-design]] — resize debounce policy
