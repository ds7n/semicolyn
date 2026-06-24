# PTY shell channel (Phase 1d)

**Status:** Locked — 2026-06-19
**Phase:** 1d (SSH core) — builds on Phase 1b `Connection` + Phase 1c auth.

## Summary

Add a raw PTY-backed shell channel on top of an authenticated `Connection`: open
a session channel, request a PTY and a login shell, stream the merged
stdout/stderr back to the caller, accept stdin and window-resize, and report a
single terminal close event with the shell's exit status. This is the spine the
terminal layer (Phase 3 — SwiftTerm + tmux control mode, and the degraded raw-PTY
fallback) renders on top of. Integration-tested against the existing `sshd`
fixture; no fixture changes are needed.

**Out of scope (later phases / tasks):** port forwarding (`direct-tcpip` /
`forwarded-tcpip`), ProxyJump nested channels, non-PTY `exec` capture, tmux
control-mode parsing, and the SwiftTerm consumption (macOS-gated). Exposing
custom terminal modes and pixel dimensions is deferred (YAGNI) until a consumer
needs them.

## Tech stack

Rust, `russh` 0.61.2, `tokio`, `uniffi` 0.31, the dev container + the `sshd`
fixture. GPL-3.0-only; REUSE headers on every new file; conventional commits.

## Verified russh 0.61.2 API (recon-confirmed)

- `Handle::channel_open_session() -> Result<Channel<Msg>, Error>`
- `Channel::request_pty(want_reply: bool, term: &str, col_width: u32, row_height: u32, pix_width: u32, pix_height: u32, terminal_modes: &[(Pty, u32)]) -> Result<(), Error>`
- `Channel::request_shell(want_reply: bool) -> Result<(), Error>`
- `Channel::data(data: impl AsyncRead) -> Result<(), Error>` (stdin write)
- `Channel::window_change(col_width: u32, row_height: u32, pix_width: u32, pix_height: u32) -> Result<(), Error>`
- `Channel::eof() -> Result<(), Error>`, `Channel::close() -> Result<(), Error>`
- `Channel::wait() -> Option<ChannelMsg>` (read loop)
- `ChannelMsg` variants used: `Data { data }`, `ExtendedData { data, ext }`, `ExitStatus { exit_status }`, `ExitSignal { signal_name, .. }`, `Eof`, `Close`

## Public API surface (UniFFI)

A foreign delegate the caller implements (mirrors the existing `HostKeyVerifier`
pattern), plus a session object returned from `Connection`.

```rust
/// Sink for shell output and lifecycle. Swift implements it; Linux tests use a
/// Rust double. Methods are synchronous and MUST be fast/non-blocking — they run
/// on the pump task; a Swift impl forwards into an AsyncStream continuation.
#[uniffi::export(with_foreign)]
pub trait ShellOutput: Send + Sync {
    /// A chunk of merged stdout+stderr from the PTY. May be called many times.
    fn on_output(&self, data: Vec<u8>);
    /// The session has ended. Fired exactly once, after which no further
    /// callbacks occur.
    fn on_closed(&self, exit: ShellExit);
}

/// How a shell session ended. At most one of the first two is set on a clean
/// teardown; `error` is set instead when the transport failed.
#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq)]
pub struct ShellExit {
    /// Clean exit code, from the server's `exit-status` request.
    pub exit_status: Option<u32>,
    /// Signal name, when the remote process was killed by a signal.
    pub signal: Option<String>,
    /// Transport/protocol error message, when the channel failed rather than
    /// closing cleanly.
    pub error: Option<String>,
}

#[uniffi::export(async_runtime = "tokio")]
impl Connection {
    /// Open a PTY-backed login shell. Requests a PTY (`term`/`cols`/`rows`,
    /// pixel dims 0, no extra modes) then a shell, and starts pumping output to
    /// `output`. Returns once the shell is started; output and the close event
    /// arrive asynchronously via the delegate.
    pub async fn open_shell(
        &self,
        term: String,
        cols: u32,
        rows: u32,
        output: Arc<dyn ShellOutput>,
    ) -> Result<Arc<ShellSession>, ConnectError>;
}

#[uniffi::export(async_runtime = "tokio")]
impl ShellSession {
    /// Write bytes to the shell's stdin.
    pub async fn write(&self, data: Vec<u8>) -> Result<(), ConnectError>;
    /// Tell the remote of a new terminal size (pixel dims 0).
    pub async fn resize(&self, cols: u32, rows: u32) -> Result<(), ConnectError>;
    /// End the session: send EOF + close. Idempotent-ish — a second call (or a
    /// call after the shell already exited) returns the "closed" error.
    pub async fn close(&self) -> Result<(), ConnectError>;
}
```

## Internals — concurrency model

The russh `Channel` is not `Clone`, and `wait()` (read) needs `&mut self` while
writes also act on the channel. Rather than wrap it in a `Mutex` and contend on
every byte, the channel lives entirely inside one background pump task; the
`ShellSession` communicates with it over a `tokio::sync::mpsc` command channel.

```
open_shell:
  ch = handle.channel_open_session().await?
  ch.request_pty(true, &term, cols, rows, 0, 0, &[]).await?
  ch.request_shell(true).await?
  (cmd_tx, cmd_rx) = mpsc::channel(32)   // small bound; commands are infrequent
  tokio::spawn(pump(ch, cmd_rx, output))   // task owns Channel + delegate
  return ShellSession { cmd_tx }

pump(ch, cmd_rx, output):
  exit = ShellExit::default()
  loop select! {
    msg = ch.wait() => match msg {
      Some(Data{data}) | Some(ExtendedData{data, ..}) => output.on_output(data),
      Some(ExitStatus{exit_status})       => exit.exit_status = Some(exit_status),
      Some(ExitSignal{signal_name, ..})   => exit.signal = Some(signal_name),
      Some(Eof) | Some(Close) | None      => break,
      _ (other msgs) => {}                // ignore WindowAdjusted/Success/etc.
    }
    cmd = cmd_rx.recv() => match cmd {
      Some(Write(b))    => ch.data(&b[..]).await ... ,
      Some(Resize(c,r)) => ch.window_change(c, r, 0, 0).await ... ,
      Some(Close) | None => { ch.eof().await; ch.close().await; /* keep draining wait() until Close */ }
    }
  }
  output.on_closed(exit)   // fired exactly once, on task exit
```

- `write` / `resize` / `close` send a `Command` over `cmd_tx`. If the task has
  ended, the send errors → typed `ConnectError::Transport { message: "shell
  session closed" }`.
- Dropping the `ShellSession` drops `cmd_tx`; `recv()` then yields `None`, the
  task closes the channel and exits — no leaked tasks.
- A transport error surfaced by `ch.wait()` (or a failed close) sets
  `exit.error` and ends the loop.
- `on_closed` is fired exactly once, when the pump task exits, regardless of how
  it ended (clean exit, signal, EOF, drop, or error).

This keeps the non-`Clone` channel single-owner and lock-free, multiplexing
reads and writes through one `select!`.

## Error handling

- PTY or shell request failure during `open_shell` → `ConnectError::Transport`
  (the session never starts; no pump task is spawned).
- `write` / `resize` / `close` after the pump task has ended → the `cmd_tx` send
  fails → `ConnectError::Transport { message: "shell session closed" }` (a
  specific, asserted failure — never a panic).
- Transport failure mid-session → reported once via `on_closed` with `error`
  set; subsequent `write`/`resize` calls return the "closed" error.

## Testing (integration vs the `sshd` fixture)

**Risk tier: Core** (real I/O, not a trust/crypto decision) → Equivalence
Partitioning + Boundary Value Analysis, good and bad cases. A test `ShellOutput`
double accumulates output under a `Mutex` and records the `ShellExit`.
Assertions use condition-based polling with a timeout (no fixed sleeps), since
output arrives asynchronously. The double drives real assertions about the
system under test (echoed bytes, exit code, post-close error) — never asserts
its own state in isolation.

| Test | Drives | Asserts (observable) |
|---|---|---|
| shell echoes input | `open_shell`, `write("echo neotilde-marker\n")` | accumulated output contains `neotilde-marker` (poll ≤ a few s, else fail) |
| clean exit reports status 0 | `write("exit 0\n")` | `on_closed` fires once; `exit_status == Some(0)`, `signal`/`error` == `None` |
| non-zero exit (BVA) | `write("exit 3\n")` | `on_closed`; `exit_status == Some(3)` — proves the real code, not a constant |
| resize is accepted | `resize(120, 40)`, `write("stty size\n")` | output contains `40 120` (server observed the new size) |
| write after close fails | `close()`, then `write(...)` | `Err(ConnectError::Transport)` — specific failure, no panic |

All tests are gated behind `NEOTILDE_TEST_SSHD` like the existing auth/connect
suites. The current Alpine `sshd` fixture already provides `/bin/sh` and `stty`,
so no fixture changes are required.

## Exit criteria

- `cargo test -p neotilde-ssh-core` (unit + connect + auth + the new shell suite)
  green against the running `sshd` fixture; no regression in earlier suites.
- Echo round-trips; clean exit reports status 0; non-zero exit reports the real
  code; resize takes effect; write-after-close returns the typed error.
- No leaked pump tasks (dropping the session closes the channel).
- Every new file carries the REUSE header; conventional commits, ~3 (one per
  task).
- **macOS-gated (deferred):** the SwiftTerm/AsyncStream consumption of
  `ShellOutput`, and any custom terminal modes / pixel dimensions.
