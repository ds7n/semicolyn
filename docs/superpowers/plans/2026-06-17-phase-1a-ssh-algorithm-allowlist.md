# Phase 1a — SSH Algorithm Allowlist Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the four-tier SSH algorithm allowlist as a pure Rust function that turns the two per-host toggles into a `russh::Preferred` negotiation list, plus a Tier-3 classifier the later handshake phase uses to raise the outdated-cryptography warning. Fully unit-tested on the Linux fast loop — no network.

**Architecture:** A new private module `algorithms` inside the `neotilde-ssh-core` crate. It depends only on `russh`'s type surface (`Preferred` + the `kex`/`cipher`/`mac`/`compression` name constants + `ssh_key::Algorithm`), not on any async runtime — so it compiles and tests in the Docker dev container with zero network. The function is `pub(crate)`: Phase 1b's connection code consumes it; nothing is exported over UniFFI in this sub-plan.

**Tech Stack:** Rust (stable), `russh` 0.61.2 (pin `russh = "0.61"`), the Neotilde dev container (`docker compose run --rm dev cargo test`).

## Global Constraints

- **Closed set.** The negotiation list contains *only* algorithms on a permitted tier for the current host. Algorithms not on any tier are never offered. Verbatim from `docs/superpowers/specs/2026-06-17-ssh-algorithms-design.md`.
- **Opportunistic omit (decided 2026-06-17).** Three algorithms the spec lists are absent from russh 0.61.2 and are **omitted from v1**, documented in module docs + a spec caveat note, and auto-enter their tier when russh gains them:
  - `sntrup761x25519-sha512@openssh.com` (Tier-1 KEX) — russh #626. **ML-KEM (`mlkem768x25519-sha256`) remains the PQC KEX**, so v1 keeps post-quantum key exchange.
  - `umac-128-etm@openssh.com` (Tier-1 MAC).
  - `hmac-sha1-96` (Tier-3 MAC).
- **russh pin:** `russh = "0.61"` (resolves to 0.61.2). Default features in this sub-plan; the crypto-backend pin (`aws-lc-rs`) and the `cargo deny` license gate land in Phase 1b when the handshake actually exercises the backend.
- **License header:** every created `.rs` file begins verbatim with:
  ```
  // SPDX-FileCopyrightText: 2026 True Positive LLC
  // SPDX-License-Identifier: GPL-3.0-only
  ```
- **Conventional commits**; squash-merge. One commit per task.
- **Run everything in the dev container:** `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev <cmd>`.

---

## Verified russh 0.61.2 API (recon-confirmed, do not re-derive)

These are confirmed by compiling against the pinned crate in the dev container:

- `russh::Preferred { kex: Cow<[kex::Name]>, key: Cow<[ssh_key::Algorithm]>, cipher: Cow<[cipher::Name]>, mac: Cow<[mac::Name]>, compression: Cow<[compression::Name]> }`
- Name constants (each a `Name(&'static str)`; `.as_ref()` yields the wire string):
  - `russh::kex::{MLKEM768X25519_SHA256, CURVE25519, CURVE25519_PRE_RFC_8731, ECDH_SHA2_NISTP256, ECDH_SHA2_NISTP384, ECDH_SHA2_NISTP521, DH_G16_SHA512, DH_G18_SHA512, DH_G14_SHA256, DH_GEX_SHA256, DH_G14_SHA1, DH_GEX_SHA1}`
  - `russh::cipher::{CHACHA20_POLY1305, AES_256_GCM, AES_128_GCM, AES_256_CTR, AES_192_CTR, AES_128_CTR, AES_256_CBC, AES_192_CBC, AES_128_CBC}`
  - `russh::mac::{HMAC_SHA256_ETM, HMAC_SHA512_ETM, HMAC_SHA256, HMAC_SHA512, HMAC_SHA1}`
  - `russh::compression::NONE`
- Host keys: `russh::keys::ssh_key::Algorithm` — `Ed25519`, `Rsa { hash: Some(HashAlg::Sha512) }` (= `rsa-sha2-512`), `Rsa { hash: Some(HashAlg::Sha256) }` (= `rsa-sha2-256`), `Rsa { hash: None }` (= `ssh-rsa`, SHA-1, Tier 3), `Ecdsa { curve: EcdsaCurve::NistP256 | NistP384 | NistP521 }`. `Algorithm` derives `PartialEq`; `.as_str()` yields the wire string. `EcdsaCurve` and `HashAlg` from `russh::keys::ssh_key`.
- **Tier-4 algorithms (arcfour, blowfish, cast128, 3des, hmac-md5, ssh-dss, dh-group1) do not exist as russh constants** — excluding them is automatic. Tests assert their absence as documentation of the floor.

## Tier → algorithm mapping (from the spec, minus the omitted three)

| Category | Tier 1 (always) | Tier 2 (`allow_legacy`) | Tier 3 (`allow_deprecated`) |
|---|---|---|---|
| KEX | `MLKEM768X25519_SHA256`, `CURVE25519`, `CURVE25519_PRE_RFC_8731`, `ECDH_SHA2_NISTP256/384/521`, `DH_G16_SHA512`, `DH_G18_SHA512` | `DH_G14_SHA256`, `DH_GEX_SHA256` | `DH_G14_SHA1`, `DH_GEX_SHA1` |
| Cipher | `CHACHA20_POLY1305`, `AES_256_GCM`, `AES_128_GCM`, `AES_256_CTR`, `AES_192_CTR`, `AES_128_CTR` | `AES_256_CBC`, `AES_192_CBC`, `AES_128_CBC` | — |
| MAC | `HMAC_SHA256_ETM`, `HMAC_SHA512_ETM`, `HMAC_SHA256`, `HMAC_SHA512` | — | `HMAC_SHA1` |
| Host key | `Ed25519`, `Rsa{Sha512}`, `Rsa{Sha256}`, `Ecdsa{NistP256/384/521}` | — | `Rsa{None}` (ssh-rsa) |

`compression` is `[NONE]` in every case (v1 offers no compression).

---

## File Structure

| File | Responsibility |
|---|---|
| `crates/neotilde-ssh-core/Cargo.toml` | Add `russh = "0.61"` dependency |
| `crates/neotilde-ssh-core/src/algorithms.rs` | `build_preferred()`, `TIER3_WIRE_NAMES`, `is_tier3()`, unit tests |
| `crates/neotilde-ssh-core/src/lib.rs` | Add `mod algorithms;` |
| `docs/superpowers/specs/2026-06-17-ssh-algorithms-design.md` | Append the stack-availability caveat (Task 3) |

---

### Task 1: russh dependency + Tier-1 baseline

**Files:**
- Modify: `crates/neotilde-ssh-core/Cargo.toml`
- Create: `crates/neotilde-ssh-core/src/algorithms.rs`
- Modify: `crates/neotilde-ssh-core/src/lib.rs`

**Interfaces:**
- Produces: `pub(crate) fn build_preferred(allow_legacy: bool, allow_deprecated: bool) -> russh::Preferred`

- [ ] **Step 1: Add the russh dependency**

In `crates/neotilde-ssh-core/Cargo.toml`, under `[dependencies]` (below the existing `uniffi` line):
```toml
russh = "0.61"
```

- [ ] **Step 2: Register the module**

In `crates/neotilde-ssh-core/src/lib.rs`, add after the `uniffi::setup_scaffolding!();` line:
```rust
mod algorithms;
```

- [ ] **Step 3: Write the Tier-1 module skeleton with failing tests**

Create `crates/neotilde-ssh-core/src/algorithms.rs` with the header, the test helpers, and the three Tier-1 tests — **but no `build_preferred` yet** (so the tests fail to compile, the Rust equivalent of red):
```rust
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

//! SSH algorithm allowlist — the closed set of algorithms Neotilde offers during
//! negotiation, per docs/superpowers/specs/2026-06-17-ssh-algorithms-design.md.
//!
//! Three spec'd algorithms are absent from russh 0.61.2 and omitted from v1
//! (they auto-enter when russh gains them):
//!   - sntrup761x25519-sha512@openssh.com (Tier 1 KEX) — ML-KEM remains the PQC KEX.
//!   - umac-128-etm@openssh.com (Tier 1 MAC).
//!   - hmac-sha1-96 (Tier 3 MAC).

#[cfg(test)]
mod tests {
    use super::*;

    fn kex_wire(p: &russh::Preferred) -> Vec<&str> {
        p.kex.iter().map(|n| n.as_ref()).collect::<Vec<&str>>()
    }
    fn cipher_wire(p: &russh::Preferred) -> Vec<&str> {
        p.cipher.iter().map(|n| n.as_ref()).collect::<Vec<&str>>()
    }
    fn mac_wire(p: &russh::Preferred) -> Vec<&str> {
        p.mac.iter().map(|n| n.as_ref()).collect::<Vec<&str>>()
    }
    fn key_wire(p: &russh::Preferred) -> Vec<&str> {
        p.key.iter().map(|a| a.as_str()).collect::<Vec<&str>>()
    }

    #[test]
    fn tier1_defaults_offer_modern_set() {
        let p = build_preferred(false, false);
        let kex = kex_wire(&p);
        assert!(kex.contains(&"mlkem768x25519-sha256"), "PQC KEX must be present");
        assert!(kex.contains(&"curve25519-sha256"));
        assert!(cipher_wire(&p).contains(&"chacha20-poly1305@openssh.com"));
        assert!(cipher_wire(&p).contains(&"aes256-gcm@openssh.com"));
        assert!(mac_wire(&p).contains(&"hmac-sha2-256-etm@openssh.com"));
        assert!(key_wire(&p).contains(&"ssh-ed25519"));
        assert!(key_wire(&p).contains(&"rsa-sha2-512"));
    }

    #[test]
    fn tier1_excludes_legacy_and_deprecated() {
        let p = build_preferred(false, false);
        assert!(!kex_wire(&p).contains(&"diffie-hellman-group14-sha256")); // Tier 2
        assert!(!kex_wire(&p).contains(&"diffie-hellman-group14-sha1"));   // Tier 3
        assert!(!cipher_wire(&p).contains(&"aes256-cbc"));                 // Tier 2
        assert!(!mac_wire(&p).contains(&"hmac-sha1"));                     // Tier 3
        assert!(!key_wire(&p).contains(&"ssh-rsa"));                       // Tier 3
    }

    #[test]
    fn tier4_never_offered_even_with_both_toggles() {
        let p = build_preferred(true, true);
        assert!(!cipher_wire(&p).contains(&"3des-cbc"));
        assert!(!key_wire(&p).contains(&"ssh-dss"));
        assert!(!mac_wire(&p).contains(&"hmac-md5"));
    }
}
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p neotilde-ssh-core`
Expected: FAIL — `cannot find function 'build_preferred' in this scope`.

- [ ] **Step 5: Implement `build_preferred` (Tier 1 only)**

Add to `crates/neotilde-ssh-core/src/algorithms.rs`, above the `#[cfg(test)]` module:
```rust
use std::borrow::Cow;
use russh::keys::ssh_key::{Algorithm, EcdsaCurve, HashAlg};
use russh::{cipher, compression, kex, mac, Preferred};

/// Builds the russh negotiation preference list from the two per-host toggles.
/// Closed set: only algorithms on a permitted tier are offered. Tier order is
/// preference order — strongest first.
pub(crate) fn build_preferred(allow_legacy: bool, allow_deprecated: bool) -> Preferred {
    // Tier 1 — always offered. PQ-hybrid KEX leads.
    let mut kex_algs = vec![
        kex::MLKEM768X25519_SHA256,
        kex::CURVE25519,
        kex::CURVE25519_PRE_RFC_8731,
        kex::ECDH_SHA2_NISTP256,
        kex::ECDH_SHA2_NISTP384,
        kex::ECDH_SHA2_NISTP521,
        kex::DH_G16_SHA512,
        kex::DH_G18_SHA512,
    ];
    let mut cipher_algs = vec![
        cipher::CHACHA20_POLY1305,
        cipher::AES_256_GCM,
        cipher::AES_128_GCM,
        cipher::AES_256_CTR,
        cipher::AES_192_CTR,
        cipher::AES_128_CTR,
    ];
    // umac-128-etm@openssh.com is spec'd Tier 1 but absent from russh 0.61 (omitted).
    let mut mac_algs = vec![
        mac::HMAC_SHA256_ETM,
        mac::HMAC_SHA512_ETM,
        mac::HMAC_SHA256,
        mac::HMAC_SHA512,
    ];
    let mut host_keys = vec![
        Algorithm::Ed25519,
        Algorithm::Rsa { hash: Some(HashAlg::Sha512) },
        Algorithm::Rsa { hash: Some(HashAlg::Sha256) },
        Algorithm::Ecdsa { curve: EcdsaCurve::NistP256 },
        Algorithm::Ecdsa { curve: EcdsaCurve::NistP384 },
        Algorithm::Ecdsa { curve: EcdsaCurve::NistP521 },
    ];

    // Tier 2 / Tier 3 appends are added in Tasks 2 and 3.
    let _ = (allow_legacy, allow_deprecated);

    Preferred {
        kex: Cow::Owned(kex_algs),
        key: Cow::Owned(host_keys),
        cipher: Cow::Owned(cipher_algs),
        mac: Cow::Owned(mac_algs),
        compression: Cow::Borrowed(&[compression::NONE]),
    }
}
```
(The `let mut` on the four vecs is intentional — Tasks 2 and 3 push onto them. The `let _ =` placeholder is replaced by real branches next task.)

- [ ] **Step 6: Run the tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p neotilde-ssh-core`
Expected: PASS — `tier1_defaults_offer_modern_set`, `tier1_excludes_legacy_and_deprecated`, `tier4_never_offered_even_with_both_toggles`, plus the existing `core_version` test.

- [ ] **Step 7: Commit**

```bash
git add crates/neotilde-ssh-core/Cargo.toml Cargo.lock crates/neotilde-ssh-core/src/lib.rs crates/neotilde-ssh-core/src/algorithms.rs
git commit -m "feat: add Tier-1 SSH algorithm allowlist via russh Preferred"
```

---

### Task 2: Tier 2 — legacy algorithms

**Files:**
- Modify: `crates/neotilde-ssh-core/src/algorithms.rs`

**Interfaces:**
- Consumes: `build_preferred` from Task 1.
- Produces: the `allow_legacy` branch behaviour (no signature change).

- [ ] **Step 1: Write the failing test**

Add inside the `tests` module in `algorithms.rs`:
```rust
    #[test]
    fn legacy_toggle_adds_tier2_only() {
        let p = build_preferred(true, false);
        assert!(kex_wire(&p).contains(&"diffie-hellman-group14-sha256"));
        assert!(kex_wire(&p).contains(&"diffie-hellman-group-exchange-sha256"));
        assert!(cipher_wire(&p).contains(&"aes256-cbc"));
        assert!(cipher_wire(&p).contains(&"aes128-cbc"));
        // legacy must NOT pull in Tier 3
        assert!(!kex_wire(&p).contains(&"diffie-hellman-group14-sha1"));
        assert!(!key_wire(&p).contains(&"ssh-rsa"));
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p neotilde-ssh-core legacy_toggle_adds_tier2_only`
Expected: FAIL — assertion fails on `diffie-hellman-group14-sha256` (not yet appended).

- [ ] **Step 3: Implement the Tier-2 branch**

In `algorithms.rs`, replace the placeholder line:
```rust
    // Tier 2 / Tier 3 appends are added in Tasks 2 and 3.
    let _ = (allow_legacy, allow_deprecated);
```
with:
```rust
    // Tier 2 — legacy but allowed (per-host `neotilde.allowLegacyAlgorithms`).
    if allow_legacy {
        kex_algs.push(kex::DH_G14_SHA256);
        kex_algs.push(kex::DH_GEX_SHA256);
        cipher_algs.push(cipher::AES_256_CBC);
        cipher_algs.push(cipher::AES_192_CBC);
        cipher_algs.push(cipher::AES_128_CBC);
    }

    // Tier 3 append is added in Task 3.
    let _ = allow_deprecated;
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p neotilde-ssh-core`
Expected: PASS — all Task 1 + Task 2 tests green.

- [ ] **Step 5: Commit**

```bash
git add crates/neotilde-ssh-core/src/algorithms.rs
git commit -m "feat: add Tier-2 legacy algorithm gating to allowlist"
```

---

### Task 3: Tier 3 — deprecated algorithms + classifier + spec note

**Files:**
- Modify: `crates/neotilde-ssh-core/src/algorithms.rs`
- Modify: `docs/superpowers/specs/2026-06-17-ssh-algorithms-design.md`

**Interfaces:**
- Consumes: `build_preferred` from Tasks 1–2.
- Produces: `pub(crate) const TIER3_WIRE_NAMES: &[&str]` and `pub(crate) fn is_tier3(name: &str) -> bool` — Phase 1b matches negotiated algorithm names against these to raise the outdated-cryptography warning.

- [ ] **Step 1: Write the failing tests**

Add inside the `tests` module in `algorithms.rs`:
```rust
    #[test]
    fn deprecated_toggle_adds_tier3_only() {
        let p = build_preferred(false, true);
        assert!(kex_wire(&p).contains(&"diffie-hellman-group14-sha1"));
        assert!(kex_wire(&p).contains(&"diffie-hellman-group-exchange-sha1"));
        assert!(mac_wire(&p).contains(&"hmac-sha1"));
        assert!(key_wire(&p).contains(&"ssh-rsa"));
        // deprecated must NOT pull in Tier 2
        assert!(!cipher_wire(&p).contains(&"aes256-cbc"));
    }

    #[test]
    fn tier3_classifier_flags_negotiated_names() {
        assert!(is_tier3("ssh-rsa"));
        assert!(is_tier3("hmac-sha1"));
        assert!(is_tier3("diffie-hellman-group14-sha1"));
        assert!(is_tier3("diffie-hellman-group-exchange-sha1"));
        assert!(!is_tier3("curve25519-sha256"));
        assert!(!is_tier3("aes256-gcm@openssh.com"));
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p neotilde-ssh-core`
Expected: FAIL — `cannot find function 'is_tier3'` and the deprecated-toggle assertion fails.

- [ ] **Step 3: Implement the Tier-3 branch**

In `algorithms.rs`, replace:
```rust
    // Tier 3 append is added in Task 3.
    let _ = allow_deprecated;
```
with:
```rust
    // Tier 3 — legacy & risky (per-host `neotilde.allowDeprecatedAlgorithms`).
    // Every connection that negotiates one of these shows a warning (Phase 1b
    // uses `is_tier3` to detect it). hmac-sha1-96 is spec'd here but absent from
    // russh 0.61 (omitted).
    if allow_deprecated {
        kex_algs.push(kex::DH_G14_SHA1);
        kex_algs.push(kex::DH_GEX_SHA1);
        mac_algs.push(mac::HMAC_SHA1);
        host_keys.push(Algorithm::Rsa { hash: None }); // ssh-rsa (SHA-1)
    }
```

- [ ] **Step 4: Implement the Tier-3 classifier**

In `algorithms.rs`, add below the `build_preferred` function (above `#[cfg(test)]`):
```rust
/// Wire names of the Tier-3 algorithms Neotilde can offer. After a handshake,
/// Phase 1b matches each negotiated algorithm name against this set to decide
/// whether to raise the outdated-cryptography warning (ssh-algorithms-design
/// §"Tier 3 warning UX"). hmac-sha1-96 is spec'd Tier 3 but absent from russh
/// 0.61, so it is not listed here.
pub(crate) const TIER3_WIRE_NAMES: &[&str] = &[
    "diffie-hellman-group14-sha1",
    "diffie-hellman-group-exchange-sha1",
    "ssh-rsa",
    "hmac-sha1",
];

/// True if `name` (a negotiated algorithm's wire name) is a Tier-3 algorithm.
pub(crate) fn is_tier3(name: &str) -> bool {
    TIER3_WIRE_NAMES.contains(&name)
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose run --rm dev cargo test -p neotilde-ssh-core`
Expected: PASS — all allowlist tests + `core_version` green.

- [ ] **Step 6: Append the stack-availability caveat to the spec**

In `docs/superpowers/specs/2026-06-17-ssh-algorithms-design.md`, add a new section immediately before `## Out of scope (v1)`:
```markdown
## Stack availability (russh 0.61.2) — added 2026-06-17

The v1 SSH stack is **russh 0.61.2**. Three algorithms listed above are not yet
implemented by russh and are **omitted from v1's offered set** (opportunistic
omit, decided 2026-06-17). Each auto-enters its tier when russh gains support;
no spec change is needed at that point — only adding the constant to
`crates/neotilde-ssh-core/src/algorithms.rs`.

| Omitted algorithm | Tier | russh tracking |
|---|---|---|
| `sntrup761x25519-sha512@openssh.com` | 1 (KEX) | russh #626 |
| `umac-128-etm@openssh.com` | 1 (MAC) | not yet implemented |
| `hmac-sha1-96` | 3 (MAC) | not yet implemented |

Post-quantum key exchange is **unaffected**: russh implements
`mlkem768x25519-sha256`, which remains Tier 1 and the PQC KEX for v1. The Tier-4
"never offered" algorithms (arcfour, blowfish, cast128, 3des, hmac-md5, ssh-dss,
dh-group1) are not implemented by russh either, so excluding them is automatic.
```

- [ ] **Step 7: Commit**

```bash
git add crates/neotilde-ssh-core/src/algorithms.rs docs/superpowers/specs/2026-06-17-ssh-algorithms-design.md
git commit -m "feat: add Tier-3 deprecated gating + classifier; document russh stack gaps"
```

---

## Phase 1a exit criteria

- [ ] `cargo test -p neotilde-ssh-core` green in the dev container (all allowlist tests + `core_version`).
- [ ] `build_preferred(false, false)` offers only Tier 1; `(true, false)` adds Tier 2; `(false, true)` adds Tier 3; `(true, true)` adds both — and Tier 4 is never present.
- [ ] `is_tier3` correctly classifies the four available Tier-3 wire names and rejects Tier-1 names.
- [ ] The three omitted algorithms are documented in `algorithms.rs` module docs **and** the spec caveat section.
- [ ] Three conventional commits, one per task. Every new file carries the REUSE header.

## Self-review notes

- **Spec coverage:** the four-tier model (§"Model — four tiers"), Tier 1/2/3/4 membership (all four category tables), the two toggles (`allowLegacyAlgorithms` / `allowDeprecatedAlgorithms`), the closed-set rule, and the Tier-3 warning hook (`is_tier3`, consumed by Phase 1b's banner) are all implemented or wired. The UI surfaces (toggles in host CRUD, the Tier-3 modal + amber banner) are **out of scope for the core** and land in the UI phases (5/7) — Phase 1a produces the mechanism, not the chrome.
- **Deliberately deferred to Phase 1b:** the crypto-backend pin (`aws-lc-rs`) + `cargo deny` license gate (only matter once the backend is exercised by a real handshake) and the detection of *which* negotiated algorithm triggered the warning (needs a live session's negotiated names — `is_tier3` is the ready hook).
- **Why opportunistic omit is safe:** the only PQC algorithm motivating the russh pick was ML-KEM, which russh has. sntrup761's absence costs a second PQC option, not PQC itself. umac/hmac-sha1-96 are convenience/legacy MACs with modern alternatives already present.

---

## Phase 1 remaining sub-plans (write each when it's next, via superpowers:writing-plans)

Phase 1a is the first of six dependency-ordered sub-plans decomposed from roadmap Phase 1:

- **1a — Algorithm allowlist** *(this plan)* — pure logic, Linux-tested.
- **1b — Connection + handshake + host-key verification delegate.** russh `client::connect`, the `client::Handler::check_server_key` TOFU delegate surfaced over UniFFI, `Preferred` wired from 1a, the `aws-lc-rs` backend pin + `cargo deny` gate, Tier-3 warning detection. Integration-tested against a containerized `sshd`. Specs: `host-key-trust`, `ssh-algorithms` (runtime half).
- **1c — Authentication + cert presentation.** publickey / password / keyboard-interactive; OpenSSH cert (`<cert>+<key>`) with expiry hard-fail. Specs: `ssh-cert-auth`.
- **1d — PTY shell channel.** open session channel, request PTY, stdin write / stdout+stderr stream / window resize.
- **1e — Port forwards.** `direct-tcpip`, `forwarded-tcpip`, dynamic (SOCKS).
- **1f — ProxyJump + chain auth enumeration.** nested channels for multi-hop; `anyUse` counting for the chain summary modal. Specs: `chain-auth`.

**Exit for the whole of Phase 1 (per roadmap):** integration tests against a containerized `sshd` in CI; cert auth + a 2-hop ProxyJump pass. (1b–1f need an `sshd` service in `docker-compose.yml` — added in 1b.)
