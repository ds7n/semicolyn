# Phase 1c — SSH Authentication (publickey / password / keyboard-interactive)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the three non-certificate SSH authentication methods on top of the Phase-1b `Connection`: password, publickey, and keyboard-interactive. Each is an async method on `Connection` (exported over UniFFI) that drives the live russh handle and returns a typed `AuthOutcome`. Integration-tested against the `sshd` fixture. **OpenSSH certificate auth is a separate follow-on plan (1c-cert)** — it needs a CA fixture and is split out per the scope decision.

**Architecture:** Phase 1b's `connect_core` returns a `Connection` holding `tokio::sync::Mutex<client::Handle<ClientHandler>>`. This phase adds `authenticate_*` methods on `Connection` that lock the handle and call russh's `authenticate_password` / `authenticate_publickey` / `authenticate_keyboard_interactive_*`, mapping russh's `AuthResult` to a UniFFI `AuthOutcome` (`Success` / `PartialSuccess` / `Failure`). Private keys are loaded in-memory from OpenSSH PEM via `ssh_key::PrivateKey::from_openssh` (the SE/Keychain-backed `Signer` path is Phase 2 / macOS, deferred). The `sshd` fixture gains a shared-volume test keypair (no secret is committed) and, for keyboard-interactive, PAM.

**Tech Stack:** Rust, `russh` 0.61.2, `tokio`, `uniffi` 0.31, the dev container + the `sshd` fixture.

## Global Constraints

- **Auth happens after connect.** `Connection` already holds a live, host-key-verified handle; these methods only authenticate.
- **No secret committed to the repo.** The publickey test keypair is generated at fixture startup into a shared Docker volume; the test reads it from `/testkeys/`. Nothing private lands in git (matches the project's pre-public privacy posture).
- **In-memory keys only this phase.** `ssh_key::PrivateKey::from_openssh`. The SE/Keychain `Signer` (hardware-bound signing) is Phase 2 + macOS, not built here.
- **Typed outcomes, not panics.** Map `AuthResult::Failure { partial_success }` → `PartialSuccess`/`Failure`; never treat a failed auth as an error (a wrong password is a normal `Failure`, not a `ConnectError`).
- **License header** on every created `.rs`/script; **conventional commits**, one per task; run everything in the dev container.
- **macOS-gated, deferred:** the Swift consumption of these async methods and the SE-backed `Signer`.

---

## Verified russh 0.61.2 API (recon-confirmed)

- `Handle::authenticate_password<U,P: Into<String>>(user, password) -> Result<AuthResult, russh::Error>`
- `Handle::authenticate_publickey<U: Into<String>>(user, key: PrivateKeyWithHashAlg) -> Result<AuthResult, russh::Error>`
- `Handle::best_supported_rsa_hash() -> Result<Option<Option<HashAlg>>, russh::Error>` (for RSA keys; ignored for others)
- `Handle::authenticate_keyboard_interactive_start<U, S: Into<Option<String>>>(user, submethods) -> Result<KeyboardInteractiveAuthResponse, russh::Error>`
- `Handle::authenticate_keyboard_interactive_respond(responses: Vec<String>) -> Result<KeyboardInteractiveAuthResponse, russh::Error>`
- `russh::client::AuthResult { Success, Failure { remaining_methods: MethodSet, partial_success: bool } }` (re-exported at `russh::client::AuthResult`)
- `russh::client::KeyboardInteractiveAuthResponse { Success, Failure { remaining_methods, partial_success }, InfoRequest { name, instructions, prompts } }`
- `russh::keys::PrivateKeyWithHashAlg::new(key: Arc<PrivateKey>, hash_alg: Option<HashAlg>)`
- `russh::keys::PrivateKey::from_openssh(pem: impl AsRef<[u8]>) -> Result<PrivateKey, _>` (= `ssh_key::PrivateKey`)

---

## File Structure

| File | Responsibility |
|---|---|
| `crates/semicolyn-ssh-core/src/connection.rs` | `AuthOutcome`, `outcome()`, three `authenticate_*` methods on `Connection` |
| `crates/semicolyn-ssh-core/tests/auth_integration.rs` | Auth integration tests vs `sshd` |
| `docker/sshd-entrypoint.sh` | Generate the shared test keypair + install authorized_keys at startup |
| `docker/Dockerfile.sshd` | Use the entrypoint; add PAM for keyboard-interactive |
| `docker-compose.yml` | `testkeys` shared volume; mount it in `dev` (ro) and `sshd` |

---

### Task 1: AuthOutcome + password authentication

**Files:**
- Modify: `crates/semicolyn-ssh-core/src/connection.rs`
- Create: `crates/semicolyn-ssh-core/tests/auth_integration.rs`

**Interfaces:**
- Consumes: `Connection`, `ConnectError`, `connect_core` (Phase 1b).
- Produces: `pub enum AuthOutcome { Success, PartialSuccess, Failure }` (`uniffi::Enum`)
- Produces: `Connection::authenticate_password(&self, user: String, password: String) -> Result<AuthOutcome, ConnectError>` (async, UniFFI)

- [ ] **Step 1: Write the failing integration tests**

Create `crates/semicolyn-ssh-core/tests/auth_integration.rs`:
```rust
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
use std::sync::{Arc, Mutex};
use semicolyn_ssh_core::connection::{connect_core, AuthOutcome, HostKeyInfo, HostKeyVerifier};

struct TrustAll;
#[async_trait::async_trait]
impl HostKeyVerifier for TrustAll {
    async fn verify(&self, _info: HostKeyInfo) -> bool { true }
}

fn sshd_addr() -> Option<String> { std::env::var("SEMICOLYN_TEST_SSHD").ok() }

#[tokio::test]
async fn password_auth_succeeds_with_correct_credentials() {
    let Some(addr) = sshd_addr() else { eprintln!("skipping: set SEMICOLYN_TEST_SSHD"); return };
    let conn = connect_core(addr, false, false, Arc::new(TrustAll)).await.expect("connect");
    let outcome = conn.authenticate_password("tester".into(), "testpass".into()).await.expect("auth call");
    assert_eq!(outcome, AuthOutcome::Success);
}

#[tokio::test]
async fn password_auth_fails_with_wrong_password() {
    let Some(addr) = sshd_addr() else { eprintln!("skipping: set SEMICOLYN_TEST_SSHD"); return };
    let conn = connect_core(addr, false, false, Arc::new(TrustAll)).await.expect("connect");
    let outcome = conn.authenticate_password("tester".into(), "wrong".into()).await.expect("auth call");
    assert_eq!(outcome, AuthOutcome::Failure);
}

// silence unused import warning until Task 2 uses Mutex
#[allow(dead_code)]
fn _uses_mutex() -> Mutex<()> { Mutex::new(()) }
```

- [ ] **Step 2: Run the tests to verify they fail**

Ensure `sshd` is up: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose up -d sshd`
Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p semicolyn-ssh-core --test auth_integration`
Expected: FAIL — `no method named 'authenticate_password'` / `cannot find type 'AuthOutcome'`.

- [ ] **Step 3: Implement `AuthOutcome` + `outcome()`**

In `crates/semicolyn-ssh-core/src/connection.rs`, add after the `ConnectError` block:
```rust
/// The result of an authentication attempt. A failed auth is a normal outcome,
/// not a `ConnectError` — the caller decides what to do (retry, try another
/// method, surface the connect-failed banner).
#[derive(uniffi::Enum, Debug, PartialEq, Eq)]
pub enum AuthOutcome {
    /// Authentication fully succeeded; the session is usable.
    Success,
    /// The method was accepted but the server requires another method too
    /// (multi-factor). Caller should authenticate again with a further method.
    PartialSuccess,
    /// Authentication failed.
    Failure,
}

fn outcome(result: russh::client::AuthResult) -> AuthOutcome {
    match result {
        russh::client::AuthResult::Success => AuthOutcome::Success,
        russh::client::AuthResult::Failure { partial_success: true, .. } => AuthOutcome::PartialSuccess,
        russh::client::AuthResult::Failure { .. } => AuthOutcome::Failure,
    }
}
```

- [ ] **Step 4: Implement `authenticate_password`**

In `crates/semicolyn-ssh-core/src/connection.rs`, add a new exported impl block (separate from the existing `#[uniffi::export] impl Connection` so the async-runtime attribute applies):
```rust
#[uniffi::export(async_runtime = "tokio")]
impl Connection {
    /// Password authentication. Returns the typed outcome; a wrong password is
    /// `Failure`, not an error.
    pub async fn authenticate_password(
        &self,
        user: String,
        password: String,
    ) -> Result<AuthOutcome, ConnectError> {
        let mut handle = self.handle.lock().await;
        Ok(outcome(handle.authenticate_password(user, password).await?))
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p semicolyn-ssh-core --test auth_integration`
Expected: PASS — both password tests.

- [ ] **Step 6: Commit**

```bash
git add crates/semicolyn-ssh-core/src/connection.rs crates/semicolyn-ssh-core/tests/auth_integration.rs
git commit -m "feat: add password authentication with typed AuthOutcome"
```

---

### Task 2: Publickey authentication + shared-volume test keypair

**Files:**
- Create: `docker/sshd-entrypoint.sh`
- Modify: `docker/Dockerfile.sshd`
- Modify: `docker-compose.yml`
- Modify: `crates/semicolyn-ssh-core/src/connection.rs`
- Modify: `crates/semicolyn-ssh-core/tests/auth_integration.rs`

**Interfaces:**
- Produces: `Connection::authenticate_publickey(&self, user: String, private_key_openssh: String) -> Result<AuthOutcome, ConnectError>` (async, UniFFI)

- [ ] **Step 1: Write the sshd entrypoint (generates the test keypair, no secret in git)**

Create `docker/sshd-entrypoint.sh`:
```sh
#!/bin/sh
# SPDX-FileCopyrightText: 2026 True Positive LLC
# SPDX-License-Identifier: GPL-3.0-only
set -e
ssh-keygen -A
mkdir -p /home/tester/.ssh
# Generate a throwaway test keypair into the shared volume on first boot.
if [ ! -f /testkeys/id_ed25519 ]; then
  ssh-keygen -t ed25519 -N '' -C 'semicolyn-test' -f /testkeys/id_ed25519
fi
# World-readable so the (non-root) dev container can read the private key.
# This is a disposable CI fixture key, never a real credential.
chmod 644 /testkeys/id_ed25519 /testkeys/id_ed25519.pub
cp /testkeys/id_ed25519.pub /home/tester/.ssh/authorized_keys
chown -R tester:tester /home/tester/.ssh
chmod 700 /home/tester/.ssh
chmod 600 /home/tester/.ssh/authorized_keys
exec "$@"
```

- [ ] **Step 2: Wire the entrypoint into the image**

Replace `docker/Dockerfile.sshd` with:
```dockerfile
# SPDX-FileCopyrightText: 2026 True Positive LLC
# SPDX-License-Identifier: GPL-3.0-only
FROM alpine:3.20
RUN apk add --no-cache openssh-server \
    && adduser -D -s /bin/sh tester \
    && echo 'tester:testpass' | chpasswd \
    && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
COPY sshd-entrypoint.sh /sshd-entrypoint.sh
RUN chmod +x /sshd-entrypoint.sh
EXPOSE 22
ENTRYPOINT ["/sshd-entrypoint.sh"]
CMD ["/usr/sbin/sshd", "-D", "-e"]
```
(`ssh-keygen -A` moves into the entrypoint so it runs at boot; the `sshd-legacy` service's `command:` override still flows through the entrypoint as `"$@"`, so its keygen + config still apply.)

- [ ] **Step 3: Add the shared volume to docker-compose**

In `docker-compose.yml`: add `testkeys:/testkeys` to both `dev` (read-only) and `sshd`, and declare the volume.
- Under `dev` → `volumes:` add: `- testkeys:/testkeys:ro`
- Under `sshd` add a `volumes:` block: `- testkeys:/testkeys`
- Under `sshd-legacy` add the same: `- testkeys:/testkeys` (keeps the shared entrypoint happy)
- Under the top-level `volumes:` add: `testkeys:`

- [ ] **Step 4: Rebuild + restart sshd, then write the failing publickey test**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose up -d --build sshd`

Add to `crates/semicolyn-ssh-core/tests/auth_integration.rs`:
```rust
#[tokio::test]
async fn publickey_auth_succeeds_with_authorized_key() {
    let Some(addr) = sshd_addr() else { eprintln!("skipping: set SEMICOLYN_TEST_SSHD"); return };
    let key = match std::fs::read_to_string("/testkeys/id_ed25519") {
        Ok(k) => k,
        Err(_) => { eprintln!("skipping: /testkeys/id_ed25519 not mounted"); return }
    };
    let conn = connect_core(addr, false, false, Arc::new(TrustAll)).await.expect("connect");
    let outcome = conn.authenticate_publickey("tester".into(), key).await.expect("auth call");
    assert_eq!(outcome, AuthOutcome::Success);
}
```

- [ ] **Step 5: Run the test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p semicolyn-ssh-core --test auth_integration publickey_auth_succeeds`
Expected: FAIL — `no method named 'authenticate_publickey'`.

- [ ] **Step 6: Implement `authenticate_publickey`**

In `crates/semicolyn-ssh-core/src/connection.rs`, add inside the `#[uniffi::export(async_runtime = "tokio")] impl Connection` block:
```rust
    /// Public-key authentication from an in-memory OpenSSH private key. (The
    /// Secure-Enclave / Keychain-backed signing path is Phase 2 + macOS.)
    pub async fn authenticate_publickey(
        &self,
        user: String,
        private_key_openssh: String,
    ) -> Result<AuthOutcome, ConnectError> {
        let key = russh::keys::PrivateKey::from_openssh(private_key_openssh.as_bytes())
            .map_err(|e| ConnectError::Transport { message: format!("invalid private key: {e}") })?;
        let mut handle = self.handle.lock().await;
        // For RSA keys, advertise the strongest server-supported SHA-2 hash;
        // ignored for ed25519/ecdsa.
        let hash = handle.best_supported_rsa_hash().await?.flatten();
        let key = russh::keys::PrivateKeyWithHashAlg::new(std::sync::Arc::new(key), hash);
        Ok(outcome(handle.authenticate_publickey(user, key).await?))
    }
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p semicolyn-ssh-core --test auth_integration`
Expected: PASS — password + publickey tests.

- [ ] **Step 8: Commit**

```bash
git add docker/sshd-entrypoint.sh docker/Dockerfile.sshd docker-compose.yml crates/semicolyn-ssh-core/src/connection.rs crates/semicolyn-ssh-core/tests/auth_integration.rs
git commit -m "feat: add publickey authentication with shared-volume test fixture"
```

---

### Task 3: Keyboard-interactive authentication

**Files:**
- Modify: `docker/Dockerfile.sshd`
- Modify: `crates/semicolyn-ssh-core/src/connection.rs`
- Modify: `crates/semicolyn-ssh-core/tests/auth_integration.rs`

**Interfaces:**
- Produces: `Connection::authenticate_keyboard_interactive(&self, user: String, responses: Vec<String>) -> Result<AuthOutcome, ConnectError>` (async, UniFFI)

> **Fixture note:** keyboard-interactive on Linux requires PAM. Alpine's base `openssh-server` build supports `UsePAM` when `linux-pam` + a PAM `sshd` policy are present. If the Alpine PAM path proves unreliable at implementation time, the documented fallback is a `debian:stable-slim` + `openssh-server` variant of `docker/Dockerfile.sshd` (Debian ships sshd with PAM enabled by default) — scoped to this task only; it does not affect Tasks 1–2.

- [ ] **Step 1: Enable PAM keyboard-interactive in the sshd image**

In `docker/Dockerfile.sshd`, extend the `apk add` and config `RUN`:
```dockerfile
RUN apk add --no-cache openssh-server openssh-server-pam linux-pam \
    && adduser -D -s /bin/sh tester \
    && echo 'tester:testpass' | chpasswd \
    && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
    && printf 'UsePAM yes\nKbdInteractiveAuthentication yes\n' >> /etc/ssh/sshd_config
```

- [ ] **Step 2: Rebuild + restart sshd, then write the failing test**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose up -d --build sshd`

Add to `crates/semicolyn-ssh-core/tests/auth_integration.rs`:
```rust
#[tokio::test]
async fn keyboard_interactive_auth_succeeds_with_password_response() {
    let Some(addr) = sshd_addr() else { eprintln!("skipping: set SEMICOLYN_TEST_SSHD"); return };
    let conn = connect_core(addr, false, false, Arc::new(TrustAll)).await.expect("connect");
    // PAM keyboard-interactive presents a single password prompt.
    let outcome = conn
        .authenticate_keyboard_interactive("tester".into(), vec!["testpass".into()])
        .await
        .expect("auth call");
    assert_eq!(outcome, AuthOutcome::Success);
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p semicolyn-ssh-core --test auth_integration keyboard_interactive`
Expected: FAIL — `no method named 'authenticate_keyboard_interactive'`.

- [ ] **Step 4: Implement `authenticate_keyboard_interactive`**

In `crates/semicolyn-ssh-core/src/connection.rs`, add inside the `#[uniffi::export(async_runtime = "tokio")] impl Connection` block:
```rust
    /// Keyboard-interactive authentication. `responses` answers each server
    /// prompt in order (typically a single password). Loops over `InfoRequest`
    /// rounds, bounded to avoid a misbehaving server spinning forever.
    pub async fn authenticate_keyboard_interactive(
        &self,
        user: String,
        responses: Vec<String>,
    ) -> Result<AuthOutcome, ConnectError> {
        use russh::client::KeyboardInteractiveAuthResponse as Kir;
        let mut handle = self.handle.lock().await;
        let mut reply = handle
            .authenticate_keyboard_interactive_start(user, None)
            .await?;
        for _ in 0..10 {
            match reply {
                Kir::Success => return Ok(AuthOutcome::Success),
                Kir::Failure { partial_success, .. } => {
                    return Ok(if partial_success {
                        AuthOutcome::PartialSuccess
                    } else {
                        AuthOutcome::Failure
                    });
                }
                Kir::InfoRequest { .. } => {
                    reply = handle
                        .authenticate_keyboard_interactive_respond(responses.clone())
                        .await?;
                }
            }
        }
        Ok(AuthOutcome::Failure)
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p semicolyn-ssh-core --test auth_integration`
Expected: PASS — all auth tests (password, publickey, keyboard-interactive).

- [ ] **Step 6: Commit**

```bash
git add docker/Dockerfile.sshd crates/semicolyn-ssh-core/src/connection.rs crates/semicolyn-ssh-core/tests/auth_integration.rs
git commit -m "feat: add keyboard-interactive authentication"
```

---

## Phase 1c exit criteria

- [ ] With `docker compose up -d --build sshd`, all auth integration tests pass:
  - password: correct → `Success`, wrong → `Failure`;
  - publickey: authorized in-memory key → `Success`;
  - keyboard-interactive: password response → `Success`.
- [ ] `cargo test -p semicolyn-ssh-core` (unit) and the 1b connect integration tests still pass (no regression).
- [ ] No private key committed to git — the publickey fixture key lives only in the `testkeys` volume.
- [ ] Three conventional commits, one per task. Every new file carries the REUSE header.
- [ ] **macOS-gated (deferred):** Swift consumption of the async `authenticate_*` methods; the SE/Keychain `Signer`.

## Self-review notes

- **Spec/roadmap coverage:** roadmap Phase 1 "auth (publickey / password / keyboard-interactive)" — all three implemented on the live handle with typed outcomes. `PartialSuccess` carries the multi-factor case the server signals via `partial_success`.
- **Split out (1c-cert):** OpenSSH certificate presentation (`authenticate_openssh_cert`), the cert+key pairing/expiry validation, and the CA fixture (sign a test key, `TrustedUserCAKeys`) — its own plan per the scope decision; `ssh-cert-auth-design.md` governs it.
- **Deferred to Phase 2 / macOS:** the `Signer` trait backed by Secure Enclave / Keychain (hardware-bound signing without exporting the key). This phase proves the protocol-level auth flow with in-memory keys; Phase 2 swaps the key source.
- **Why a shared-volume key, not a committed one:** the repo goes public; a committed private key — even a throwaway — is exactly what the privacy/security posture forbids. Generating it into an ephemeral volume keeps git clean while still giving the test a real authorized key.
- **Keyboard-interactive is the fixture-risk task:** it needs PAM. Kept last and isolated, with a Debian-image fallback documented, so any PAM friction can't block password/publickey.
