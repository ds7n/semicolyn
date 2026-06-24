# Phase 1d — PTY Shell Channel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a PTY-backed shell channel on the authenticated Phase-1b/1c `Connection`: open a session, request a PTY + login shell, stream merged stdout/stderr to a foreign delegate, accept stdin and resize, and report a single typed close event with the shell's exit status.

**Architecture:** `Connection::open_shell` opens a russh session channel, requests a PTY then a shell, and spawns one background "pump" task that **solely owns** the non-`Clone` `Channel`. The returned `ShellSession` talks to that task over a `tokio::sync::mpsc` command channel (write / resize / close); the task multiplexes channel reads (`wait()`) and commands in a single lock-free `tokio::select!`, pushing output to the `ShellOutput` delegate and firing `on_closed` exactly once when it exits.

**Tech Stack:** Rust, `russh` 0.61.2, `tokio`, `uniffi` 0.31, the dev container + the existing `sshd` fixture (no fixture changes).

**Design doc:** `docs/superpowers/specs/2026-06-19-pty-shell-channel-design.md`

## Global Constraints

- **Shell requires an authenticated connection.** Tests connect, then `authenticate_password("tester","testpass")` (Phase 1c) before `open_shell`.
- **Channel is single-owner.** Only the pump task touches the `Channel`; `ShellSession` never holds it. No `Mutex` around the channel.
- **`on_closed` fires exactly once**, when the pump task exits (clean exit, signal, EOF, session drop, or transport error).
- **Typed outcomes, not panics.** Post-close `write`/`resize`/`close` return `ConnectError::Transport { message: "shell session closed" }` — never panic.
- **No fixture changes.** The current Alpine `sshd` already provides `/bin/sh` and `stty`; all tests gate behind `NEOTILDE_TEST_SSHD`.
- **License header** (`// SPDX-FileCopyrightText: 2026 True Positive LLC` / `// SPDX-License-Identifier: GPL-3.0-only`) on every new `.rs`; **conventional commits**, one per task; run everything in the dev container.
- **macOS-gated, deferred:** the SwiftTerm/AsyncStream consumption of `ShellOutput`; custom terminal modes / pixel dimensions.

## Verified russh 0.61.2 API (recon-confirmed)

- `Handle::channel_open_session(&self) -> Result<Channel<Msg>, russh::Error>`
- `Channel::request_pty(&self, want_reply: bool, term: &str, col_width: u32, row_height: u32, pix_width: u32, pix_height: u32, terminal_modes: &[(Pty, u32)]) -> Result<(), Error>`
- `Channel::request_shell(&self, want_reply: bool) -> Result<(), Error>`
- `Channel::data_bytes(&self, data: impl Into<Bytes>) -> Result<(), Error>` (stdin; takes owned bytes)
- `Channel::window_change(&self, col_width: u32, row_height: u32, pix_width: u32, pix_height: u32) -> Result<(), Error>`
- `Channel::eof(&self) -> Result<(), Error>`, `Channel::close(&self) -> Result<(), Error>`
- `Channel::wait(&mut self) -> Option<ChannelMsg>`
- `ChannelMsg::Data { data: Bytes }`, `ChannelMsg::ExtendedData { data: Bytes, ext: u32 }`, `ChannelMsg::ExitStatus { exit_status: u32 }`, `ChannelMsg::ExitSignal { signal_name: Sig, .. }`, `ChannelMsg::Eof`, `ChannelMsg::Close`
- `russh::Sig::name` is **private** → stringify the signal with `format!("{signal_name:?}")`.

## File Structure

| File | Responsibility |
|---|---|
| `crates/neotilde-ssh-core/src/connection.rs` | `ShellOutput` delegate, `ShellExit`, `ShellSession`, `ShellCommand` (internal), `Connection::open_shell`, the `pump` task |
| `crates/neotilde-ssh-core/tests/shell_integration.rs` | Shell channel integration tests vs `sshd` (test double + condition polling) |

---

### Task 1: Shell open + stream + write + close + exit status

**Files:**
- Modify: `crates/neotilde-ssh-core/src/connection.rs`
- Create: `crates/neotilde-ssh-core/tests/shell_integration.rs`

**Interfaces:**
- Consumes: `connect_core`, `Connection`, `ConnectError`, `AuthOutcome`, `authenticate_password`, `HostKeyVerifier`, `HostKeyInfo` (Phases 1b/1c).
- Produces:
  - `pub trait ShellOutput: Send + Sync { fn on_output(&self, data: Vec<u8>); fn on_closed(&self, exit: ShellExit); }` (`#[uniffi::export(with_foreign)]`)
  - `pub struct ShellExit { pub exit_status: Option<u32>, pub signal: Option<String>, pub error: Option<String> }` (`uniffi::Record`)
  - `pub struct ShellSession { /* mpsc sender */ }` (`uniffi::Object`)
  - `Connection::open_shell(&self, term: String, cols: u32, rows: u32, output: Arc<dyn ShellOutput>) -> Result<Arc<ShellSession>, ConnectError>` (async, UniFFI)
  - `ShellSession::write(&self, data: Vec<u8>) -> Result<(), ConnectError>` (async, UniFFI)
  - `ShellSession::close(&self) -> Result<(), ConnectError>` (async, UniFFI)

- [ ] **Step 1: Write the failing integration tests**

Create `crates/neotilde-ssh-core/tests/shell_integration.rs`:
```rust
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
use std::sync::{Arc, Mutex};
use std::time::Duration;
use neotilde_ssh_core::connection::{
    connect_core, AuthOutcome, Connection, ConnectError, HostKeyInfo, HostKeyVerifier,
    ShellExit, ShellOutput,
};

struct TrustAll;
#[async_trait::async_trait]
impl HostKeyVerifier for TrustAll {
    async fn verify(&self, _info: HostKeyInfo) -> bool { true }
}

#[derive(Default)]
struct Collected {
    out: Vec<u8>,
    exit: Option<ShellExit>,
}

/// Test double: accumulates output and records the close event so tests can
/// assert on observable shell behavior (echoed bytes, exit code, errors).
#[derive(Clone)]
struct Collector(Arc<Mutex<Collected>>);
impl Collector {
    fn new() -> Self { Collector(Arc::new(Mutex::new(Collected::default()))) }
    fn text(&self) -> String { String::from_utf8_lossy(&self.0.lock().unwrap().out).into_owned() }
    fn exit(&self) -> Option<ShellExit> { self.0.lock().unwrap().exit.clone() }
}
impl ShellOutput for Collector {
    fn on_output(&self, data: Vec<u8>) { self.0.lock().unwrap().out.extend_from_slice(&data); }
    fn on_closed(&self, exit: ShellExit) { self.0.lock().unwrap().exit = Some(exit); }
}

fn sshd_addr() -> Option<String> { std::env::var("NEOTILDE_TEST_SSHD").ok() }

/// Poll `pred` up to ~5s (100 × 50ms). Returns its final value — true once the
/// async condition holds, false if it never did (so the test fails on a real
/// timeout rather than hanging).
async fn wait_until(mut pred: impl FnMut() -> bool) -> bool {
    for _ in 0..100 {
        if pred() { return true; }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    pred()
}

async fn connect_and_auth(addr: String) -> Connection {
    let conn = connect_core(addr, false, false, Arc::new(TrustAll)).await.expect("connect");
    let outcome = conn
        .authenticate_password("tester".into(), "testpass".into())
        .await
        .expect("auth call");
    assert_eq!(outcome, AuthOutcome::Success);
    conn
}

#[tokio::test]
async fn shell_echoes_written_input() {
    let Some(addr) = sshd_addr() else { eprintln!("skipping: set NEOTILDE_TEST_SSHD"); return };
    let conn = connect_and_auth(addr).await;
    let col = Collector::new();
    let session = conn
        .open_shell("xterm".into(), 80, 24, Arc::new(col.clone()))
        .await
        .expect("open shell");
    session.write(b"echo neotilde-marker\n".to_vec()).await.expect("write");
    let saw = wait_until(|| col.text().contains("neotilde-marker")).await;
    assert!(saw, "expected shell output to contain marker, got: {:?}", col.text());
    let _ = session.close().await;
}

#[tokio::test]
async fn shell_clean_exit_reports_status_zero() {
    let Some(addr) = sshd_addr() else { eprintln!("skipping: set NEOTILDE_TEST_SSHD"); return };
    let conn = connect_and_auth(addr).await;
    let col = Collector::new();
    let session = conn
        .open_shell("xterm".into(), 80, 24, Arc::new(col.clone()))
        .await
        .expect("open shell");
    session.write(b"exit 0\n".to_vec()).await.expect("write");
    let closed = wait_until(|| col.exit().is_some()).await;
    assert!(closed, "shell did not report closure");
    let exit = col.exit().unwrap();
    assert_eq!(exit.exit_status, Some(0));
    assert_eq!(exit.signal, None);
    assert_eq!(exit.error, None);
}

// Silence the unused import until Task 3 uses it.
#[allow(dead_code)]
fn _uses_connect_error() -> Option<ConnectError> { None }
```

- [ ] **Step 2: Run the tests to verify they fail**

Ensure `sshd` is up: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose up -d sshd`
Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p neotilde-ssh-core --test shell_integration`
Expected: FAIL — `no ShellExit/ShellOutput in connection`, `no method named open_shell`.

- [ ] **Step 3: Add the delegate, `ShellExit`, `ShellCommand`, and `ShellSession`**

In `crates/neotilde-ssh-core/src/connection.rs`, add after the `AuthOutcome` / `outcome()` block:
```rust
/// Sink for shell output and lifecycle. Swift implements it (forwarding into an
/// AsyncStream); Linux tests use a Rust double. Methods are synchronous and MUST
/// be fast/non-blocking — they run on the pump task.
#[uniffi::export(with_foreign)]
pub trait ShellOutput: Send + Sync {
    /// A chunk of merged stdout+stderr from the PTY. May be called many times.
    fn on_output(&self, data: Vec<u8>);
    /// The session ended. Fired exactly once; no callbacks follow.
    fn on_closed(&self, exit: ShellExit);
}

/// How a shell session ended. On a clean teardown at most one of
/// `exit_status` / `signal` is set; `error` is set instead on transport failure.
#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq, Default)]
pub struct ShellExit {
    /// Clean exit code, from the server's `exit-status`.
    pub exit_status: Option<u32>,
    /// Signal name, when the remote process was killed by a signal.
    pub signal: Option<String>,
    /// Transport/protocol error message, when the channel failed.
    pub error: Option<String>,
}

/// Commands the `ShellSession` sends to its owning pump task.
enum ShellCommand {
    Write(Vec<u8>),
    Resize(u32, u32),
    Close,
}

/// A live PTY shell channel. Drives one background pump task that owns the russh
/// channel; this handle only sends it commands.
#[derive(uniffi::Object)]
pub struct ShellSession {
    cmd_tx: tokio::sync::mpsc::Sender<ShellCommand>,
}
```

- [ ] **Step 4: Add the `pump` task**

In `crates/neotilde-ssh-core/src/connection.rs`, add a free function (near `connect_core`):
```rust
/// Sole owner of the russh channel for a shell session. Multiplexes channel
/// reads and `ShellSession` commands; pushes output to `output` and fires
/// `on_closed` exactly once on exit.
async fn pump(
    mut channel: russh::Channel<russh::client::Msg>,
    mut cmd_rx: tokio::sync::mpsc::Receiver<ShellCommand>,
    output: Arc<dyn ShellOutput>,
) {
    use russh::ChannelMsg as M;
    let mut exit = ShellExit::default();
    loop {
        tokio::select! {
            msg = channel.wait() => match msg {
                Some(M::Data { data }) | Some(M::ExtendedData { data, .. }) => {
                    output.on_output(data.to_vec());
                }
                Some(M::ExitStatus { exit_status }) => exit.exit_status = Some(exit_status),
                Some(M::ExitSignal { signal_name, .. }) => {
                    exit.signal = Some(format!("{signal_name:?}"));
                }
                Some(M::Eof) | Some(M::Close) | None => break,
                Some(_) => {} // WindowAdjusted / Success / Failure / etc.
            },
            cmd = cmd_rx.recv() => match cmd {
                Some(ShellCommand::Write(bytes)) => {
                    if let Err(e) = channel.data_bytes(bytes).await {
                        exit.error = Some(e.to_string());
                        break;
                    }
                }
                Some(ShellCommand::Resize(cols, rows)) => {
                    if let Err(e) = channel.window_change(cols, rows, 0, 0).await {
                        exit.error = Some(e.to_string());
                        break;
                    }
                }
                // Explicit close, or all senders dropped: tear down and drain.
                Some(ShellCommand::Close) | None => {
                    let _ = channel.eof().await;
                    let _ = channel.close().await;
                    while let Some(msg) = channel.wait().await {
                        match msg {
                            M::Data { data } | M::ExtendedData { data, .. } => {
                                output.on_output(data.to_vec());
                            }
                            M::ExitStatus { exit_status } => exit.exit_status = Some(exit_status),
                            M::ExitSignal { signal_name, .. } => {
                                exit.signal = Some(format!("{signal_name:?}"));
                            }
                            M::Eof | M::Close => break,
                            _ => {}
                        }
                    }
                    break;
                }
            },
        }
    }
    output.on_closed(exit);
}
```

- [ ] **Step 5: Implement `open_shell` on `Connection`**

In `crates/neotilde-ssh-core/src/connection.rs`, add inside the existing `#[uniffi::export(async_runtime = "tokio")] impl Connection` block (alongside the `authenticate_*` methods):
```rust
    /// Open a PTY-backed login shell. Requests a PTY (`term`/`cols`/`rows`,
    /// pixel dims 0, no extra modes) then a shell, and starts pumping output to
    /// `output`. Returns once the shell starts; output and the close event
    /// arrive asynchronously via the delegate.
    pub async fn open_shell(
        &self,
        term: String,
        cols: u32,
        rows: u32,
        output: Arc<dyn ShellOutput>,
    ) -> Result<Arc<ShellSession>, ConnectError> {
        let channel = {
            let handle = self.handle.lock().await;
            handle.channel_open_session().await?
        };
        channel.request_pty(true, &term, cols, rows, 0, 0, &[]).await?;
        channel.request_shell(true).await?;
        let (cmd_tx, cmd_rx) = tokio::sync::mpsc::channel(32);
        tokio::spawn(pump(channel, cmd_rx, output));
        Ok(Arc::new(ShellSession { cmd_tx }))
    }
```

- [ ] **Step 6: Implement `write` and `close` on `ShellSession`**

In `crates/neotilde-ssh-core/src/connection.rs`, add a new exported impl block (separate, so the tokio async-runtime attribute applies):
```rust
#[uniffi::export(async_runtime = "tokio")]
impl ShellSession {
    /// Write bytes to the shell's stdin.
    pub async fn write(&self, data: Vec<u8>) -> Result<(), ConnectError> {
        self.cmd_tx
            .send(ShellCommand::Write(data))
            .await
            .map_err(|_| ConnectError::Transport { message: "shell session closed".into() })
    }

    /// End the session: EOF + close. After the shell has already exited this
    /// returns the "shell session closed" error.
    pub async fn close(&self) -> Result<(), ConnectError> {
        self.cmd_tx
            .send(ShellCommand::Close)
            .await
            .map_err(|_| ConnectError::Transport { message: "shell session closed".into() })
    }
}
```

- [ ] **Step 7: Drop the now-stale `#[allow(dead_code)]` on `handle`**

The `handle` field is now used by auth (1c) and `open_shell` (1d). In `crates/neotilde-ssh-core/src/connection.rs`, in the `Connection` struct, change:
```rust
    #[allow(dead_code)] // consumed by Phase 1c (auth) and 1d (channels)
    handle: tokio::sync::Mutex<client::Handle<ClientHandler>>,
```
to:
```rust
    handle: tokio::sync::Mutex<client::Handle<ClientHandler>>,
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p neotilde-ssh-core --test shell_integration`
Expected: PASS — `shell_echoes_written_input`, `shell_clean_exit_reports_status_zero`.

- [ ] **Step 9: Commit**

```bash
git add crates/neotilde-ssh-core/src/connection.rs crates/neotilde-ssh-core/tests/shell_integration.rs
git commit -m "feat: add PTY shell channel with streamed output and exit status"
```

---

### Task 2: Window resize

**Files:**
- Modify: `crates/neotilde-ssh-core/src/connection.rs`
- Modify: `crates/neotilde-ssh-core/tests/shell_integration.rs`

**Interfaces:**
- Consumes: `ShellSession`, `ShellCommand::Resize` (Task 1).
- Produces: `ShellSession::resize(&self, cols: u32, rows: u32) -> Result<(), ConnectError>` (async, UniFFI)

- [ ] **Step 1: Write the failing test**

Add to `crates/neotilde-ssh-core/tests/shell_integration.rs`:
```rust
#[tokio::test]
async fn shell_resize_changes_window_size() {
    let Some(addr) = sshd_addr() else { eprintln!("skipping: set NEOTILDE_TEST_SSHD"); return };
    let conn = connect_and_auth(addr).await;
    let col = Collector::new();
    let session = conn
        .open_shell("xterm".into(), 80, 24, Arc::new(col.clone()))
        .await
        .expect("open shell");
    session.resize(120, 40).await.expect("resize");
    session.write(b"stty size\n".to_vec()).await.expect("write");
    // `stty size` prints "<rows> <cols>" — the resized terminal is 40x120.
    let saw = wait_until(|| col.text().contains("40 120")).await;
    assert!(saw, "expected resized size 40 120 in output, got: {:?}", col.text());
    let _ = session.close().await;
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p neotilde-ssh-core --test shell_integration shell_resize`
Expected: FAIL — `no method named resize`.

- [ ] **Step 3: Implement `resize`**

In `crates/neotilde-ssh-core/src/connection.rs`, add inside the `#[uniffi::export(async_runtime = "tokio")] impl ShellSession` block:
```rust
    /// Tell the remote of a new terminal size (pixel dims 0).
    pub async fn resize(&self, cols: u32, rows: u32) -> Result<(), ConnectError> {
        self.cmd_tx
            .send(ShellCommand::Resize(cols, rows))
            .await
            .map_err(|_| ConnectError::Transport { message: "shell session closed".into() })
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p neotilde-ssh-core --test shell_integration shell_resize`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add crates/neotilde-ssh-core/src/connection.rs crates/neotilde-ssh-core/tests/shell_integration.rs
git commit -m "feat: add shell window resize"
```

---

### Task 3: Adversarial / boundary coverage

**Files:**
- Modify: `crates/neotilde-ssh-core/tests/shell_integration.rs`

**Interfaces:**
- Consumes: `open_shell`, `ShellSession::{write, close}`, `ShellExit`, `ConnectError` (Task 1). No new production code — this task hardens coverage of Task 1's contract (BVA on the exit code; the typed post-close failure).

- [ ] **Step 1: Write the failing tests**

Replace the `_uses_connect_error` placeholder in `crates/neotilde-ssh-core/tests/shell_integration.rs` with:
```rust
#[tokio::test]
async fn shell_nonzero_exit_reports_real_code() {
    let Some(addr) = sshd_addr() else { eprintln!("skipping: set NEOTILDE_TEST_SSHD"); return };
    let conn = connect_and_auth(addr).await;
    let col = Collector::new();
    let session = conn
        .open_shell("xterm".into(), 80, 24, Arc::new(col.clone()))
        .await
        .expect("open shell");
    session.write(b"exit 3\n".to_vec()).await.expect("write");
    let closed = wait_until(|| col.exit().is_some()).await;
    assert!(closed, "shell did not report closure");
    // Proves we surface the server's real exit code, not a hardcoded constant.
    assert_eq!(col.exit().unwrap().exit_status, Some(3));
}

#[tokio::test]
async fn write_after_close_returns_typed_error() {
    let Some(addr) = sshd_addr() else { eprintln!("skipping: set NEOTILDE_TEST_SSHD"); return };
    let conn = connect_and_auth(addr).await;
    let col = Collector::new();
    let session = conn
        .open_shell("xterm".into(), 80, 24, Arc::new(col.clone()))
        .await
        .expect("open shell");
    session.close().await.expect("close");
    // Wait for the pump task to actually finish (drops the receiver) — only then
    // is a further send guaranteed to fail rather than being buffered.
    let closed = wait_until(|| col.exit().is_some()).await;
    assert!(closed, "session did not close");
    let err = session.write(b"x".to_vec()).await.expect_err("write after close must fail");
    match err {
        ConnectError::Transport { message } => assert_eq!(message, "shell session closed"),
        other => panic!("expected Transport(\"shell session closed\"), got {other:?}"),
    }
}
```
Also delete the now-unused `#[allow(dead_code)] fn _uses_connect_error` helper (replaced above).

- [ ] **Step 2: Run the tests to verify they fail (or pass) for the right reason**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p neotilde-ssh-core --test shell_integration`
Expected: both new tests compile and PASS against the Task-1 implementation. If `write_after_close_returns_typed_error` fails with `write after close must fail` (i.e. the write returned `Ok`), the close-then-wait ordering regressed — confirm the test waits for `col.exit().is_some()` before writing. If `shell_nonzero_exit_reports_real_code` reports `Some(0)`, the pump is overwriting/ignoring `ExitStatus` — re-check Task 1 Step 4.

- [ ] **Step 3: Run the entire crate suite (no regression)**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p neotilde-ssh-core`
Expected: PASS — unit tests, `connect_integration` (4), `auth_integration` (5), `shell_integration` (5).

- [ ] **Step 4: Commit**

```bash
git add crates/neotilde-ssh-core/tests/shell_integration.rs
git commit -m "test: add shell non-zero exit (BVA) and write-after-close negative cases"
```

---

## Phase 1d exit criteria

- [ ] `cargo test -p neotilde-ssh-core` green against the running `sshd` fixture; earlier suites (unit / connect / auth) unaffected.
- [ ] Echo round-trips; clean exit → `exit_status Some(0)`; non-zero exit → `Some(3)`; resize reflected by `stty size`; write-after-close → `ConnectError::Transport { "shell session closed" }`.
- [ ] No leaked pump tasks — dropping the `ShellSession` (all senders gone) makes the task close the channel and exit, firing `on_closed` once.
- [ ] New test file carries the REUSE header; three conventional commits, one per task.
- [ ] **macOS-gated (deferred):** SwiftTerm/AsyncStream consumption of `ShellOutput`; custom terminal modes / pixel dimensions.

## Self-review notes

- **Spec coverage:** every spec section maps to a task — API surface + concurrency + error handling land in Task 1 (open/stream/write/close/exit) and Task 2 (resize); the spec's 5-row test table maps to Task 1 (echo, exit-0), Task 2 (resize), Task 3 (exit-3 BVA, write-after-close negative). Exit criteria copied from the spec.
- **Concurrency correctness:** the `tokio::select!` borrows `&mut channel` only inside the `wait()` branch; the un-selected future is dropped before a command handler runs, so `channel.data_bytes(&self)` / `window_change(&self)` in the command arm are free of the read borrow — the standard select-read/handle-write idiom.
- **Why write-after-close waits for closure first:** the mpsc buffer (32) would accept a post-`Close` `Write` before the pump drains, so an immediate write could spuriously succeed. The test waits for `on_closed` (receiver dropped) so the send deterministically fails — this is a property of the design, documented so the implementer doesn't "fix" it by shrinking the buffer.
- **Signal stringification:** `russh::Sig::name` is private, so the rarely-hit `ExitSignal` path uses `format!("{signal_name:?}")`; `signal` is not asserted by any test (we exercise exit codes, not signals).
- **Split out / deferred:** SwiftTerm consumption and custom PTY modes/pixels per the spec; port forwarding and ProxyJump remain separate Phase-1 plans.
