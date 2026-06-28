# tmux `-CC` control-mode protocol parser (Phase 3a)

**Date:** 2026-06-20
**Status:** Locked
**Phase:** 3a — the Linux-testable slice of Phase 3 (Terminal core + tmux control
mode). SwiftTerm integration, the native pane SwiftUI rendering, and the
command-encoder / session controller are **separate later slices**.
**Related specs:** [[2026-06-17-terminal-emulator-scope-design]],
[[2026-06-17-tmux-session-design]], [[2026-06-14-degraded-mode-design]].

## Goal

Turn the raw byte stream tmux emits in control mode (`tmux -CC`) into a sequence
of typed, validated events that the native pane/window model and the SwiftTerm
feed consume. The parser is the beating heart of Semicolyn's session engine; getting
it correct and well-tested on the Linux fast loop de-risks the whole terminal
phase before any macOS-gated UI work.

## Placement

**Swift, in `SemicolynKit`** (`Sources/SemicolynKit/Tmux/`). When connected via
`tmux -CC`, the control-mode stream *is* the shell channel's byte stream, which
already crosses the UniFFI bridge as `ShellOutput.on_output([UInt8])` into Swift.
The `%output` payloads feed SwiftTerm (Swift) and the pane/window model is Swift,
so parsing in Swift keeps the entire data flow on one side of the bridge with no
new marshalled event vocabulary. Pure string/byte parsing, no Apple-only APIs →
fully testable via `swift test` in the dev container.

The alternative (Rust in `semicolyn-ssh-core`) was rejected: it would require a
UniFFI record/enum for every parsed event, a large bridge surface for data whose
only consumer is Swift.

## Architecture & data flow

A pure, streaming, **parser-only** unit — no I/O, no socket, no command-sending:

```
russh shell channel ──on_output([UInt8])──▶ ControlModeParser.feed(_:) ──▶ [ControlModeEvent]
                                              (buffers partial lines)         │
                                                                              ▼
                                                              pane/window model + SwiftTerm feed
```

- **Input:** arbitrary byte chunks, *not* line-aligned. The parser holds an
  internal buffer; it emits events only for complete `\n`-terminated lines. A
  trailing partial line waits for the next `feed`.
- **API:** `func feed(_ bytes: [UInt8]) -> [ControlModeEvent]` — synchronous,
  pull-style (returns the events parsed from that chunk). No delegate; trivial to
  test.
- **Boundary:** the parser knows nothing about SSH, sockets, the `-CC`
  handshake, or sending tmux commands. It is `bytes → events`, deterministic.

## Event contract

Typed ID wrappers keep the three tmux namespaces from mixing:

```swift
struct PaneID: Hashable    { let raw: UInt32 }   // %0, %1 …
struct WindowID: Hashable  { let raw: UInt32 }   // @0, @1 …
struct SessionID: Hashable { let raw: UInt32 }   // $0, $1 …

enum ControlModeEvent: Equatable {
    case output(pane: PaneID, data: [UInt8])                  // octal-unescaped bytes
    case commandResult(number: Int, outcome: CommandOutcome) // %begin…%end/%error coalesced
    case windowAdd(WindowID)
    case windowClose(WindowID)
    case windowRenamed(WindowID, name: String)
    case windowPaneChanged(WindowID, active: PaneID)
    case layoutChange(WindowID, layout: PaneLayout, visible: PaneLayout, flags: String)
    case sessionChanged(SessionID, name: String)
    case sessionWindowChanged(SessionID, active: WindowID)
    case sessionsChanged
    case exit(reason: String?)
    case unknown(verb: String, raw: String)                  // forward-compat, never a crash
    case malformed(raw: String, reason: String)              // recoverable parse failure
}

enum CommandOutcome: Equatable { case ok([String]); case error([String]) }
```

### Messages handled

| Wire form | Event |
|---|---|
| `%begin <ts> <num> <flags>` … `%end <ts> <num> <flags>` | `.commandResult(num, .ok(bodyLines))` |
| `%begin …` … `%error <ts> <num> <flags>` | `.commandResult(num, .error(bodyLines))` |
| `%output %<pane> <data>` | `.output(pane, unescaped(data))` |
| `%layout-change @<win> <layout> <visible-layout> <flags>` | `.layoutChange(win, …)` |
| `%window-add @<win>` | `.windowAdd(win)` |
| `%window-close @<win>` / `%unlinked-window-close @<win>` | `.windowClose(win)` |
| `%window-renamed @<win> <name>` | `.windowRenamed(win, name)` |
| `%window-pane-changed @<win> %<pane>` | `.windowPaneChanged(win, pane)` |
| `%session-changed $<sess> <name>` | `.sessionChanged(sess, name)` |
| `%session-window-changed $<sess> @<win>` | `.sessionWindowChanged(sess, win)` |
| `%sessions-changed` | `.sessionsChanged` |
| `%exit` / `%exit <reason>` | `.exit(reason)` |
| any other `%verb …` | `.unknown(verb, raw)` |

### Block coalescing

The parser buffers body lines between `%begin N` and its matching `%end N` /
`%error N`, then emits **one** `.commandResult(N, …)`. tmux guarantees
notifications never interleave inside a block, so coalescing is safe and gives
consumers a clean "response to command N". The matching `<num>` from `%begin` is
the event's `number`. A `%end`/`%error` whose number does not match the open
block, or that arrives with no block open, is a `.malformed` event (the stream is
out of sync) and the parser resets to the no-open-block state.

### `%output` octal unescaping

tmux escapes the data field: a backslash followed by exactly three octal digits
is one byte; `\\` is a literal backslash. The decoder turns the escaped ASCII
field back into the raw `[UInt8]`. A backslash not followed by a valid 3-octal
(or `\`) escape makes the line `.malformed`.

## Layout-string parsing (`%layout-change`)

The layout string (e.g. `bc62,80x24,0,0{40x24,0,0,1,39x24,41,0,2}`) parses into a
tree:

```swift
struct Geometry: Equatable { let w, h, x, y: UInt16 }
indirect enum PaneLayout: Equatable {
    case leaf(PaneID, Geometry)
    case columns([PaneLayout], Geometry)   // {…} panes side-by-side (left→right)
    case rows([PaneLayout], Geometry)      // […] panes stacked (top→bottom)
}
```

- The leading 4-hex **checksum** is parsed and **ignored** (tmux's own integrity
  field; re-verifying buys nothing on a trusted local parse).
- `WxH,X,Y,<paneid>` → `.leaf`; `WxH,X,Y{…}` → `.columns`; `WxH,X,Y[…]` →
  `.rows`. Children are comma-separated and may nest arbitrarily.
- A grammar violation (unbalanced brackets, missing dimensions, non-numeric
  field) makes the enclosing `%layout-change` a `.malformed` event; no partial
  tree is emitted.

Both `<layout>` and `<visible-layout>` fields are parsed; the visible layout can
differ when a pane is zoomed.

## Error handling

**Lenient, never-throw** — a long-lived terminal session must survive a weird
line:

- Unknown `%verb` → `.unknown` event.
- Malformed known verb (bad id, broken octal, bad layout grammar, mismatched
  block number) → `.malformed(raw, reason)`; that line is dropped, parsing
  continues.
- Partial line → buffered; no event until its newline arrives.

No `throws`, no `fatalError`, no precondition failures on input. Input is
untrusted stream data and is treated as such.

## Testing (TDD, `swift test` on Linux)

Risk tier: **Critical** (protocol trust boundary parsing untrusted bytes) →
equivalence partitioning + boundary values + adversarial cases; every assertion
checks the exact event/payload, never merely "did not crash".

- **Framing:** chunk split mid-line, mid-id, and between `\r` and `\n`; multiple
  events in one `feed`; one event across three `feed`s.
- **`%output`:** octal decode (`\033`, `\\`, mixed), empty data, bad escape →
  `.malformed`, large payload.
- **Blocks:** `%begin/%end` ok with N body lines (incl. zero), `%begin/%error`,
  number mismatch → `.malformed` + resync, `%end` with no open block →
  `.malformed`.
- **Window/session events:** each verb with valid args → exact event; missing
  arg → `.malformed`; renamed with spaces / empty name.
- **Layout:** single `.leaf`; one `{}` split; one `[]` split; deep nested mix;
  zoomed (visible ≠ layout); checksum ignored; unbalanced brackets →
  `.malformed`.
- **Forward-compat:** unknown verb → `.unknown(verb, raw)` with the verb captured.

## Out of scope (this slice)

- The `tmux -CC` handshake orchestration and the **command encoder** (`new-window`,
  `split-window`, `resize-pane`, `send-keys`, `kill-session`) — Phase 3b.
- SwiftTerm integration and SwiftUI pane rendering — macOS-gated, later in Phase 3.
- `%pause` / `%continue` / `%extended-output` (pause-after-N flow control),
  `%subscription-change` (refresh-client `-B` subscriptions),
  `%client-detached` / `%client-session-changed` (multi-client awareness) — not
  needed for v1; auto-addable later as `.unknown` already tolerates them.
- Session naming / multi-device policy — already locked in
  [[2026-06-17-tmux-session-design]]; runtime concern of the controller, not the
  parser.

## Cross-spec consequences

- [[2026-06-17-terminal-emulator-scope-design]] — the `%output` bytes this parser
  emits are what later feed the xterm-256color emulator; OSC 52 / OSC 0-2 / mouse
  handling all operate on that downstream byte stream, not on this parser.
- [[2026-06-14-degraded-mode-design]] — `.exit` and a sustained run of
  `.malformed` are signals the controller can use to fall back to raw-PTY mode.
