# tmux session controller

**Date:** 2026-06-20
**Status:** Locked
**Phase:** 3 (terminal core) — the stateful orchestrator that ties together the
Phase 3a parser, 3b session model, and 3c command encoder. Pure, Linux-testable;
owns no I/O.

## Goal

Define `TmuxSessionController`: the object that drives a `tmux -CC` control-mode
session from attach to exit. It turns the three pure pieces into a working
session engine:

- **In:** raw channel bytes → ``ControlModeParser`` → ``ControlModeEvent``s.
- **State:** events fold into a ``TmuxSessionState`` (3b) the UI renders.
- **Out:** caller intents → ``TmuxCommand`` lines → wire bytes to write.
- **Correlation:** each command the caller submits is matched to its
  `%begin`/`%end`/`%error` result block so the caller learns the outcome.

## I/O boundary (the load-bearing decision)

The controller is a **pure state machine with no I/O**, exactly like the parser
and encoder. The actual SSH channel — exec request, read loop, write — lives in
the caller (a later macOS/bridge slice). The controller only:

- **produces** the exec command string and the wire bytes to write, and
- **consumes** the bytes that arrive.

This keeps the whole control-mode stack Linux-testable end to end: feed it a
byte script, assert on the resulting state and outputs, no sockets.

### Surface

```
final class TmuxSessionController {
    init()

    // Lifecycle the caller observes.
    private(set) var lifecycle: TmuxLifecycle   // .idle → .attaching → .attached → .exited
    private(set) var state: TmuxSessionState     // the 3b model, folded from events

    // 1. Begin a session. Returns the SSH *exec command string* to run on the
    //    channel (control mode starts immediately). nil if name invalid or not idle.
    func start(sessionName: String) -> String?

    // 2. Feed channel bytes. Parses, folds structural events into `state`,
    //    resolves completed commands, advances lifecycle. Returns what changed.
    func feed(_ bytes: [UInt8]) -> TmuxControllerOutput

    // 3. Submit a command (an encoder line). Registers it for correlation and
    //    returns its id + the framed wire bytes to write. nil unless .attached.
    func submit(_ commandLine: String) -> TmuxSubmission?
}

enum TmuxLifecycle: Equatable { case idle, attaching, attached, exited(reason: String?) }

struct TmuxSubmission: Equatable { let id: UInt64; let wire: [UInt8] }   // wire = line + "\n"

struct TmuxControllerOutput: Equatable {
    var lifecycleChanged: Bool
    var stateChanged: Bool
    var resolved: [ResolvedCommand]   // commands whose result block arrived this feed
}

struct ResolvedCommand: Equatable { let id: UInt64; let outcome: CommandOutcome }
```

## Attach handshake

Semicolyn runs **`tmux -CC new-session -A -s <name>`** as the channel's exec command
(`start` returns exactly this string). Rationale:

- `-CC` enters control mode; the stream is control-mode from the first byte.
- `new-session -A` is **create-or-attach, atomically** — it creates `<name>` if
  absent, attaches if present. This is the spec's
  [[2026-06-17-tmux-session-design]] shared-session model and dissolves the
  "two devices first-connect at once" race (tmux serializes; the loser attaches).
- **No `-D`** — detaching other clients would break the multi-device sharing the
  session-naming spec is built around.

`<name>` is the caller-computed `semicolyn-<accountHash>` (or alt-session variant);
the controller stays agnostic of how it's derived (that's iOS-Keychain
territory) but **validates** it against the session charset (below) and refuses
otherwise.

### Lifecycle transitions

| From | Event | To |
|---|---|---|
| `.idle` | `start()` called | `.attaching` |
| `.attaching` | first `%session-changed` (`sessionChanged`) | `.attached` |
| any non-exited | `%exit` (`exit`) | `.exited(reason)` |

`%session-changed` is the attach signal: tmux emits `%session-changed $id name`
immediately after a successful attach, carrying the identity the UI needs. Using
it (not the payload-less `%sessions-changed`) means reaching `.attached` and
populating `state.sessionID` happen together.

## Command ↔ result correlation

tmux wraps each command the client sends in a `%begin <ts> <n> …` / `%end`
(or `%error`) block; the parser already coalesces these into
`commandResult(number:outcome:)`. Replies arrive **in send order** (tmux
processes the control-mode command queue serially), so:

- `submit` assigns a monotonic `id`, appends it to a **FIFO pending queue**, and
  returns the framed wire bytes.
- On each `commandResult`, the controller **pops the head** of the pending queue
  and emits a `ResolvedCommand(id, outcome)`.

### The unsolicited initial block

When `-CC` attaches, tmux emits one initial `%begin/%end` block that corresponds
to no client command. The controller handles this without a special case:
**`submit` is only valid in `.attached`**, but the initial block arrives during
`.attaching` while the pending queue is empty. A `commandResult` with an **empty
pending queue is treated as spontaneous and dropped** (not matched, not an
error). By the time the caller can submit, the initial block is long consumed.
Other attached clients' commands never appear as blocks on our stream (only as
the resulting `%output`/`%layout-change` notifications), so the empty-queue case
is exactly and only the initial block.

## State folding

For every parsed event the controller calls `state.apply(event)` — 3b already
ignores non-structural events, so this is safe and total. `stateChanged` is set
by comparing the `Equatable` state before/after the feed (no per-event
bookkeeping to drift). `commandResult` is handled by the controller (correlation)
and also passed to `apply` (which ignores it) — one code path, no branching to
forget.

## Validation / fail-closed

- `start`: `sessionName` must satisfy the Semicolyn session charset `^[a-z0-9-]+$`
  ([[2026-06-17-tmux-session-design]]); else `nil`. This rule is **shared** with
  the 3c encoder's `killSession` via a single `isValidTmuxSessionName` helper —
  one definition, both call sites (no drift between attach and kill).
- `start`: returns `nil` if `lifecycle != .idle` (start is once-only).
- `submit`: returns `nil` unless `lifecycle == .attached`.

## Out of scope (later slices)

- **Actual channel I/O** — exec request, async read loop, backpressure, write —
  caller's job (macOS/bridge slice). The controller is the pure core it drives.
- **Command timeouts** — require a clock; would break deterministic
  Linux testing. The I/O layer (which owns the clock) times out a pending
  submission and can surface a synthetic error; the controller stays clockless.
- **Reattach after drop** — SSH-sleep/wake and mosh roaming
  ([[2026-06-15-multi-connection-switching-design]]) re-run `start` on a fresh
  controller against the same (server-preserved) session; orchestrating *when*
  is Phase 6.
- **Alt-session / kill-session lifecycle** — naming and the picker actions are
  [[2026-06-17-tmux-session-design]]; the controller just takes whatever name it
  is given and can emit a `kill-session` line via the encoder.
- **Degraded raw-PTY mode** — no tmux, no controller
  ([[2026-06-14-degraded-mode-design]]).
- **SwiftTerm / SwiftUI rendering** — macOS-gated; renders `state`.

## Related

- [[2026-06-20-tmux-control-mode-parser-design]] — inbound events
- [[2026-06-20-tmux-session-model-design]] — the state being folded
- [[2026-06-20-tmux-command-encoder-design]] — the lines being submitted
- [[2026-06-17-tmux-session-design]] — session naming + multi-device
- [[2026-06-15-multi-connection-switching-design]] — reattach lifecycle (Phase 6)
