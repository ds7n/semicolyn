# tmux control-mode transport (SSH exec channel)

**Date:** 2026-06-20
**Status:** Locked
**Phase:** 3 (terminal core) — the Rust-side transport that carries a `tmux -CC`
control-mode stream, bridging the Phase 1 SSH core to the Phase 3d
`TmuxSessionController`. Linux-testable against the `sshd` fixtures.

## Goal

Give `Connection` (the russh transport from Phase 1) the one capability the tmux
control-mode session needs: **run a remote command and stream its bytes
bidirectionally**. The Swift ``TmuxSessionController`` produces the command string
(`tmux -CC new-session -A -s <name>`) and consumes the byte stream; this slice is
the channel underneath it.

## Decision: a generic `open_exec`, not a tmux-specific method

The SSH operation tmux control mode needs is just **exec a command + pipe its
stdio**. Two shapes were considered:

- `open_tmux_control(session_name)` — Rust builds `tmux -CC new-session -A -s
  <name>` and validates the name.
- **`open_exec(command)`** — Rust execs whatever command string it's given.

**Chosen: `open_exec(command, output)`.** The tmux knowledge already lives in
Swift (`TmuxSessionController.start()` builds and the encoder validates the
command); duplicating the `tmux -CC …` literal and the session-name charset in
Rust would be a second source of truth across the language boundary. A generic
exec channel is also the primitive the later **mosh bootstrap** needs (exec
`mosh-server new …` and read its port/key), so it pays for itself twice. Rust
stays a dumb, reusable transport; product logic stays in Swift.

## Reuse: the Phase 1d shell machinery, unchanged

A control-mode channel is byte-stream-in / byte-stream-out / exit — **identical**
to the PTY shell from Phase 1d. So `open_exec` reuses, with no new types:

- `ShellOutput` — the output+lifecycle sink (`on_output` / `on_closed`).
- `ShellExit` — exit status / signal / error.
- `ShellSession` — the write/close handle.
- `pump` — the single channel-owning task.

The only difference from `open_shell` is **`exec` instead of `request_shell`**;
the `request_pty` stays.

### A PTY is required (verified against real tmux)

`tmux -CC` calls `tcgetattr` on startup and exits with *"tcgetattr failed: Not a
tty"* — producing **no** control-mode output — when run without a controlling
terminal (confirmed by running it under a plain pipe vs. a PTY in the `sshd`
fixture image). So the transport requests a PTY, exactly as iTerm2's tmux
integration does. The `-CC` (double-`C`) mode then disables terminal echo
itself, so the protocol rides the PTY without corruption. `cols`/`rows` seed the
control-client size; `ShellSession.resize` (`window_change`) works normally
because a PTY is present.

## Surface

```rust
impl Connection {
    /// Exec `command` on a PTY-backed session channel and pump its stdio to
    /// `output`. The transport for tmux control mode — the caller passes
    /// `TmuxSessionController.start()`'s `tmux -CC new-session -A -s <name>`
    /// string — and any other run-a-remote-command need (e.g. mosh bootstrap).
    /// Returns once the channel is open; output and the exit arrive via `output`.
    pub async fn open_exec(
        &self,
        command: String,
        term: String,
        cols: u32,
        rows: u32,
        output: Arc<dyn ShellOutput>,
    ) -> Result<Arc<ShellSession>, ConnectError>;
}
```

`request_pty(term, cols, rows)` then `channel.exec(true, command)`; same `pump`
spawn as `open_shell`.

## Validation

None at the Rust boundary: `exec` of a command string is the generic SSH
primitive, and the only caller builds the string from the validated Swift
encoder. Adding a charset check here would be a redundant, drifting second gate.
(The session-name charset is enforced once, in Swift, by `isValidTmuxSessionName`
shared between the controller and `kill-session`.)

## Testing (Linux, against the `sshd` fixture)

- **Generic exec correctness** (no tmux needed): exec `printf` / `echo` →
  `on_output` carries the exact bytes; exec `sh -c 'exit 0'` / `'exit 7'` →
  `on_closed` reports the real status (good and bad). These prove the transport
  independent of tmux.
- **Real `tmux -CC` smoke** (requires tmux in the fixture): exec `tmux -CC
  new-session -A -s glymr-test` → `on_output` contains the control-mode handshake
  notifications (`%begin`, `%session-changed $0 glymr-test`, `%window-add`).
  Verified real-tmux output for reference:

  ```
  <ESC>P1000p%begin <ts> <n> 0
  %end <ts> <n> 0
  %window-add @0
  %sessions-changed
  %session-changed $0 glymr-test
  %output %0 …
  <ESC>\
  ```

  This proves the actual target command produces a real control-mode stream a
  `TmuxSessionController` could drive. The fixture's `Dockerfile.sshd` adds
  `tmux` for this.

### Discovered downstream gap (Phase 3a follow-up, not this slice)

The real stream is wrapped in a **DCS** envelope — `ESC P 1 0 0 0 p` … `ESC \` —
and the opening `%begin` shares the first line as `ESC P1000p%begin …`. The
Phase 3a `ControlModeParser` does **not** yet strip this wrapper, so it would
mis-parse the first and last lines. That is a parser-hardening slice, tracked
separately; this transport slice only proves the bytes arrive intact (the test
substring-matches the notifications, which is wrapper-agnostic).

## Out of scope (later slices)

- **Wiring `open_exec` to `TmuxSessionController`** — needs the UniFFI bridge
  (macOS-gated XCFramework). Here both halves exist and are independently tested;
  the bridge connects `on_output` → `controller.feed` and `controller.submit`'s
  wire bytes → `session.write`.
- **Command timeouts / reattach** — the controller's deferred items
  ([[2026-06-20-tmux-session-controller-design]]).
- **mosh bootstrap** — a separate future caller of `open_exec`.

## Related

- [[2026-06-19-pty-shell-channel-design]] — the Phase 1d shell machinery reused here
- [[2026-06-20-tmux-session-controller-design]] — the Swift consumer of this stream
- [[2026-06-17-tmux-session-design]] — the `tmux -CC new-session -A` command
