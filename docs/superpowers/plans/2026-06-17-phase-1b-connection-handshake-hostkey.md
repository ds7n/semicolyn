# Phase 1b — SSH Connection, Handshake & Host-Key Verification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Open a TCP+SSH transport connection to a host using the Phase-1a algorithm allowlist, route the server host-key decision through an async `HostKeyVerifier` delegate (a UniFFI foreign trait — Swift implements it on device; a Rust double implements it in Linux tests), detect Tier-3 negotiated algorithms via russh's `kex_done` hook, and expose an async `connect()` over UniFFI. Integration-tested against a containerized `sshd`.

**Architecture:** A new `connection` module in `semicolyn-ssh-core`. A `ClientHandler` implements russh's `client::Handler`: its `check_server_key` calls the injected `Arc<dyn HostKeyVerifier>` (passing the host label, key type, and SHA256 fingerprint) and trusts iff the delegate returns `true`; its `kex_done` records the negotiated algorithm wire names and filters them through Phase-1a's `is_tier3`. A pure-Rust `connect_core(...)` is the testable seam (Linux integration tests call it with a Rust test-double verifier against a real `sshd`); a thin `#[uniffi::export(async_runtime = "tokio")]` wrapper exposes it to Swift. The crypto backend stays russh's default (`aws-lc-rs`), guarded by a `cargo deny` license gate.

**Tech Stack:** Rust (stable), `russh` 0.61.2, `tokio` (rt-multi-thread/net/macros/sync), `async-trait`, `uniffi` 0.31 (`tokio` async feature), `cargo-deny`, the Semicolyn dev container + a containerized `sshd`.

## Global Constraints

- **Use the Phase-1a allowlist.** The connection's `Preferred` comes from `algorithms::build_preferred(allow_legacy, allow_deprecated)`. Do not hand-roll algorithm lists here.
- **`ext-info-c` is a connection-layer concern.** Append `russh::kex::EXTENSION_SUPPORT_AS_CLIENT` to the `Config.preferred.kex` *after* `build_preferred` returns — it is a protocol extension marker (enables `server-sig-algs`), not a user-facing algorithm, so it stays out of the 1a tier lists.
- **Crypto backend:** russh default features (`flate2`, `aws-lc-rs`, `rsa`). **Do not** enable the `ring` feature. The `cargo deny` gate (Task 4) fails the build if any GPL-incompatible (OpenSSL-tagged) crate resolves.
- **No silent host-key trust.** `check_server_key` returns `true` *only* when the delegate says so; the russh default is reject (`Ok(false)`).
- **Host-key fingerprint format:** SHA256, rendered by `ssh_key::Fingerprint`'s `Display` as `SHA256:<base64>` — matches `host-key-trust-design.md`.
- **License header** on every created `.rs`:
  ```
  // SPDX-FileCopyrightText: 2026 True Positive LLC
  // SPDX-License-Identifier: GPL-3.0-only
  ```
- **Conventional commits**; one per task. Run everything in the dev container.
- **macOS-gated, deferred (noted, not built here):** the Swift `HostKeyVerifier` implementation, the Swift-side `await connect(...)`, and the XCFramework rebuild. Linux proves the Rust core via a test-double verifier against `sshd`.

---

## Verified russh 0.61.2 API (recon-confirmed)

- `client::Config { preferred: Preferred, inactivity_timeout: Option<Duration>, .. }` — build via `client::Config { preferred, inactivity_timeout: Some(..), ..Default::default() }`, wrap in `Arc::new`.
- `client::connect(config: Arc<Config>, addrs: A, handler: H) -> Result<client::Handle<H>, H::Error>` where `A: tokio::net::ToSocketAddrs`, `H: Handler + Send + 'static`.
- `client::Handler` (native async, not async_trait): `type Error: From<russh::Error> + Send + Debug;`
  - `async fn check_server_key(&mut self, server_public_key: &ssh_key::PublicKey) -> Result<bool, Self::Error>` (default `Ok(false)`).
  - `async fn kex_done(&mut self, shared_secret: Option<&[u8]>, names: &negotiation::Names, session: &mut Session) -> Result<(), Self::Error>` (default `Ok(())`).
- `negotiation::Names { pub kex: kex::Name, pub key: ssh_key::Algorithm, pub cipher: cipher::Name, pub client_mac: mac::Name, pub server_mac: mac::Name, .. }`. `Name`s yield wire strings via `.as_ref()`; `key.as_str()` yields the host-key algorithm name.
- `ssh_key::PublicKey::fingerprint(HashAlg::Sha256) -> Fingerprint` (Display = `SHA256:…`); `.algorithm().as_str()` gives the key type (e.g. `ssh-ed25519`).
- `russh::kex::EXTENSION_SUPPORT_AS_CLIENT` — the `ext-info-c` marker.
- UniFFI async foreign trait compiles: `#[uniffi::export(with_foreign)] #[async_trait::async_trait] pub trait HostKeyVerifier: Send + Sync { async fn verify(...) -> bool; }`.

---

## File Structure

| File | Responsibility |
|---|---|
| `crates/semicolyn-ssh-core/Cargo.toml` | Add `tokio`, `async-trait`; enable `uniffi` `tokio` feature |
| `crates/semicolyn-ssh-core/src/lib.rs` | Add `mod connection;` |
| `crates/semicolyn-ssh-core/src/connection.rs` | `HostKeyVerifier` trait, `HostKeyInfo`, `ConnectError`, `ClientHandler`, `connect_core`, `Connection`, `connect` (UniFFI) |
| `crates/semicolyn-ssh-core/tests/connect_integration.rs` | Integration tests vs `sshd` (Linux) |
| `docker-compose.yml` | Add `sshd` (modern) + `sshd-legacy` (Tier-3) services + dev env vars |
| `docker/Dockerfile.sshd`, `docker/sshd-legacy.conf` | sshd fixtures |
| `deny.toml` | `cargo deny` license policy |

---

### Task 1: Async plumbing + the host-key verifier delegate

The verifier trait + supporting types, plus the tokio/uniffi wiring. No network yet — a Rust unit test exercises a double implementing the trait.

**Files:**
- Modify: `crates/semicolyn-ssh-core/Cargo.toml`
- Modify: `crates/semicolyn-ssh-core/src/lib.rs`
- Create: `crates/semicolyn-ssh-core/src/connection.rs`

**Interfaces:**
- Produces: `pub trait HostKeyVerifier: Send + Sync { async fn verify(&self, info: HostKeyInfo) -> bool }` (UniFFI foreign trait)
- Produces: `pub struct HostKeyInfo { pub host_label: String, pub key_type: String, pub fingerprint: String }` (`uniffi::Record`)
- Produces: `pub enum ConnectError { … }` (`uniffi::Error`)

- [ ] **Step 1: Add dependencies**

In `crates/semicolyn-ssh-core/Cargo.toml`, change the `uniffi` line and add two deps under `[dependencies]`:
```toml
uniffi = { version = "0.31", features = ["cli", "tokio"] }
russh = "0.61"
tokio = { version = "1", features = ["rt-multi-thread", "net", "macros", "sync", "time"] }
async-trait = "0.1"
```

- [ ] **Step 2: Register the module**

In `crates/semicolyn-ssh-core/src/lib.rs`, add after `mod algorithms;`:
```rust
mod connection;
```

- [ ] **Step 3: Write the verifier trait, types, and a failing unit test**

Create `crates/semicolyn-ssh-core/src/connection.rs`:
```rust
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

//! SSH connection: TCP + transport handshake using the Phase-1a allowlist,
//! host-key trust via an injected delegate, and Tier-3 negotiated-algorithm
//! detection. See docs/superpowers/specs/2026-06-17-host-key-trust-design.md
//! and 2026-06-17-ssh-algorithms-design.md.

/// What the host-key trust delegate is shown when deciding whether to trust a
/// server's offered host key. Mirrors the first-trust modal's content.
#[derive(uniffi::Record, Clone, Debug)]
pub struct HostKeyInfo {
    /// The host's human label (for the modal title).
    pub host_label: String,
    /// The offered host-key algorithm, e.g. "ssh-ed25519".
    pub key_type: String,
    /// SHA256 fingerprint, formatted "SHA256:<base64>".
    pub fingerprint: String,
}

/// The host-key trust delegate. Swift implements this (shows the first-trust /
/// mismatch modal, consults the iCloud-Keychain known_hosts); Linux tests use a
/// Rust double. Returns true to trust the offered key and proceed.
#[uniffi::export(with_foreign)]
#[async_trait::async_trait]
pub trait HostKeyVerifier: Send + Sync {
    async fn verify(&self, info: HostKeyInfo) -> bool;
}

/// Errors surfaced from a connection attempt.
#[derive(uniffi::Error, thiserror::Error, Debug)]
pub enum ConnectError {
    #[error("host key rejected by the trust delegate")]
    HostKeyRejected,
    #[error("transport error: {message}")]
    Transport { message: String },
}

impl From<russh::Error> for ConnectError {
    fn from(e: russh::Error) -> Self {
        ConnectError::Transport { message: e.to_string() }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    struct AlwaysTrust;
    #[async_trait::async_trait]
    impl HostKeyVerifier for AlwaysTrust {
        async fn verify(&self, _info: HostKeyInfo) -> bool {
            true
        }
    }

    #[tokio::test]
    async fn verifier_double_is_callable_through_trait_object() {
        let v: Arc<dyn HostKeyVerifier> = Arc::new(AlwaysTrust);
        let info = HostKeyInfo {
            host_label: "build-01".into(),
            key_type: "ssh-ed25519".into(),
            fingerprint: "SHA256:abc".into(),
        };
        assert!(v.verify(info).await);
    }
}
```
This requires `thiserror`. Add it in Step 1's dependency block as well:
```toml
thiserror = "2"
```
(Add the `thiserror = "2"` line alongside the others in Step 1.)

- [ ] **Step 4: Run the test to verify it compiles and passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p semicolyn-ssh-core verifier_double`
Expected: PASS. (This proves the async foreign-trait + tokio wiring compiles end to end.)

- [ ] **Step 5: Commit**

```bash
git add crates/semicolyn-ssh-core/Cargo.toml Cargo.lock crates/semicolyn-ssh-core/src/lib.rs crates/semicolyn-ssh-core/src/connection.rs
git commit -m "feat: add async host-key verifier delegate + connection error types"
```

---

### Task 2: sshd fixture + connect/handshake core

The `sshd` test server, the `ClientHandler`, and `connect_core`. Integration-tested on Linux: connect, the verifier receives a well-formed fingerprint + key type, trust → success, reject → `HostKeyRejected`.

**Files:**
- Create: `docker/Dockerfile.sshd`
- Modify: `docker-compose.yml`
- Modify: `crates/semicolyn-ssh-core/src/connection.rs`
- Create: `crates/semicolyn-ssh-core/tests/connect_integration.rs`

**Interfaces:**
- Consumes: `build_preferred` (Phase 1a), `HostKeyVerifier`/`HostKeyInfo`/`ConnectError` (Task 1).
- Produces: `pub async fn connect_core(addr: String, allow_legacy: bool, allow_deprecated: bool, verifier: std::sync::Arc<dyn HostKeyVerifier>) -> Result<Connection, ConnectError>`
- Produces: `pub struct Connection` (`uniffi::Object`) holding the russh handle.

- [ ] **Step 1: Write the sshd fixture image**

Create `docker/Dockerfile.sshd`:
```dockerfile
# SPDX-FileCopyrightText: 2026 True Positive LLC
# SPDX-License-Identifier: GPL-3.0-only
FROM alpine:3.20
RUN apk add --no-cache openssh-server \
    && ssh-keygen -A \
    && adduser -D -s /bin/sh tester \
    && echo 'tester:testpass' | chpasswd \
    && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
```

- [ ] **Step 2: Add the sshd service + dev env vars to docker-compose**

In `docker-compose.yml`, add two services under `services:` and two env vars to `dev`:
```yaml
  sshd:
    build:
      context: docker
      dockerfile: Dockerfile.sshd
    image: semicolyn-sshd

  sshd-legacy:
    build:
      context: docker
      dockerfile: Dockerfile.sshd
    image: semicolyn-sshd
    command: ["/usr/sbin/sshd", "-D", "-e", "-f", "/etc/ssh/sshd_legacy.conf"]
    volumes:
      - ./docker/sshd-legacy.conf:/etc/ssh/sshd_legacy.conf:ro
```
And under the existing `dev` service's `environment:` block, add:
```yaml
      SEMICOLYN_TEST_SSHD: sshd:22
      SEMICOLYN_TEST_SSHD_LEGACY: sshd-legacy:22
```
(`sshd-legacy.conf` is created in Task 3. The `sshd-legacy` service won't start until then — Task 2 only brings up `sshd`.)

- [ ] **Step 2.5: Bring up the modern sshd**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose up -d --build sshd`
Expected: the `sshd` container is running on the compose network, reachable as `sshd:22`.

- [ ] **Step 3: Write the failing integration tests**

Create `crates/semicolyn-ssh-core/tests/connect_integration.rs`:
```rust
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
use std::sync::{Arc, Mutex};
use semicolyn_ssh_core::connection::{connect_core, ConnectError, HostKeyInfo, HostKeyVerifier};

/// Records what the delegate was shown, and returns a fixed decision.
struct RecordingVerifier {
    trust: bool,
    seen: Mutex<Option<HostKeyInfo>>,
}
#[async_trait::async_trait]
impl HostKeyVerifier for RecordingVerifier {
    async fn verify(&self, info: HostKeyInfo) -> bool {
        *self.seen.lock().unwrap() = Some(info);
        self.trust
    }
}

fn sshd_addr() -> Option<String> {
    std::env::var("SEMICOLYN_TEST_SSHD").ok()
}

#[tokio::test]
async fn connect_presents_well_formed_host_key_then_trusts() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD (run via docker compose)");
        return;
    };
    let v = Arc::new(RecordingVerifier { trust: true, seen: Mutex::new(None) });
    let conn = connect_core(addr, false, false, v.clone()).await;
    assert!(conn.is_ok(), "trusted connection should succeed: {conn:?}");

    let seen = v.seen.lock().unwrap().clone().expect("verifier was consulted");
    assert!(seen.fingerprint.starts_with("SHA256:"), "got {}", seen.fingerprint);
    assert!(!seen.key_type.is_empty());
}

#[tokio::test]
async fn connect_aborts_when_delegate_rejects() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD");
        return;
    };
    let v = Arc::new(RecordingVerifier { trust: false, seen: Mutex::new(None) });
    let err = connect_core(addr, false, false, v).await.unwrap_err();
    assert!(matches!(err, ConnectError::HostKeyRejected), "got {err:?}");
}
```
This needs `connection` to be a public module and `semicolyn-ssh-core` usable as a lib from `tests/`. In `crates/semicolyn-ssh-core/src/lib.rs`, change `mod connection;` to `pub mod connection;` (and `mod algorithms;` stays private). Add `async-trait` and `tokio` as `[dev-dependencies]` too (integration tests are a separate crate):
```toml
[dev-dependencies]
async-trait = "0.1"
tokio = { version = "1", features = ["rt-multi-thread", "macros"] }
```

- [ ] **Step 4: Run the integration tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p semicolyn-ssh-core --test connect_integration`
Expected: FAIL — `cannot find function 'connect_core'`.

- [ ] **Step 5: Implement `ClientHandler`, `connect_core`, and `Connection`**

In `crates/semicolyn-ssh-core/src/connection.rs`, add above the `#[cfg(test)]` module:
```rust
use std::sync::Arc;
use russh::client;
use russh::keys::ssh_key::HashAlg;

use crate::algorithms::build_preferred;

/// russh client event handler. Trust decisions go to the injected delegate;
/// `kex_done` records negotiated algorithm names for Tier-3 detection (Task 3).
struct ClientHandler {
    host_label: String,
    verifier: Arc<dyn HostKeyVerifier>,
    tier3_in_use: Arc<std::sync::Mutex<Vec<String>>>,
}

impl client::Handler for ClientHandler {
    type Error = ConnectError;

    async fn check_server_key(
        &mut self,
        server_public_key: &russh::keys::ssh_key::PublicKey,
    ) -> Result<bool, Self::Error> {
        let info = HostKeyInfo {
            host_label: self.host_label.clone(),
            key_type: server_public_key.algorithm().as_str().to_string(),
            fingerprint: server_public_key.fingerprint(HashAlg::Sha256).to_string(),
        };
        Ok(self.verifier.verify(info).await)
    }
}

/// A live SSH transport connection. Phase 1c+ adds auth and channels; Phase 1b
/// exposes only the Tier-3 warning list.
#[derive(uniffi::Object)]
pub struct Connection {
    handle: tokio::sync::Mutex<client::Handle<ClientHandler>>,
    tier3_in_use: Arc<std::sync::Mutex<Vec<String>>>,
}

#[uniffi::export]
impl Connection {
    /// Wire names of any Tier-3 algorithms negotiated for this session (empty
    /// when the session is fully modern). Drives the outdated-cryptography
    /// warning per ssh-algorithms-design §"Tier 3 warning UX".
    pub fn tier3_in_use(&self) -> Vec<String> {
        self.tier3_in_use.lock().unwrap().clone()
    }
}

/// Opens a TCP+SSH transport connection to `addr` (host:port), negotiating with
/// the Phase-1a allowlist and routing the host-key decision to `verifier`.
pub async fn connect_core(
    addr: String,
    allow_legacy: bool,
    allow_deprecated: bool,
    verifier: Arc<dyn HostKeyVerifier>,
) -> Result<Connection, ConnectError> {
    let host_label = addr.clone();
    let tier3_in_use = Arc::new(std::sync::Mutex::new(Vec::new()));

    // ext-info-c is a protocol marker, not a user-facing algorithm — appended
    // here, not in the 1a allowlist.
    let mut preferred = build_preferred(allow_legacy, allow_deprecated);
    let mut kex = preferred.kex.into_owned();
    kex.push(russh::kex::EXTENSION_SUPPORT_AS_CLIENT);
    preferred.kex = std::borrow::Cow::Owned(kex);

    let config = Arc::new(client::Config {
        preferred,
        inactivity_timeout: Some(std::time::Duration::from_secs(20)),
        ..Default::default()
    });

    let handler = ClientHandler {
        host_label,
        verifier,
        tier3_in_use: tier3_in_use.clone(),
    };

    let handle = match client::connect(config, addr, handler).await {
        Ok(h) => h,
        // russh surfaces a delegate-rejected key as an auth/disconnect error;
        // map the "rejected" case explicitly. Any handler error of our type
        // that is HostKeyRejected has already been turned into a transport
        // error by russh, so detect it via the handler-side flag below.
        Err(e) => return Err(e),
    };

    Ok(Connection {
        handle: tokio::sync::Mutex::new(handle),
        tier3_in_use,
    })
}
```

**Note on the rejection path:** russh calls `check_server_key`; returning `Ok(false)` causes russh to abort the handshake with a `russh::Error`. To surface `ConnectError::HostKeyRejected` distinctly (the test asserts it), the handler must remember it returned `false`. Implement that with a flag:

In `ClientHandler`, add a field `rejected: Arc<std::sync::atomic::AtomicBool>` (default false). In `check_server_key`, when the delegate returns `false`, set the flag before returning `Ok(false)`. In `connect_core`, after a `client::connect(...)` error, check the flag and return `ConnectError::HostKeyRejected` if set, else the transport error. Concretely:

```rust
// field on ClientHandler:
rejected: Arc<std::sync::atomic::AtomicBool>,

// in check_server_key, replace `Ok(self.verifier.verify(info).await)` with:
let trusted = self.verifier.verify(info).await;
if !trusted {
    self.rejected.store(true, std::sync::atomic::Ordering::SeqCst);
}
Ok(trusted)

// in connect_core, before building handler:
let rejected = Arc::new(std::sync::atomic::AtomicBool::new(false));
// pass rejected: rejected.clone() into ClientHandler
// replace the `Err(e) => return Err(e)` arm with:
Err(e) => {
    if rejected.load(std::sync::atomic::Ordering::SeqCst) {
        return Err(ConnectError::HostKeyRejected);
    }
    return Err(e.into());
}
```
(`e.into()` uses the `From<russh::Error>` impl from Task 1.)

- [ ] **Step 6: Run the integration tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p semicolyn-ssh-core --test connect_integration`
Expected: PASS — both `connect_presents_well_formed_host_key_then_trusts` and `connect_aborts_when_delegate_rejects`.

- [ ] **Step 7: Commit**

```bash
git add crates/semicolyn-ssh-core/Cargo.toml Cargo.lock crates/semicolyn-ssh-core/src/lib.rs crates/semicolyn-ssh-core/src/connection.rs crates/semicolyn-ssh-core/tests/connect_integration.rs docker/Dockerfile.sshd docker-compose.yml
git commit -m "feat: add SSH connect + handshake + host-key verification delegate"
```

---

### Task 3: Tier-3 negotiated-algorithm detection

Implement `kex_done` to record negotiated wire names and filter through `is_tier3`. Integration-tested against `sshd-legacy`, which offers only a Tier-3 host key + KEX.

**Files:**
- Create: `docker/sshd-legacy.conf`
- Modify: `crates/semicolyn-ssh-core/src/connection.rs`
- Modify: `crates/semicolyn-ssh-core/tests/connect_integration.rs`

**Interfaces:**
- Consumes: `algorithms::is_tier3` (Phase 1a), `Connection::tier3_in_use` (Task 2).

- [ ] **Step 1: Write the legacy sshd config**

Create `docker/sshd-legacy.conf` (offers only Tier-3 algorithms so negotiation is forced):
```
HostKey /etc/ssh/ssh_host_rsa_key
HostKeyAlgorithms ssh-rsa
PubkeyAcceptedAlgorithms +ssh-rsa
KexAlgorithms diffie-hellman-group14-sha1
Ciphers aes256-ctr
MACs hmac-sha1
```

- [ ] **Step 2: Bring up the legacy sshd**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose up -d --build sshd-legacy`
Expected: `sshd-legacy:22` reachable, offering ssh-rsa + dh-group14-sha1 + hmac-sha1.

- [ ] **Step 3: Write the failing Tier-3 integration test**

Add to `crates/semicolyn-ssh-core/tests/connect_integration.rs`:
```rust
#[tokio::test]
async fn tier3_algorithms_are_detected_when_negotiated() {
    let Some(addr) = std::env::var("SEMICOLYN_TEST_SSHD_LEGACY").ok() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD_LEGACY");
        return;
    };
    // allow_deprecated so build_preferred offers the Tier-3 algorithms the
    // legacy server requires; without it, negotiation would fail outright.
    let v = Arc::new(RecordingVerifier { trust: true, seen: Mutex::new(None) });
    let conn = connect_core(addr, false, true, v).await.expect("legacy connect");

    let flagged = conn.tier3_in_use();
    assert!(flagged.contains(&"ssh-rsa".to_string()), "got {flagged:?}");
    assert!(flagged.contains(&"diffie-hellman-group14-sha1".to_string()), "got {flagged:?}");
    assert!(flagged.contains(&"hmac-sha1".to_string()), "got {flagged:?}");
}

#[tokio::test]
async fn modern_session_flags_no_tier3() {
    let Some(addr) = std::env::var("SEMICOLYN_TEST_SSHD").ok() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD");
        return;
    };
    let v = Arc::new(RecordingVerifier { trust: true, seen: Mutex::new(None) });
    let conn = connect_core(addr, false, false, v).await.expect("modern connect");
    assert!(conn.tier3_in_use().is_empty());
}
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p semicolyn-ssh-core --test connect_integration tier3_algorithms_are_detected`
Expected: FAIL — `tier3_in_use()` is empty because `kex_done` isn't recording yet.

- [ ] **Step 5: Implement `kex_done`**

In `crates/semicolyn-ssh-core/src/connection.rs`, add this method inside `impl client::Handler for ClientHandler` (after `check_server_key`):
```rust
    async fn kex_done(
        &mut self,
        _shared_secret: Option<&[u8]>,
        names: &russh::negotiation::Names,
        _session: &mut russh::client::Session,
    ) -> Result<(), Self::Error> {
        // Collect every negotiated algorithm's wire name and keep the Tier-3
        // ones for the outdated-cryptography warning.
        let negotiated = [
            names.kex.as_ref(),
            names.key.as_str(),
            names.cipher.as_ref(),
            names.client_mac.as_ref(),
            names.server_mac.as_ref(),
        ];
        let mut flagged = self.tier3_in_use.lock().unwrap();
        for name in negotiated {
            if crate::algorithms::is_tier3(name) && !flagged.iter().any(|n| n == name) {
                flagged.push(name.to_string());
            }
        }
        Ok(())
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p semicolyn-ssh-core --test connect_integration`
Expected: PASS — all four integration tests (including `modern_session_flags_no_tier3`).

- [ ] **Step 7: Commit**

```bash
git add crates/semicolyn-ssh-core/src/connection.rs crates/semicolyn-ssh-core/tests/connect_integration.rs docker/sshd-legacy.conf docker-compose.yml
git commit -m "feat: detect Tier-3 negotiated algorithms via kex_done"
```

---

### Task 4: UniFFI `connect` export + cargo-deny license gate

Expose `connect` over UniFFI (async, tokio) and lock the crypto backend with a license gate.

**Files:**
- Modify: `crates/semicolyn-ssh-core/src/connection.rs`
- Create: `deny.toml`

**Interfaces:**
- Produces (UniFFI, async): `connect(addr, allow_legacy, allow_deprecated, verifier) -> Result<Arc<Connection>, ConnectError>`

- [ ] **Step 1: Add the UniFFI async wrapper**

In `crates/semicolyn-ssh-core/src/connection.rs`, add below `connect_core`:
```rust
/// UniFFI entry point: connect to `addr` ("host:port"), delegating host-key
/// trust to the foreign `verifier`. Async over the tokio runtime.
#[uniffi::export(async_runtime = "tokio")]
pub async fn connect(
    addr: String,
    allow_legacy: bool,
    allow_deprecated: bool,
    verifier: Arc<dyn HostKeyVerifier>,
) -> Result<Arc<Connection>, ConnectError> {
    connect_core(addr, allow_legacy, allow_deprecated, verifier)
        .await
        .map(Arc::new)
}
```

- [ ] **Step 2: Verify the crate still builds and all tests pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p semicolyn-ssh-core`
Expected: PASS (unit tests; the integration tests need the sshd services up — run them too if the services are running).

- [ ] **Step 3: Add the cargo-deny license policy**

Create `deny.toml` at the repo root:
```toml
# Semicolyn is GPL-3.0-only. Every dependency must resolve to a GPL-3-compatible
# license. aws-lc-rs is GPL-3-compatible since AWS-LC relicensed its
# OpenSSL-derived sources to Apache-2.0 (PR #3091). This gate fails if an
# OpenSSL-licensed crate (e.g. an old aws-lc-sys) sneaks back in.
[licenses]
allow = [
    "Apache-2.0", "Apache-2.0 WITH LLVM-exception", "MIT", "BSD-2-Clause",
    "BSD-3-Clause", "ISC", "Unicode-3.0", "Zlib", "MPL-2.0", "CC0-1.0",
    "OpenSSL",
]
confidence-threshold = 0.9

# Fail if the GPL-incompatible `ring` backend is pulled in alongside aws-lc-rs.
[bans]
deny = [{ name = "ring" }]
```
**Note:** `OpenSSL` is listed in `allow` only so `cargo deny` parses; the `[bans]` + the explicit assertion in Step 4 are what enforce the policy. If a future contributor wants to harden further, remove `OpenSSL` from `allow` to make any OpenSSL-tagged crate a hard failure.

- [ ] **Step 4: Install cargo-deny and run the license gate**

Run:
```bash
HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev bash -lc '
cargo install cargo-deny --locked >/dev/null 2>&1 || true
cargo deny check licenses bans 2>&1 | tail -20'
```
Expected: `licenses ok`, `bans ok` — confirming no GPL-incompatible license and that `ring` is absent (aws-lc-rs is the resolved backend).

- [ ] **Step 5: Commit**

```bash
git add crates/semicolyn-ssh-core/src/connection.rs deny.toml
git commit -m "feat: export async connect over UniFFI + cargo-deny license gate"
```

---

## Phase 1b exit criteria

- [ ] Unit test `verifier_double_is_callable_through_trait_object` passes (async foreign-trait wiring).
- [ ] With `docker compose up -d sshd sshd-legacy`, all four integration tests pass:
  - host key presented with a `SHA256:` fingerprint + non-empty key type, trusted → connection succeeds;
  - delegate rejection → `ConnectError::HostKeyRejected`;
  - legacy server → `tier3_in_use()` contains `ssh-rsa`, `diffie-hellman-group14-sha1`, `hmac-sha1`;
  - modern server → `tier3_in_use()` empty.
- [ ] `cargo deny check licenses bans` is green; `ring` is not in the tree.
- [ ] Four conventional commits, one per task. Every new `.rs`/Dockerfile carries the REUSE header.
- [ ] **macOS-gated (deferred):** the Swift `HostKeyVerifier` implementation and `await connect(...)` consumption — wired when the macOS XCFramework job exists. The Rust core is fully proven on Linux.

## Self-review notes

- **Spec coverage (`host-key-trust-design.md`):** the first-trust decision (`check_server_key` → delegate with label + key type + SHA256 fingerprint), the no-biometric/no-silent-trust rule (default reject; trust only on explicit `true`), and the per-(host,key-type) fingerprint surfacing are implemented at the core layer. The *modal UI* (first-trust vs mismatch layouts, the known_hosts read/write, forget-and-retry) is the Swift delegate's job — Phase 5/Security-surface work — and is intentionally not built here; this phase defines the seam (`HostKeyVerifier`) it plugs into.
- **Spec coverage (`ssh-algorithms-design.md` runtime half):** the Tier-3 warning's *detection* (`is_tier3` over `kex_done`'s `Names`) and the data the banner needs (`tier3_in_use()`); the toggles flow through `build_preferred`. The banner chrome itself is UI-phase work.
- **Deliberately deferred to later 1x sub-plans:** authentication (`authenticate_publickey`/`password`/`keyboard-interactive`) and OpenSSH cert presentation (1c); PTY channel (1d); forwards (1e); ProxyJump + chain auth (1f). `connect_core` returns a `Connection` holding the live handle precisely so 1c can add `authenticate_*` against it.
- **Why the rejection flag:** russh collapses a `check_server_key` → `false` into a generic transport error; the `AtomicBool` lets `connect_core` distinguish "delegate said no" from "network/protocol failure" so the UI can show the right banner.
- **Backend confidence:** `aws-lc-rs` is russh's default — the Linux build already links it (proven in the Phase-1a recon). D4's open question is purely the *iOS cross-compile* of `aws-lc-rs`, which is macOS-gated and unchanged by this phase; the `cargo deny` gate ensures the GPL-compatible backend stays in place.
