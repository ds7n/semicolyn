# Phase 1c-cert — OpenSSH Certificate Authentication (client-side, core)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add client-side OpenSSH certificate authentication to the `Connection`: present `<cert> + <private key>` to the SSH stack, after validating (1) the cert parses, (2) the cert certifies the given private key, and (3) the cert is within its validity window. Integration-tested against an `sshd` fixture configured with `TrustedUserCAKeys`.

**Architecture:** A new `Connection::authenticate_openssh_cert` (async, UniFFI) mirrors the Phase-1c `authenticate_publickey`: it parses the in-memory OpenSSH private key and certificate, runs three client-side checks, then calls russh's `Handle::authenticate_openssh_cert(user, Arc<PrivateKey>, Certificate)` and maps the `AuthResult` to the existing `AuthOutcome`. Certificate-specific failures surface as a new typed `ConnectError::CertificateInvalid { message }` — never a panic, never a silent fallback to the bare key. The `sshd` fixture gains a CA: at boot it generates a CA keypair, signs the test user key into a valid certificate (plus an expired and a not-yet-valid one for negative tests), and trusts the CA via `TrustedUserCAKeys`.

**Tech Stack:** Rust, `russh` 0.61.2, `ssh-key` 0.7.0-rc.10 (re-exported as `russh::keys::ssh_key`), `tokio`, `uniffi` 0.31, the dev container + the `sshd` fixture.

**Design doc:** `docs/superpowers/specs/2026-06-17-ssh-cert-auth-design.md` (§Auth flow, §"CA trust" 3-point client check). The identity-management UI, schema, expiry chips, and import sheet in that spec are macOS/Swift-gated (Phase 5) and out of scope here.

## Global Constraints

- **Client presents, server decides.** Glymr does not validate the CA against any client trust store. Client-side checks are exactly the spec's three: parser sanity, key↔cert pair match, validity window. The server enforces CA trust via `TrustedUserCAKeys`.
- **No silent fallback.** An expired / not-yet-valid / mismatched cert fails with `ConnectError::CertificateInvalid`; never fall back to bare-key auth.
- **Typed outcomes, not panics.** A wrong/expired cert is `CertificateInvalid` (a client validation error). A *failed but well-formed* auth attempt against the server maps to `AuthOutcome::Failure` like the other methods — not an error.
- **OpenSSH cert format only.** Parse via `ssh_key::Certificate` (`.parse()` / FromStr). No PEM/DER conversion.
- **No secret committed.** The CA private key and the signed certs live only in the `testkeys` Docker volume, like the existing publickey fixture. Nothing private lands in git.
- **License header** (`// SPDX-FileCopyrightText: 2026 True Positive LLC` / `// SPDX-License-Identifier: GPL-3.0-only`) on every new `.rs`; **conventional commits**, one per task; run everything in the dev container.
- **macOS-gated, deferred:** identity schema/UI, import sheet, expiry chips; and the host-key cert-variant allowlist additions (server host certs — a separate follow-on, not this plan).

## Verified API (recon-confirmed)

- `russh::client::Handle::authenticate_openssh_cert<U: Into<String>>(&mut self, user: U, key: Arc<PrivateKey>, cert: Certificate) -> Result<AuthResult, russh::Error>`
- `russh::keys::PrivateKey::from_openssh(impl AsRef<[u8]>) -> Result<PrivateKey, _>` (Phase-1c proven)
- `russh::keys::ssh_key::Certificate: FromStr` — parse with `s.parse::<Certificate>()`
- `Certificate::valid_after(&self) -> u64`, `Certificate::valid_before(&self) -> u64` (unix seconds)
- `Certificate::public_key(&self) -> &KeyData` (the certified key)
- `PrivateKey::public_key(&self) -> &PublicKey`, `PublicKey::key_data(&self) -> &KeyData`; `KeyData: PartialEq` → compare `key.public_key().key_data() == cert.public_key()`
- Current time: `std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)`

## File Structure

| File | Responsibility |
|---|---|
| `crates/glymr-ssh-core/src/connection.rs` | `ConnectError::CertificateInvalid`, `Connection::authenticate_openssh_cert` |
| `crates/glymr-ssh-core/tests/cert_auth_integration.rs` | Cert auth integration tests vs `sshd` (valid / expired / not-yet-valid / mismatched) |
| `docker/sshd-entrypoint.sh` | Generate CA, sign valid/expired/not-yet-valid certs, trust the CA |

---

### Task 1: CA fixture + CertificateInvalid + authenticate_openssh_cert + success test

**Files:**
- Modify: `docker/sshd-entrypoint.sh`
- Modify: `crates/glymr-ssh-core/src/connection.rs`
- Create: `crates/glymr-ssh-core/tests/cert_auth_integration.rs`

**Interfaces:**
- Consumes: `connect_core`, `Connection`, `ConnectError`, `AuthOutcome`, `outcome()`, `HostKeyVerifier`/`HostKeyInfo` (Phases 1b/1c).
- Produces:
  - `ConnectError::CertificateInvalid { message: String }` (new `uniffi::Error` variant)
  - `Connection::authenticate_openssh_cert(&self, user: String, private_key_openssh: String, cert_openssh: String) -> Result<AuthOutcome, ConnectError>` (async, UniFFI)

- [ ] **Step 1: Extend the sshd entrypoint with a CA and signed certs**

In `docker/sshd-entrypoint.sh`, after the existing `authorized_keys` block (after `chmod 600 /home/tester/.ssh/authorized_keys`) and before `exec "$@"`, add:
```sh
# --- Client-certificate auth fixture (Phase 1c-cert) ---
# A disposable CA that signs the test user key. Never a real credential.
if [ ! -f /testkeys/ca ]; then
  ssh-keygen -t ed25519 -N '' -C 'glymr-test-ca' -f /testkeys/ca
fi
chmod 644 /testkeys/ca /testkeys/ca.pub
# Sign id_ed25519 into three certs for principal 'tester': valid-now, expired,
# and not-yet-valid. ssh-keygen names the output "<input-basename>-cert.pub",
# so sign copies to get distinct filenames. Re-signed every boot (validity
# windows stay fresh; the fixed-date ones stay expired/future).
cp /testkeys/id_ed25519.pub /testkeys/valid.pub
cp /testkeys/id_ed25519.pub /testkeys/expired.pub
cp /testkeys/id_ed25519.pub /testkeys/notyet.pub
ssh-keygen -s /testkeys/ca -I glymr-valid   -n tester -V -5m:+52w   /testkeys/valid.pub
ssh-keygen -s /testkeys/ca -I glymr-expired -n tester -V 20000101000000:20000102000000 /testkeys/expired.pub
ssh-keygen -s /testkeys/ca -I glymr-notyet  -n tester -V +52w:+104w /testkeys/notyet.pub
chmod 644 /testkeys/valid-cert.pub /testkeys/expired-cert.pub /testkeys/notyet-cert.pub
# Trust the CA for user authentication (idempotent across reboots).
grep -q '^TrustedUserCAKeys' /etc/ssh/sshd_config \
  || echo 'TrustedUserCAKeys /testkeys/ca.pub' >> /etc/ssh/sshd_config
```

- [ ] **Step 2: Rebuild + restart sshd, then write the failing success test**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose up -d --build sshd`
Sanity-check the fixture produced the certs:
`HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose exec sshd sh -c 'ls /testkeys/*-cert.pub && ssh-keygen -L -f /testkeys/valid-cert.pub | head'`
Expected: three `*-cert.pub` files; `valid-cert.pub` lists principal `tester` and a valid-now window.

Create `crates/glymr-ssh-core/tests/cert_auth_integration.rs`:
```rust
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
use std::sync::Arc;
use glymr_ssh_core::connection::{
    connect_core, AuthOutcome, ConnectError, HostKeyInfo, HostKeyVerifier,
};

struct TrustAll;
#[async_trait::async_trait]
impl HostKeyVerifier for TrustAll {
    async fn verify(&self, _info: HostKeyInfo) -> bool { true }
}

fn sshd_addr() -> Option<String> { std::env::var("GLYMR_TEST_SSHD").ok() }

fn read_testkey(name: &str) -> Option<String> {
    match std::fs::read_to_string(format!("/testkeys/{name}")) {
        Ok(s) => Some(s),
        Err(_) => { eprintln!("skipping: /testkeys/{name} not mounted"); None }
    }
}

#[tokio::test]
async fn cert_auth_succeeds_with_valid_cert() {
    let Some(addr) = sshd_addr() else { eprintln!("skipping: set GLYMR_TEST_SSHD"); return };
    let (Some(key), Some(cert)) = (read_testkey("id_ed25519"), read_testkey("valid-cert.pub")) else { return };
    let conn = connect_core(addr, false, false, Arc::new(TrustAll)).await.expect("connect");
    let outcome = conn
        .authenticate_openssh_cert("tester".into(), key, cert)
        .await
        .expect("auth call");
    assert_eq!(outcome, AuthOutcome::Success);
}

// Silence the unused import until Task 2 uses it.
#[allow(dead_code)]
fn _uses_connect_error() -> Option<ConnectError> { None }
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p glymr-ssh-core --test cert_auth_integration`
Expected: FAIL — `no method named authenticate_openssh_cert` (and `CertificateInvalid` not yet a variant).

- [ ] **Step 4: Add the `CertificateInvalid` error variant**

In `crates/glymr-ssh-core/src/connection.rs`, add to the `ConnectError` enum (after the `Transport` variant):
```rust
    /// The supplied certificate is unusable on the client side: malformed,
    /// not matching the private key, or outside its validity window. Never a
    /// silent fallback to bare-key auth.
    #[error("certificate invalid: {message}")]
    CertificateInvalid { message: String },
```

- [ ] **Step 5: Implement `authenticate_openssh_cert`**

In `crates/glymr-ssh-core/src/connection.rs`, add inside the existing `#[uniffi::export(async_runtime = "tokio")] impl Connection` block (alongside the `authenticate_*` methods):
```rust
    /// OpenSSH certificate authentication: present `<cert> + <private key>`.
    /// Performs the three client-side checks from the cert-auth design (parse,
    /// key↔cert pair match, validity window) then lets the server decide CA
    /// trust. An unusable cert is `CertificateInvalid` — never a fallback to
    /// the bare key.
    pub async fn authenticate_openssh_cert(
        &self,
        user: String,
        private_key_openssh: String,
        cert_openssh: String,
    ) -> Result<AuthOutcome, ConnectError> {
        let key = russh::keys::PrivateKey::from_openssh(private_key_openssh.as_bytes())
            .map_err(|e| ConnectError::Transport { message: format!("invalid private key: {e}") })?;
        let cert = cert_openssh
            .parse::<russh::keys::ssh_key::Certificate>()
            .map_err(|e| ConnectError::CertificateInvalid { message: format!("malformed certificate: {e}") })?;
        // Pair sanity: the cert must certify this private key.
        if key.public_key().key_data() != cert.public_key() {
            return Err(ConnectError::CertificateInvalid {
                message: "certificate does not match the private key".into(),
            });
        }
        // Validity window: validAfter <= now <= validBefore (unix seconds).
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        if now < cert.valid_after() {
            return Err(ConnectError::CertificateInvalid {
                message: "certificate is not yet valid".into(),
            });
        }
        if now > cert.valid_before() {
            return Err(ConnectError::CertificateInvalid {
                message: "certificate has expired".into(),
            });
        }
        let mut handle = self.handle.lock().await;
        Ok(outcome(
            handle
                .authenticate_openssh_cert(user, std::sync::Arc::new(key), cert)
                .await?,
        ))
    }
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p glymr-ssh-core --test cert_auth_integration`
Expected: PASS — `cert_auth_succeeds_with_valid_cert`.

- [ ] **Step 7: Commit**

```bash
git add docker/sshd-entrypoint.sh crates/glymr-ssh-core/src/connection.rs crates/glymr-ssh-core/tests/cert_auth_integration.rs
git commit -m "feat: add OpenSSH certificate authentication with CA test fixture"
```

---

### Task 2: Adversarial validation coverage (expired / not-yet-valid / mismatched key)

**Files:**
- Modify: `crates/glymr-ssh-core/tests/cert_auth_integration.rs`

**Interfaces:**
- Consumes: `authenticate_openssh_cert`, `ConnectError::CertificateInvalid` (Task 1). No production change — this task hardens the three client-side checks. **Risk tier: Critical** (auth/trust): each negative asserts the SPECIFIC `CertificateInvalid` message, not just that it errored.

- [ ] **Step 1: Write the failing/again-passing adversarial tests**

Replace the `#[allow(dead_code)] fn _uses_connect_error` placeholder in `crates/glymr-ssh-core/tests/cert_auth_integration.rs` with:
```rust
#[tokio::test]
async fn cert_auth_rejects_expired_cert() {
    let Some(addr) = sshd_addr() else { eprintln!("skipping: set GLYMR_TEST_SSHD"); return };
    let (Some(key), Some(cert)) = (read_testkey("id_ed25519"), read_testkey("expired-cert.pub")) else { return };
    let conn = connect_core(addr, false, false, Arc::new(TrustAll)).await.expect("connect");
    let err = conn
        .authenticate_openssh_cert("tester".into(), key, cert)
        .await
        .expect_err("expired cert must be refused");
    match err {
        ConnectError::CertificateInvalid { message } => assert_eq!(message, "certificate has expired"),
        other => panic!("expected CertificateInvalid(expired), got {other:?}"),
    }
}

#[tokio::test]
async fn cert_auth_rejects_not_yet_valid_cert() {
    let Some(addr) = sshd_addr() else { eprintln!("skipping: set GLYMR_TEST_SSHD"); return };
    let (Some(key), Some(cert)) = (read_testkey("id_ed25519"), read_testkey("notyet-cert.pub")) else { return };
    let conn = connect_core(addr, false, false, Arc::new(TrustAll)).await.expect("connect");
    let err = conn
        .authenticate_openssh_cert("tester".into(), key, cert)
        .await
        .expect_err("not-yet-valid cert must be refused");
    match err {
        ConnectError::CertificateInvalid { message } => assert_eq!(message, "certificate is not yet valid"),
        other => panic!("expected CertificateInvalid(not yet valid), got {other:?}"),
    }
}

#[tokio::test]
async fn cert_auth_rejects_cert_for_a_different_key() {
    let Some(addr) = sshd_addr() else { eprintln!("skipping: set GLYMR_TEST_SSHD"); return };
    // The CA private key is a valid ed25519 key unrelated to id_ed25519, so the
    // valid cert (which certifies id_ed25519) does not match it → pair failure.
    let (Some(wrong_key), Some(cert)) = (read_testkey("ca"), read_testkey("valid-cert.pub")) else { return };
    let conn = connect_core(addr, false, false, Arc::new(TrustAll)).await.expect("connect");
    let err = conn
        .authenticate_openssh_cert("tester".into(), wrong_key, cert)
        .await
        .expect_err("cert not matching the key must be refused");
    match err {
        ConnectError::CertificateInvalid { message } => {
            assert_eq!(message, "certificate does not match the private key")
        }
        other => panic!("expected CertificateInvalid(mismatch), got {other:?}"),
    }
}
```
Also delete the now-unused `_uses_connect_error` helper (replaced above).

- [ ] **Step 2: Run the new tests**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p glymr-ssh-core --test cert_auth_integration`
Expected: all four cert tests PASS. If `cert_auth_rejects_expired_cert` reports `Ok`/`Success` instead of the error, the expiry check is wrong or the fixture's expired cert is not actually expired (check `ssh-keygen -L -f /testkeys/expired-cert.pub`). If the mismatch test panics with a different message, the pair check is missing/after the call.

- [ ] **Step 3: Run the entire crate suite (no regression)**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p glymr-ssh-core`
Expected: PASS — unit (8), connect (4), auth (5), shell (5), cert (4).

- [ ] **Step 4: Commit**

```bash
git add crates/glymr-ssh-core/tests/cert_auth_integration.rs
git commit -m "test: add cert auth adversarial cases (expired, not-yet-valid, key mismatch)"
```

---

## Phase 1c-cert exit criteria

- [ ] `cargo test -p glymr-ssh-core` green against the rebuilt `sshd` fixture; earlier suites unaffected.
- [ ] Valid cert + matching key + CA-trusting server → `AuthOutcome::Success`.
- [ ] Expired / not-yet-valid / mismatched-key cert → `ConnectError::CertificateInvalid` with the specific message; never a bare-key fallback, never a panic.
- [ ] No CA private key or signed cert committed to git — all live only in the `testkeys` volume.
- [ ] Two conventional commits, one per task; the new test file carries the REUSE header.
- [ ] **macOS-gated / deferred:** identity schema + UI (import sheet, detail section, expiry chips); the host-key cert-variant allowlist additions (server host certs).

## Self-review notes

- **Spec coverage:** implements §"Auth flow" (present cert+key when valid; hard-refuse when expired, no silent fallback) and the §"CA trust" three client checks (parser sanity, pair match, validity window). The UI/schema/chips are explicitly Swift-gated and excluded.
- **Why a fixture CA, not a committed cert:** same privacy posture as the publickey key — a signed cert + CA key are generated into the ephemeral `testkeys` volume; git stays clean.
- **BVA on the validity window:** both boundaries are covered — `now > valid_before` (expired) and `now < valid_after` (not-yet-valid) — plus the valid-now interior and the pair-match adversarial case.
- **Reusing the CA key as the "wrong key":** the fixture already emits `/testkeys/ca` (a valid, unrelated ed25519 private key), so the mismatch test needs no extra fixture file.
- **Split out / deferred:** the algorithms-spec Tier-1/Tier-3 cert-variant *host-key* additions are server host-cert verification (host-key-trust territory), independent of client cert auth — a separate small follow-on, not bundled here.
