# Phase 1e — Port Forwarding (local + dynamic + remote)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the three SSH port-forward types on the authenticated `Connection`, each as an async UniFFI method returning a closeable forward handle: **local** (`direct-tcpip` — bind a device-local port, tunnel to a remote target), **dynamic** (a local SOCKS5 proxy that opens a `direct-tcpip` channel per CONNECT), and **remote** (`forwarded-tcpip` — ask the server to listen and route inbound connections back to a device-local target). Integration-tested against the `sshd` fixture.

**Architecture:** The russh `client::Handle` is **not `Clone`**, so the `Connection`'s handle is wrapped in `Arc<tokio::sync::Mutex<Handle>>`; forward listener tasks share the `Arc` and briefly lock it only to open a channel (data then flows on the channel's `ChannelStream`, off-lock). Local and dynamic forwards bind a `tokio::net::TcpListener` owned by a per-forward accept-loop task (a `JoinSet` of per-connection pumps; aborting the task tears the whole forward down). Each tunnel is a `tokio::io::copy_bidirectional(tcp, channel.into_stream())`. Remote forwards add a `ForwardMap` (`Arc<Mutex<HashMap<u32,(String,u16)>>>`) shared between `Connection` and `ClientHandler`: `open_remote_forward` calls `Handle::tcpip_forward` and registers the server bind port → local target; the handler's `server_channel_open_forwarded_tcpip` callback looks up the target, connects locally, and pumps.

**Tech Stack:** Rust, `russh` 0.61.2, `tokio` (net + io + task::JoinSet), `uniffi` 0.31, the dev container + the `sshd` fixture. SOCKS5 CONNECT (no-auth) is hand-rolled — no new dependency (keeps the cargo-deny license gate clean).

**Design basis:** roadmap Phase 1 "direct-tcpip / forwarded-tcpip forwards" + host-config-model's `localForwards`/`remoteForwards`/`dynamicForwards`. No SSH-core runtime spec existed; this plan is the locked design for the core forwarding API (UI runtime surface is `terminal-ux-additions`, Swift-gated).

## Global Constraints

- **Handle is not Clone.** Share `Arc<tokio::sync::Mutex<Handle>>`; lock only to open a channel, never across `copy_bidirectional`.
- **Forwards owned by the core.** The Rust core owns the local `TcpListener`(s) and pump tasks. `close()` (and `Drop`) aborts the accept loop, whose `JoinSet` drop aborts all in-flight tunnels and frees the port.
- **Per-connection failures don't kill the forward.** A failed channel-open or a reset tunnel ends that one connection; the listener keeps accepting.
- **SOCKS5, CONNECT, no-auth only.** The dynamic proxy is device-local. Reject other versions/commands/auth with the correct SOCKS reply, then close. No SOCKS4, BIND, or UDP ASSOCIATE.
- **Typed outcomes, not panics.** Bind/setup failures → `ConnectError::Transport { message }`; never panic on socket or protocol input.
- **License header** on every new `.rs`; **conventional commits**, one per task; run everything in the dev container.
- **macOS-gated, deferred:** the Swift runtime UI (per-forward status rows, toggles) from `terminal-ux-additions`.

## Verified russh 0.61.2 / tokio API (recon-confirmed)

- `client::Handle` is NOT `Clone` (owns a `receiver` + `JoinHandle`) → wrap in `Arc<Mutex<…>>`.
- `Handle::channel_open_direct_tcpip<A,B: Into<String>>(&self, host_to_connect, port_to_connect: u32, originator_address, originator_port: u32) -> Result<Channel<Msg>, Error>`
- `Handle::tcpip_forward<A: Into<String>>(&self, address, port: u32) -> Result<u32, Error>` (returns the assigned port when `port==0`)
- `Handle::cancel_tcpip_forward<A: Into<String>>(&self, address, port: u32) -> Result<(), Error>`
- `client::Handler::server_channel_open_forwarded_tcpip(&mut self, channel: Channel<Msg>, connected_address: &str, connected_port: u32, originator_address: &str, originator_port: u32, session: &mut Session) -> impl Future<Output=Result<(),Self::Error>>` (default returns Ok; override it)
- `Channel::into_stream(self) -> ChannelStream<Msg>` — implements `AsyncRead + AsyncWrite + Unpin`.
- `tokio::io::copy_bidirectional(&mut a, &mut b)` — both `AsyncRead+AsyncWrite+Unpin` (TcpStream ✓, ChannelStream ✓).
- `tokio::task::JoinSet` (dropping it aborts all its tasks); `tokio::task::JoinHandle::abort_handle()`.

## File Structure

| File | Responsibility |
|---|---|
| `crates/semicolyn-ssh-core/src/lib.rs` | add `pub mod forward;` |
| `crates/semicolyn-ssh-core/src/connection.rs` | `handle` → `Arc<Mutex<Handle>>`; `ClientHandler`→`pub(crate)`; `open_local_forward`/`open_dynamic_forward`/`open_remote_forward` on `Connection`; `ForwardMap` + the `server_channel_open_forwarded_tcpip` override (Task 3) |
| `crates/semicolyn-ssh-core/src/forward.rs` | pump helper, `LocalForward`/`DynamicForward`/`RemoteForward` objects, accept loops, hand-rolled SOCKS5 |
| `crates/semicolyn-ssh-core/tests/forward_integration.rs` | integration tests vs `sshd` |
| `docker/Dockerfile.sshd` | `AllowTcpForwarding yes` (Task 1) + `GatewayPorts yes` (Task 3) |

---

### Task 1: Handle→Arc refactor + module + local forward (direct-tcpip)

**Files:**
- Modify: `crates/semicolyn-ssh-core/src/connection.rs`, `crates/semicolyn-ssh-core/src/lib.rs`, `docker/Dockerfile.sshd`
- Create: `crates/semicolyn-ssh-core/src/forward.rs`, `crates/semicolyn-ssh-core/tests/forward_integration.rs`

**Interfaces:**
- Consumes: `connect_core`, `Connection`, `ConnectError`, `ClientHandler`, `authenticate_password`, `AuthOutcome` (Phases 1b/1c).
- Produces:
  - `Connection::open_local_forward(&self, local_host: String, local_port: u16, remote_host: String, remote_port: u16) -> Result<Arc<LocalForward>, ConnectError>` (async, UniFFI)
  - `forward::LocalForward` (`uniffi::Object`): `fn bound_port(&self) -> u16`, `async fn close(&self)`; `Drop` aborts.

- [ ] **Step 1: Enable TCP forwarding in the sshd fixture**

In `docker/Dockerfile.sshd`, append `AllowTcpForwarding yes` to the config `RUN`'s final `printf` (the line that already writes `UsePAM yes\nKbdInteractiveAuthentication yes`):
```dockerfile
    && printf 'UsePAM yes\nKbdInteractiveAuthentication yes\nAllowTcpForwarding yes\n' >> /etc/ssh/sshd_config
```

- [ ] **Step 2: Refactor `Connection.handle` to `Arc<Mutex<Handle>>` and make `ClientHandler` crate-visible**

In `crates/semicolyn-ssh-core/src/connection.rs`:
- Change the handler struct declaration `struct ClientHandler {` → `pub(crate) struct ClientHandler {`.
- Change the `Connection` field:
  ```rust
      handle: tokio::sync::Mutex<client::Handle<ClientHandler>>,
  ```
  to:
  ```rust
      handle: std::sync::Arc<tokio::sync::Mutex<client::Handle<ClientHandler>>>,
  ```
- In `connect_core`, change the constructor:
  ```rust
      Ok(Connection {
          handle: tokio::sync::Mutex::new(handle),
          tier3_in_use,
      })
  ```
  to:
  ```rust
      Ok(Connection {
          handle: std::sync::Arc::new(tokio::sync::Mutex::new(handle)),
          tier3_in_use,
      })
  ```
  (The existing `self.handle.lock().await` call sites in the `authenticate_*` and `open_shell` methods are unchanged — `Arc<Mutex<_>>` derefs to `Mutex<_>`.)

- [ ] **Step 3: Wire the module and write the failing local-forward test**

In `crates/semicolyn-ssh-core/src/lib.rs`, add after `pub mod connection;`:
```rust
pub mod forward;
```

Create `crates/semicolyn-ssh-core/tests/forward_integration.rs`:
```rust
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use semicolyn_ssh_core::connection::{
    connect_core, AuthOutcome, Connection, ConnectError, HostKeyInfo, HostKeyVerifier,
};

struct TrustAll;
#[async_trait::async_trait]
impl HostKeyVerifier for TrustAll {
    async fn verify(&self, _info: HostKeyInfo) -> bool { true }
}

fn sshd_addr() -> Option<String> { std::env::var("SEMICOLYN_TEST_SSHD").ok() }
fn sshd_host() -> Option<String> { sshd_addr().map(|a| a.split(':').next().unwrap_or("sshd").to_string()) }

async fn connect_and_auth(addr: String) -> Connection {
    let conn = connect_core(addr, false, false, Arc::new(TrustAll)).await.expect("connect");
    let outcome = conn.authenticate_password("tester".into(), "testpass".into()).await.expect("auth call");
    assert_eq!(outcome, AuthOutcome::Success);
    conn
}

// Tunnel local:0 -> (server) -> 127.0.0.1:22 (sshd's own port); reading the
// tunnel must yield sshd's SSH banner, proving end-to-end bidirectional flow.
#[tokio::test]
async fn local_forward_tunnels_to_remote_service() {
    let Some(addr) = sshd_addr() else { eprintln!("skipping: set SEMICOLYN_TEST_SSHD"); return };
    let conn = connect_and_auth(addr).await;
    let fwd = conn
        .open_local_forward("127.0.0.1".into(), 0, "127.0.0.1".into(), 22)
        .await
        .expect("open local forward");
    let mut sock = tokio::net::TcpStream::connect(("127.0.0.1", fwd.bound_port()))
        .await
        .expect("connect to local forward");
    let mut buf = [0u8; 8];
    let n = tokio::time::timeout(Duration::from_secs(5), sock.read(&mut buf))
        .await
        .expect("read timed out")
        .expect("read");
    assert!(n >= 4 && &buf[..4] == b"SSH-", "expected SSH banner through tunnel, got {:?}", &buf[..n]);
    fwd.close().await;
}

#[tokio::test]
async fn local_forward_reports_bound_port() {
    let Some(addr) = sshd_addr() else { eprintln!("skipping: set SEMICOLYN_TEST_SSHD"); return };
    let conn = connect_and_auth(addr).await;
    let fwd = conn
        .open_local_forward("127.0.0.1".into(), 0, "127.0.0.1".into(), 22)
        .await
        .expect("open local forward");
    assert_ne!(fwd.bound_port(), 0, "ephemeral bind must report a real port");
    fwd.close().await;
}

#[tokio::test]
async fn local_forward_close_frees_the_port() {
    let Some(addr) = sshd_addr() else { eprintln!("skipping: set SEMICOLYN_TEST_SSHD"); return };
    let conn = connect_and_auth(addr).await;
    let fwd = conn
        .open_local_forward("127.0.0.1".into(), 0, "127.0.0.1".into(), 22)
        .await
        .expect("open local forward");
    let port = fwd.bound_port();
    fwd.close().await;
    // After close the accept loop is aborted and the listener dropped; give the
    // runtime a moment, then a fresh connect must be refused.
    tokio::time::sleep(Duration::from_millis(200)).await;
    let res = tokio::time::timeout(
        Duration::from_secs(2),
        tokio::net::TcpStream::connect(("127.0.0.1", port)),
    ).await.expect("connect attempt timed out");
    assert!(res.is_err(), "port {port} should be refused after close");
}

// Silence unused imports until later tasks use them.
#[allow(dead_code)]
fn _uses(_: Option<ConnectError>, _: fn(&mut [u8])) {}
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose up -d --build sshd`
Then: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p semicolyn-ssh-core --test forward_integration`
Expected: FAIL — `no method named open_local_forward` / unresolved `forward`.

- [ ] **Step 5: Implement the pump helper and `LocalForward` in `forward.rs`**

Create `crates/semicolyn-ssh-core/src/forward.rs`:
```rust
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

//! SSH port forwarding: local (direct-tcpip), dynamic (SOCKS5), and remote
//! (forwarded-tcpip). The russh `Handle` is not `Clone`, so listener tasks
//! share `Arc<Mutex<Handle>>` and lock it only to open a channel; bytes then
//! flow on the channel's `ChannelStream`, off-lock.

use std::sync::Arc;
use tokio::sync::Mutex;

use crate::connection::ClientHandler;

type Handle = russh::client::Handle<ClientHandler>;

/// Copy bytes both directions between a local socket and an SSH channel until
/// either side closes. Errors are swallowed — a broken tunnel ends that one
/// connection, not the forward.
async fn pump(mut sock: tokio::net::TcpStream, channel: russh::Channel<russh::client::Msg>) {
    let mut stream = channel.into_stream();
    let _ = tokio::io::copy_bidirectional(&mut sock, &mut stream).await;
}

/// A live local (direct-tcpip) forward. Dropping or `close()`ing it aborts the
/// accept loop; its `JoinSet` of per-connection pumps is then dropped, aborting
/// all in-flight tunnels and freeing the bound port.
#[derive(uniffi::Object)]
pub struct LocalForward {
    bound_port: u16,
    abort: tokio::task::AbortHandle,
}

#[uniffi::export(async_runtime = "tokio")]
impl LocalForward {
    /// The actual local port the forward is listening on (useful when opened
    /// with port 0).
    pub fn bound_port(&self) -> u16 {
        self.bound_port
    }

    /// Stop the forward: abort the accept loop and tear down all tunnels.
    pub async fn close(&self) {
        self.abort.abort();
    }
}

impl Drop for LocalForward {
    fn drop(&mut self) {
        self.abort.abort();
    }
}

pub(crate) async fn open_local(
    handle: Arc<Mutex<Handle>>,
    local_host: String,
    local_port: u16,
    remote_host: String,
    remote_port: u16,
) -> Result<LocalForward, crate::connection::ConnectError> {
    use crate::connection::ConnectError;
    let listener = tokio::net::TcpListener::bind((local_host.as_str(), local_port))
        .await
        .map_err(|e| ConnectError::Transport {
            message: format!("failed to bind local forward {local_host}:{local_port}: {e}"),
        })?;
    let bound_port = listener
        .local_addr()
        .map_err(|e| ConnectError::Transport { message: format!("local_addr: {e}") })?
        .port();
    let task = tokio::spawn(local_accept_loop(listener, handle, remote_host, remote_port));
    Ok(LocalForward { bound_port, abort: task.abort_handle() })
}

async fn local_accept_loop(
    listener: tokio::net::TcpListener,
    handle: Arc<Mutex<Handle>>,
    remote_host: String,
    remote_port: u16,
) {
    let mut tunnels = tokio::task::JoinSet::new();
    loop {
        let Ok((sock, _peer)) = listener.accept().await else { break };
        let handle = Arc::clone(&handle);
        let rhost = remote_host.clone();
        tunnels.spawn(async move {
            let opened = {
                let h = handle.lock().await;
                h.channel_open_direct_tcpip(rhost, remote_port as u32, "127.0.0.1", 0).await
            };
            if let Ok(channel) = opened {
                pump(sock, channel).await;
            }
        });
        // Reap finished tunnels so the set doesn't grow unbounded.
        while tunnels.try_join_next().is_some() {}
    }
    // Returning (or being aborted) drops `tunnels`, aborting all live pumps.
}
```

- [ ] **Step 6: Add `open_local_forward` on `Connection`**

In `crates/semicolyn-ssh-core/src/connection.rs`, inside the existing `#[uniffi::export(async_runtime = "tokio")] impl Connection` block:
```rust
    /// Open a local (direct-tcpip) port forward: bind `local_host:local_port`
    /// on the device and tunnel each accepted connection to
    /// `remote_host:remote_port` through the SSH session. Pass `local_port` 0
    /// for an OS-assigned port (read it back via `bound_port()`).
    pub async fn open_local_forward(
        &self,
        local_host: String,
        local_port: u16,
        remote_host: String,
        remote_port: u16,
    ) -> Result<std::sync::Arc<crate::forward::LocalForward>, ConnectError> {
        crate::forward::open_local(
            std::sync::Arc::clone(&self.handle),
            local_host,
            local_port,
            remote_host,
            remote_port,
        )
        .await
        .map(std::sync::Arc::new)
    }
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p semicolyn-ssh-core --test forward_integration`
Expected: PASS — `local_forward_tunnels_to_remote_service`, `local_forward_reports_bound_port`, `local_forward_close_frees_the_port`.

- [ ] **Step 8: Run the full crate suite (no regression from the handle refactor)**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p semicolyn-ssh-core`
Expected: PASS — unit, connect, auth, shell, cert, and the new forward tests; output pristine.

- [ ] **Step 9: Commit**

```bash
git add crates/semicolyn-ssh-core/src/lib.rs crates/semicolyn-ssh-core/src/connection.rs crates/semicolyn-ssh-core/src/forward.rs crates/semicolyn-ssh-core/tests/forward_integration.rs docker/Dockerfile.sshd
git commit -m "feat: add local (direct-tcpip) port forwarding"
```

---

### Task 2: Dynamic forward (SOCKS5 proxy)

**Files:**
- Modify: `crates/semicolyn-ssh-core/src/forward.rs`, `crates/semicolyn-ssh-core/src/connection.rs`, `crates/semicolyn-ssh-core/tests/forward_integration.rs`

**Interfaces:**
- Consumes: `pump`, `Handle`, `open_local`'s patterns (Task 1).
- Produces:
  - `Connection::open_dynamic_forward(&self, local_host: String, local_port: u16) -> Result<Arc<DynamicForward>, ConnectError>` (async, UniFFI)
  - `forward::DynamicForward` (`uniffi::Object`): `fn bound_port(&self) -> u16`, `async fn close(&self)`; `Drop` aborts.

- [ ] **Step 1: Write the failing dynamic-forward tests**

Add to `crates/semicolyn-ssh-core/tests/forward_integration.rs`:
```rust
// Perform a SOCKS5 no-auth CONNECT handshake over `sock` to `host:port`.
// Returns the server's reply byte (0x00 = success) after the greeting.
async fn socks5_connect(sock: &mut tokio::net::TcpStream, host: &str, port: u16) -> u8 {
    // greeting: VER=5, 1 method, method=0 (no auth)
    sock.write_all(&[0x05, 0x01, 0x00]).await.expect("greeting");
    let mut g = [0u8; 2];
    sock.read_exact(&mut g).await.expect("greeting reply");
    assert_eq!(g, [0x05, 0x00], "server must select no-auth");
    // request: VER=5, CMD=CONNECT(1), RSV=0, ATYP=domain(3), len, host, port
    let mut req = vec![0x05, 0x01, 0x00, 0x03, host.len() as u8];
    req.extend_from_slice(host.as_bytes());
    req.extend_from_slice(&port.to_be_bytes());
    sock.write_all(&req).await.expect("request");
    // reply: VER, REP, RSV, ATYP, BND.ADDR(4 for v4), BND.PORT(2)
    let mut rep = [0u8; 10];
    sock.read_exact(&mut rep).await.expect("reply");
    assert_eq!(rep[0], 0x05);
    rep[1]
}

#[tokio::test]
async fn dynamic_forward_socks5_connect_reaches_target() {
    let Some(addr) = sshd_addr() else { eprintln!("skipping: set SEMICOLYN_TEST_SSHD"); return };
    let conn = connect_and_auth(addr).await;
    let fwd = conn.open_dynamic_forward("127.0.0.1".into(), 0).await.expect("open dynamic forward");
    let mut sock = tokio::net::TcpStream::connect(("127.0.0.1", fwd.bound_port())).await.expect("connect proxy");
    let rep = socks5_connect(&mut sock, "127.0.0.1", 22).await;
    assert_eq!(rep, 0x00, "SOCKS5 CONNECT to 127.0.0.1:22 must succeed");
    let mut buf = [0u8; 8];
    let n = tokio::time::timeout(Duration::from_secs(5), sock.read(&mut buf)).await.expect("timeout").expect("read");
    assert!(n >= 4 && &buf[..4] == b"SSH-", "expected SSH banner through SOCKS tunnel, got {:?}", &buf[..n]);
    fwd.close().await;
}

#[tokio::test]
async fn dynamic_forward_rejects_non_socks5_greeting() {
    let Some(addr) = sshd_addr() else { eprintln!("skipping: set SEMICOLYN_TEST_SSHD"); return };
    let conn = connect_and_auth(addr).await;
    let fwd = conn.open_dynamic_forward("127.0.0.1".into(), 0).await.expect("open dynamic forward");
    let mut sock = tokio::net::TcpStream::connect(("127.0.0.1", fwd.bound_port())).await.expect("connect proxy");
    // SOCKS4 greeting (VER=4) — unsupported; server must close without a v5 reply.
    sock.write_all(&[0x04, 0x01, 0x00, 0x16]).await.expect("write");
    let mut buf = [0u8; 2];
    let r = tokio::time::timeout(Duration::from_secs(2), sock.read(&mut buf)).await.expect("timeout");
    // Either EOF (0 bytes) or a non-0x05 first byte — never a SOCKS5 success.
    match r {
        Ok(0) => {}                               // connection closed: acceptable
        Ok(_) => assert_ne!(buf[0], 0x05, "must not speak SOCKS5 to a v4 client"),
        Err(e) => panic!("unexpected read error: {e}"),
    }
    fwd.close().await;
}

#[tokio::test]
async fn dynamic_forward_rejects_unsupported_command() {
    let Some(addr) = sshd_addr() else { eprintln!("skipping: set SEMICOLYN_TEST_SSHD"); return };
    let conn = connect_and_auth(addr).await;
    let fwd = conn.open_dynamic_forward("127.0.0.1".into(), 0).await.expect("open dynamic forward");
    let mut sock = tokio::net::TcpStream::connect(("127.0.0.1", fwd.bound_port())).await.expect("connect proxy");
    sock.write_all(&[0x05, 0x01, 0x00]).await.expect("greeting");
    let mut g = [0u8; 2];
    sock.read_exact(&mut g).await.expect("greeting reply");
    assert_eq!(g, [0x05, 0x00]);
    // CMD=BIND(2) is unsupported → reply code 0x07 (command not supported).
    let mut req = vec![0x05, 0x02, 0x00, 0x03, 0x09];
    req.extend_from_slice(b"127.0.0.1");
    req.extend_from_slice(&22u16.to_be_bytes());
    sock.write_all(&req).await.expect("request");
    let mut rep = [0u8; 10];
    sock.read_exact(&mut rep).await.expect("reply");
    assert_eq!(rep[1], 0x07, "BIND must be rejected with 0x07 command-not-supported");
    fwd.close().await;
}
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p semicolyn-ssh-core --test forward_integration dynamic_forward`
Expected: FAIL — `no method named open_dynamic_forward`.

- [ ] **Step 3: Implement the SOCKS5 handler + `DynamicForward` in `forward.rs`**

In `crates/semicolyn-ssh-core/src/forward.rs`, add:
```rust
/// A live dynamic (SOCKS5) forward — a device-local SOCKS5 proxy that opens a
/// direct-tcpip channel per CONNECT. Lifecycle identical to `LocalForward`.
#[derive(uniffi::Object)]
pub struct DynamicForward {
    bound_port: u16,
    abort: tokio::task::AbortHandle,
}

#[uniffi::export(async_runtime = "tokio")]
impl DynamicForward {
    pub fn bound_port(&self) -> u16 {
        self.bound_port
    }
    pub async fn close(&self) {
        self.abort.abort();
    }
}

impl Drop for DynamicForward {
    fn drop(&mut self) {
        self.abort.abort();
    }
}

pub(crate) async fn open_dynamic(
    handle: Arc<Mutex<Handle>>,
    local_host: String,
    local_port: u16,
) -> Result<DynamicForward, crate::connection::ConnectError> {
    use crate::connection::ConnectError;
    let listener = tokio::net::TcpListener::bind((local_host.as_str(), local_port))
        .await
        .map_err(|e| ConnectError::Transport {
            message: format!("failed to bind dynamic forward {local_host}:{local_port}: {e}"),
        })?;
    let bound_port = listener
        .local_addr()
        .map_err(|e| ConnectError::Transport { message: format!("local_addr: {e}") })?
        .port();
    let task = tokio::spawn(dynamic_accept_loop(listener, handle));
    Ok(DynamicForward { bound_port, abort: task.abort_handle() })
}

async fn dynamic_accept_loop(listener: tokio::net::TcpListener, handle: Arc<Mutex<Handle>>) {
    let mut tunnels = tokio::task::JoinSet::new();
    loop {
        let Ok((sock, _peer)) = listener.accept().await else { break };
        let handle = Arc::clone(&handle);
        tunnels.spawn(async move {
            let _ = socks5_serve(sock, handle).await;
        });
        while tunnels.try_join_next().is_some() {}
    }
}

/// Minimal SOCKS5 server: no-auth, CONNECT only. Replies with the correct SOCKS5
/// error code for unsupported versions/methods/commands/address types, then
/// closes. On CONNECT, opens a direct-tcpip channel and pumps.
async fn socks5_serve(
    mut sock: tokio::net::TcpStream,
    handle: Arc<Mutex<Handle>>,
) -> std::io::Result<()> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    // Generic failure reply (VER, REP, RSV, ATYP=v4, 0.0.0.0:0).
    let fail = |code: u8| [0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0];

    // Greeting: VER, NMETHODS, METHODS...
    let mut head = [0u8; 2];
    sock.read_exact(&mut head).await?;
    if head[0] != 0x05 {
        return Ok(()); // not SOCKS5 — close silently
    }
    let mut methods = vec![0u8; head[1] as usize];
    sock.read_exact(&mut methods).await?;
    if !methods.contains(&0x00) {
        sock.write_all(&[0x05, 0xFF]).await?; // no acceptable methods
        return Ok(());
    }
    sock.write_all(&[0x05, 0x00]).await?; // select no-auth

    // Request: VER, CMD, RSV, ATYP, ADDR, PORT
    let mut req = [0u8; 4];
    sock.read_exact(&mut req).await?;
    if req[0] != 0x05 {
        return Ok(());
    }
    if req[1] != 0x01 {
        sock.write_all(&fail(0x07)).await?; // command not supported
        return Ok(());
    }
    let host = match req[3] {
        0x01 => {
            let mut a = [0u8; 4];
            sock.read_exact(&mut a).await?;
            std::net::Ipv4Addr::from(a).to_string()
        }
        0x04 => {
            let mut a = [0u8; 16];
            sock.read_exact(&mut a).await?;
            std::net::Ipv6Addr::from(a).to_string()
        }
        0x03 => {
            let mut len = [0u8; 1];
            sock.read_exact(&mut len).await?;
            let mut d = vec![0u8; len[0] as usize];
            sock.read_exact(&mut d).await?;
            String::from_utf8_lossy(&d).into_owned()
        }
        _ => {
            sock.write_all(&fail(0x08)).await?; // address type not supported
            return Ok(());
        }
    };
    let mut port = [0u8; 2];
    sock.read_exact(&mut port).await?;
    let port = u16::from_be_bytes(port);

    let opened = {
        let h = handle.lock().await;
        h.channel_open_direct_tcpip(host, port as u32, "127.0.0.1", 0).await
    };
    match opened {
        Ok(channel) => {
            // success, BND.ADDR=0.0.0.0:0 (clients ignore it for CONNECT)
            sock.write_all(&[0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]).await?;
            pump(sock, channel).await;
        }
        Err(_) => {
            sock.write_all(&fail(0x01)).await?; // general SOCKS server failure
        }
    }
    Ok(())
}
```

- [ ] **Step 4: Add `open_dynamic_forward` on `Connection`**

In `crates/semicolyn-ssh-core/src/connection.rs`, inside the same exported `impl Connection` block:
```rust
    /// Open a dynamic (SOCKS5) forward: run a device-local SOCKS5 proxy on
    /// `local_host:local_port`; each CONNECT opens a direct-tcpip channel to the
    /// requested target. Pass `local_port` 0 for an OS-assigned port.
    pub async fn open_dynamic_forward(
        &self,
        local_host: String,
        local_port: u16,
    ) -> Result<std::sync::Arc<crate::forward::DynamicForward>, ConnectError> {
        crate::forward::open_dynamic(std::sync::Arc::clone(&self.handle), local_host, local_port)
            .await
            .map(std::sync::Arc::new)
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p semicolyn-ssh-core --test forward_integration`
Expected: PASS — all local + dynamic tests.

- [ ] **Step 6: Commit**

```bash
git add crates/semicolyn-ssh-core/src/forward.rs crates/semicolyn-ssh-core/src/connection.rs crates/semicolyn-ssh-core/tests/forward_integration.rs
git commit -m "feat: add dynamic (SOCKS5) port forwarding"
```

---

### Task 3: Remote forward (forwarded-tcpip)

**Files:**
- Modify: `crates/semicolyn-ssh-core/src/connection.rs`, `crates/semicolyn-ssh-core/src/forward.rs`, `crates/semicolyn-ssh-core/tests/forward_integration.rs`, `docker/Dockerfile.sshd`

**Interfaces:**
- Consumes: `pump`, `Handle`, `ClientHandler`, `Connection` (Tasks 1–2).
- Produces:
  - `crate::connection::ForwardMap` = `Arc<std::sync::Mutex<HashMap<u32, (String, u16)>>>` (server-bind-port → local target)
  - `Connection::open_remote_forward(&self, remote_bind_host: String, remote_bind_port: u16, local_host: String, local_port: u16) -> Result<Arc<RemoteForward>, ConnectError>` (async, UniFFI)
  - `forward::RemoteForward` (`uniffi::Object`): `fn bound_port(&self) -> u16`, `async fn close(&self) -> Result<(), ConnectError>`
  - `ClientHandler::server_channel_open_forwarded_tcpip` override routing inbound channels to the registered local target.

- [ ] **Step 1: Enable gateway ports in the sshd fixture**

In `docker/Dockerfile.sshd`, extend the final config `printf` to also write `GatewayPorts yes` (so the server binds the forwarded port on all interfaces, reachable from the dev container):
```dockerfile
    && printf 'UsePAM yes\nKbdInteractiveAuthentication yes\nAllowTcpForwarding yes\nGatewayPorts yes\n' >> /etc/ssh/sshd_config
```

- [ ] **Step 2: Add the `ForwardMap` and share it into `ClientHandler` + `Connection`**

In `crates/semicolyn-ssh-core/src/connection.rs`:
- Add near the top (after imports):
  ```rust
  /// Server-listen-port → device-local target (host, port) for active remote
  /// (forwarded-tcpip) forwards. Shared between `Connection` and `ClientHandler`.
  pub(crate) type ForwardMap =
      std::sync::Arc<std::sync::Mutex<std::collections::HashMap<u32, (String, u16)>>>;
  ```
- Add a field to `ClientHandler`:
  ```rust
      forwards: ForwardMap,
  ```
- Add a field to `Connection`:
  ```rust
      forwards: ForwardMap,
  ```
- In `connect_core`, create the map once and share it:
  ```rust
      let forwards: ForwardMap = std::sync::Arc::new(std::sync::Mutex::new(std::collections::HashMap::new()));
  ```
  Add `forwards: forwards.clone(),` to the `ClientHandler { … }` constructor, and `forwards,` to the `Connection { … }` constructor.

- [ ] **Step 3: Implement the forwarded-tcpip handler callback**

In `crates/semicolyn-ssh-core/src/connection.rs`, inside `impl client::Handler for ClientHandler` (alongside `check_server_key` / `kex_done`), add:
```rust
    async fn server_channel_open_forwarded_tcpip(
        &mut self,
        channel: russh::Channel<russh::client::Msg>,
        _connected_address: &str,
        connected_port: u32,
        _originator_address: &str,
        _originator_port: u32,
        _session: &mut russh::client::Session,
    ) -> Result<(), Self::Error> {
        // Route an inbound (server-initiated) forwarded connection to the
        // device-local target registered for this server listen port.
        let target = self.forwards.lock().unwrap().get(&connected_port).cloned();
        if let Some((host, port)) = target {
            tokio::spawn(async move {
                if let Ok(sock) = tokio::net::TcpStream::connect((host.as_str(), port)).await {
                    let mut sock = sock;
                    let mut stream = channel.into_stream();
                    let _ = tokio::io::copy_bidirectional(&mut sock, &mut stream).await;
                }
            });
        }
        // No registered target → channel is dropped (closed).
        Ok(())
    }
```

- [ ] **Step 4: Write the failing remote-forward test**

Add to `crates/semicolyn-ssh-core/tests/forward_integration.rs`:
```rust
// Remote forward: ask the server to listen on a fixed port and route inbound
// connections back to a device-local target serving a known banner. Connect to
// the server's port (reachable as <sshd-host>:PORT thanks to GatewayPorts yes)
// and expect the banner.
#[tokio::test]
async fn remote_forward_routes_inbound_to_local_target() {
    let Some(addr) = sshd_addr() else { eprintln!("skipping: set SEMICOLYN_TEST_SSHD"); return };
    let Some(host) = sshd_host() else { return };
    const REMOTE_PORT: u16 = 13389;
    const BANNER: &[u8] = b"HELLO-SEMICOLYN\n";

    // Device-local target: accept one connection and write the banner.
    let target = tokio::net::TcpListener::bind("127.0.0.1:0").await.expect("bind target");
    let target_port = target.local_addr().unwrap().port();
    tokio::spawn(async move {
        if let Ok((mut s, _)) = target.accept().await {
            let _ = s.write_all(BANNER).await;
            let _ = s.flush().await;
        }
    });

    let conn = connect_and_auth(addr).await;
    let fwd = conn
        .open_remote_forward("0.0.0.0".into(), REMOTE_PORT, "127.0.0.1".into(), target_port)
        .await
        .expect("open remote forward");
    assert_eq!(fwd.bound_port(), REMOTE_PORT);

    // Connect to the server's forwarded port from the dev container.
    let mut sock = tokio::time::timeout(
        Duration::from_secs(5),
        tokio::net::TcpStream::connect((host.as_str(), REMOTE_PORT)),
    ).await.expect("connect timeout").expect("connect to server forward port");
    let mut buf = vec![0u8; BANNER.len()];
    tokio::time::timeout(Duration::from_secs(5), sock.read_exact(&mut buf))
        .await.expect("read timeout").expect("read banner");
    assert_eq!(&buf, BANNER, "remote forward must deliver the local target's banner");

    fwd.close().await.expect("close remote forward");
}
```
Also delete the `#[allow(dead_code)] fn _uses(...)` placeholder from Task 1 (its imports are all used now).

- [ ] **Step 5: Run the test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose up -d --build sshd`
Then: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p semicolyn-ssh-core --test forward_integration remote_forward`
Expected: FAIL — `no method named open_remote_forward`.

- [ ] **Step 6: Implement `RemoteForward` + `open_remote` in `forward.rs`**

In `crates/semicolyn-ssh-core/src/forward.rs`, add:
```rust
use crate::connection::{ConnectError, ForwardMap};

/// A live remote (forwarded-tcpip) forward. The server listens on `bound_port`
/// and routes inbound connections back to a device-local target; `close()`
/// cancels the server-side listener and unregisters the route.
#[derive(uniffi::Object)]
pub struct RemoteForward {
    bound_port: u16,
    bind_host: String,
    handle: Arc<Mutex<Handle>>,
    forwards: ForwardMap,
}

#[uniffi::export(async_runtime = "tokio")]
impl RemoteForward {
    pub fn bound_port(&self) -> u16 {
        self.bound_port
    }

    /// Cancel the server-side listener and stop routing.
    pub async fn close(&self) -> Result<(), ConnectError> {
        self.forwards.lock().unwrap().remove(&(self.bound_port as u32));
        let h = self.handle.lock().await;
        h.cancel_tcpip_forward(self.bind_host.clone(), self.bound_port as u32).await?;
        Ok(())
    }
}

pub(crate) async fn open_remote(
    handle: Arc<Mutex<Handle>>,
    forwards: ForwardMap,
    remote_bind_host: String,
    remote_bind_port: u16,
    local_host: String,
    local_port: u16,
) -> Result<RemoteForward, ConnectError> {
    let assigned = {
        let h = handle.lock().await;
        h.tcpip_forward(remote_bind_host.clone(), remote_bind_port as u32).await?
    };
    // For a fixed (non-zero) request the server listens on exactly that port and
    // the reply carries no port; for port 0 the server returns the chosen port.
    let bound_port: u16 = if remote_bind_port == 0 { assigned as u16 } else { remote_bind_port };
    forwards
        .lock()
        .unwrap()
        .insert(bound_port as u32, (local_host, local_port));
    Ok(RemoteForward { bound_port, bind_host: remote_bind_host, handle, forwards })
}
```

- [ ] **Step 7: Add `open_remote_forward` on `Connection`**

In `crates/semicolyn-ssh-core/src/connection.rs`, inside the exported `impl Connection` block:
```rust
    /// Open a remote (forwarded-tcpip) port forward: ask the server to listen on
    /// `remote_bind_host:remote_bind_port` and route each inbound connection
    /// back to the device-local `local_host:local_port` through the SSH session.
    /// Pass `remote_bind_port` 0 for a server-assigned port (read via
    /// `bound_port()`).
    pub async fn open_remote_forward(
        &self,
        remote_bind_host: String,
        remote_bind_port: u16,
        local_host: String,
        local_port: u16,
    ) -> Result<std::sync::Arc<crate::forward::RemoteForward>, ConnectError> {
        crate::forward::open_remote(
            std::sync::Arc::clone(&self.handle),
            self.forwards.clone(),
            remote_bind_host,
            remote_bind_port,
            local_host,
            local_port,
        )
        .await
        .map(std::sync::Arc::new)
    }
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p semicolyn-ssh-core --test forward_integration`
Expected: PASS — local, dynamic, and remote tests.

- [ ] **Step 9: Run the entire crate suite (no regression)**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p semicolyn-ssh-core`
Expected: PASS — unit (8), connect (4), auth (5), shell (5), cert (4), forward (7); pristine.

- [ ] **Step 10: Commit**

```bash
git add crates/semicolyn-ssh-core/src/connection.rs crates/semicolyn-ssh-core/src/forward.rs crates/semicolyn-ssh-core/tests/forward_integration.rs docker/Dockerfile.sshd
git commit -m "feat: add remote (forwarded-tcpip) port forwarding"
```

---

## Phase 1e exit criteria

- [ ] `cargo test -p semicolyn-ssh-core` green against the rebuilt `sshd` fixture; earlier suites unaffected by the `handle` → `Arc<Mutex<_>>` refactor.
- [ ] **Local:** tunnel delivers the remote service's bytes; `bound_port()` reports the OS-assigned port; `close()` frees the port.
- [ ] **Dynamic:** SOCKS5 no-auth CONNECT reaches the target; non-SOCKS5 and unsupported commands get the correct rejection.
- [ ] **Remote:** server-side listener routes an inbound connection back to the device-local target; `close()` cancels it.
- [ ] No silent listener/task leaks — `close()`/`Drop` aborts the accept loop (and its `JoinSet`).
- [ ] Three conventional commits (one per task); new files carry the REUSE header; no new dependency added (SOCKS5 hand-rolled).
- [ ] **macOS-gated / deferred:** the Swift per-forward status UI from `terminal-ux-additions`.

## Self-review notes

- **Why `Arc<Mutex<Handle>>`:** russh's `Handle` is not `Clone` (owns a `receiver` + `JoinHandle`), so listener tasks can't take a copy. Sharing the `Arc` and locking only around `channel_open_direct_tcpip` keeps the data plane (the per-tunnel `copy_bidirectional`) entirely off-lock; the brief control-plane lock is the same one auth/`open_shell` already take.
- **Lifecycle:** every forward holds the accept-loop's `AbortHandle`; the accept loop owns a `JoinSet` of pumps. `close()`/`Drop` aborts the loop → `JoinSet` drops → all tunnels abort and the listener frees its port. Forwards also hold an `Arc<Mutex<Handle>>` clone, so the session outlives the `Connection` value if a forward is still held.
- **Remote-forward routing:** the `ForwardMap` is the only shared mutable state between `Connection` and the russh-owned `ClientHandler`; it's a `std::sync::Mutex<HashMap>` locked only for brief get/insert/remove. The handler spawns the local connect + pump so it never blocks the session loop.
- **SOCKS5 scope:** no-auth CONNECT only, with correct reply codes for unsupported version (silent close)/method (0xFF)/command (0x07)/address type (0x08). Hand-rolled to avoid a dependency and keep the cargo-deny license gate clean. SOCKS4/BIND/UDP-ASSOCIATE are out.
- **Test strategy:** local + dynamic tunnel to sshd's own `127.0.0.1:22` and assert the `SSH-` banner (no extra fixture service); remote stands up a device-local banner listener and connects to the server's `GatewayPorts`-exposed port. Negatives assert the specific SOCKS reply byte (`0x07`) and that a v4 client never gets a v5 success.
- **Risk tier:** Core (I/O plumbing). Good and bad cases per type; the SOCKS negatives are the adversarial-input coverage.
- **Deferred:** dynamic/remote bind-conflict and target-refused edge cases are not exhaustively tested (the local double-bind/refused-after-close cases cover the bind/lifecycle mechanics shared by all three).
