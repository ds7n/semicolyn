# Phase 2b-i — Apple Key-Minting (iCloud-Keychain flavor) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **First execution step:** create the feature branch and commit this plan doc (Task 0).

**Goal:** Let a user **generate** or **import** an SSH identity (iCloud-Keychain flavor, ed25519 default) and **authenticate to a host with it** — closing the "identity create/import + publickey connect" gap Plan 2 deferred to Phase 2b.

**Architecture:** All SSH-key crypto (generate, parse, OpenSSH-encode, fingerprint) lives in the **Rust core** via the `ssh-key` crate already in-tree (`russh::keys::ssh_key`), exposed over UniFFI and `cargo test`-verified on Linux. A pure-Swift **`IdentityService`** in `SemicolynKit` orchestrates mint → persist private key to the existing `SecretStore` → save metadata via the existing `HostStore`, behind an `IdentityMinter` protocol so the orchestration is `swift test`-verified on Linux with a fake. The real `CoreIdentityMinter` bridges to Rust (macOS-only, `BridgeTests`). The app's `ConnectionViewModel` then uses the **already-wired** `authenticatePublickey` with a stored identity, and the `IdentityPickerSheet` stub tabs become real Create/Import flows.

**Tech Stack:** Rust (`ssh-key 0.7.0-rc.10` via `russh::keys::ssh_key`, UniFFI 0.31+), Swift 6 / `SemicolynKit` (XCTest, swift-crypto on Linux), SwiftUI app target (macOS-CI compile gate).

## Scope

**In scope (this plan, "2b-i"):**
- ed25519 key **generation** (iCloud-Keychain flavor) and existing-key **import** (ed25519 / ecdsa-p256 / ecdsa-p384 / rsa).
- Persisting the private key to the Keychain-backed `SecretStore` and the identity **metadata** via `HostStore` (both already exist).
- **publickey authentication** from a stored identity (the Rust `authenticate_publickey` bridge already exists — wire the app to it).
- The Create-new / Import-existing tabs of the inline `IdentityPickerSheet`.

**Explicitly DEFERRED (not this plan):**
- **Secure-Enclave flavor.** SE key generation needs SE hardware + a provisioning entitlement (gated on Apple Developer enrollment, still pending) **and** a russh→Swift signing-delegation bridge (russh can't hold an SE private key — signing must call back into `Security`). This is a separate future sub-phase. In 2b-i there is no SE code path at all: `IdentityService` only ever mints/imports the iCloud-Keychain flavor, and the picker shows a static "Secure Enclave keys arrive in a later update" explainer (no selectable SE action). The future SE phase adds the SE minting path and its own typed error.
- **CloudKit `BlobStore`** (Phase 2b-ii) — host/identity metadata still uses the local `FileBlobStore`; CloudKit lands once an Apple Developer account + container are provisioned.
- **Certificate attachment** to identities (`ssh-cert-auth-design`) — the Rust cert path exists; the identity-level cert UI/schema is a later increment.
- **Standalone Settings → Identities & Keys** management screens (list/detail) — Phase 5. This plan only touches the inline create/import half-sheet needed to connect.

## File Structure

| File | Responsibility | Test surface |
|---|---|---|
| `crates/semicolyn-ssh-core/src/keys.rs` *(create)* | `KeyMaterial` record, `KeyError`, `mint_ed25519_identity()`, `import_private_key()` | Linux `cargo test` (Critical) |
| `crates/semicolyn-ssh-core/src/lib.rs` *(modify)* | register `mod keys;` | — |
| `crates/semicolyn-ssh-core/Cargo.toml` *(modify)* | add `ssh-key` direct dep w/ generation+encryption features | — |
| `crates/semicolyn-ssh-core/tests/fixtures/` *(create)* | committed ed25519 test key + `.pub` for import tests | — |
| `Sources/SemicolynKit/Storage/IdentityService.swift` *(create)* | `KeyMaterial` value type, `IdentityMinter` protocol, `IdentityService`, `IdentityServiceError` | Linux `swift test` (Core) |
| `Tests/SemicolynKitTests/IdentityServiceTests.swift` *(create)* | `FakeIdentityMinter` + service behavior | Linux `swift test` |
| `App/CoreIdentityMinter.swift` *(create, macOS-only)* | `IdentityMinter` impl bridging to `SemicolynSSHCoreFFI` | macOS `BridgeTests` |
| `Tests/BridgeTests/CoreIdentityMinterTests.swift` *(create, macOS-only)* | mint/import round-trip against real Rust | macOS CI |
| `App/AppStores.swift` *(modify)* | expose a built `IdentityService` | compile gate |
| `App/ConnectionViewModel.swift` *(modify)* | connect-with-identity (publickey) path | compile gate |
| `App/IdentityPickerSheet.swift` *(modify)* | real Create-new / Import-existing tabs | compile gate |

## Global Constraints

- Every source/test file begins with `// SPDX-FileCopyrightText: 2026 True Positive LLC` then `// SPDX-License-Identifier: GPL-3.0-only` (Rust uses `//`; keep first two lines).
- **No new Apple-only APIs in `SemicolynKit`** — `IdentityService` and `KeyMaterial` are pure value-type Swift that compile and test on Linux. Anything touching `SemicolynSSHCoreFFI`/`Security` lives in the `App/` target (macOS-only).
- Secrets (private-key material) live **only** in `SecretStore` via `SecretRef.privateKey(identityID:)`; identity **metadata** records (public key, fingerprint) go through `HostStore`/`EncryptedRecordStore`. Never put private-key bytes in a `BlobStore` record.
- `cargo deny check licenses` must stay green — `ssh-key` is Apache-2.0/MIT (GPL-3-compatible); do not pull an OpenSSL-tagged dep.
- Testing tier: **Critical** for `keys.rs` (mint/import/fingerprint correctness, adversarial: malformed key, wrong/missing passphrase, unsupported algorithm). **Core** for `IdentityService` (EP + BVA, good AND bad cases, exact-value assertions).
- Conventional commits; commit after every green step. Branch `feat/phase-2b-i-apple-key-minting`; squash-merge at the end.
- Rust test command: `docker compose run --rm dev cargo test -p semicolyn-ssh-core`. Swift test command: `docker compose run --rm dev swift test --filter IdentityServiceTests`.

---

### Task 0: Branch + plan doc

- [ ] **Step 1: Create the feature branch**

```bash
git checkout -b feat/phase-2b-i-apple-key-minting
```

- [ ] **Step 2: Commit the plan doc**

This file already lives at `docs/superpowers/plans/2026-06-23-phase-2b-i-apple-key-minting.md`. Commit it on the branch:

```bash
git add docs/superpowers/plans/2026-06-23-phase-2b-i-apple-key-minting.md
git commit -m "docs: Phase 2b-i Apple key-minting plan"
```

---

### Task 1: Rust key-minting + import (`keys.rs`)

The only genuinely new crypto. Lives in the Rust core because `ssh-key` (already in-tree as `russh::keys::ssh_key`) implements OpenSSH key generation, parsing, encoding, and fingerprinting correctly and is `cargo test`-able on Linux. Exposed over UniFFI for the Swift bridge.

**Files:**
- Modify: `crates/semicolyn-ssh-core/Cargo.toml`
- Create: `crates/semicolyn-ssh-core/src/keys.rs`
- Modify: `crates/semicolyn-ssh-core/src/lib.rs`
- Create: `crates/semicolyn-ssh-core/tests/fixtures/ed25519_test_key` + `…/ed25519_test_key.pub`

**Interfaces:**
- Produces (UniFFI-exported, consumed by Task 3):
  - `pub struct KeyMaterial { pub private_key_openssh: String, pub public_key_openssh: String, pub fingerprint_sha256: String, pub algorithm: String }` (`#[derive(uniffi::Record)]`). `algorithm` is one of `"ed25519" | "ecdsa-p256" | "ecdsa-p384" | "rsa"` (matches Swift `KeyAlgorithm` raw values). `public_key_openssh` is the single-line `ssh-ed25519 AAAA… comment` form; `fingerprint_sha256` is `SHA256:<base64-no-pad>`.
  - `pub enum KeyError { Generation { message }, Parse { message }, Decrypt { message }, UnsupportedAlgorithm { algorithm } }` (`#[derive(uniffi::Error, Debug, thiserror::Error)]`).
  - `pub fn mint_ed25519_identity() -> Result<KeyMaterial, KeyError>` (Swift: `mintEd25519Identity()`).
  - `pub fn import_private_key(openssh: String, passphrase: Option<String>) -> Result<KeyMaterial, KeyError>` (Swift: `importPrivateKey(openssh:passphrase:)`).

- [ ] **Step 1: Add the `ssh-key` direct dependency with generation features**

Pin to the exact version already resolved for russh so the type is identical (Cargo unifies one compiled crate; adding features here also enables them for russh's re-exported `russh::keys::ssh_key`). In `crates/semicolyn-ssh-core/Cargo.toml`, under `[dependencies]` (alongside `russh = "0.61"`), add:

```toml
ssh-key = { version = "=0.7.0-rc.10", default-features = false, features = ["alloc", "ed25519", "ecdsa", "rsa", "p256", "p384", "encryption", "rand_core", "getrandom"] }
thiserror = "1"
```

> If `thiserror` is already a dependency, do not duplicate it. If the feature set fails to resolve, drop to the minimum that compiles `PrivateKey::random` + `PrivateKey::decrypt`: at least `ed25519`, `encryption`, `rand_core`, `getrandom`.

- [ ] **Step 2: Generate and commit the import test fixture**

```bash
cd crates/semicolyn-ssh-core
mkdir -p tests/fixtures
ssh-keygen -t ed25519 -N '' -C "semicolyn-test" -f tests/fixtures/ed25519_test_key
ssh-keygen -lf tests/fixtures/ed25519_test_key.pub   # capture the SHA256:… fingerprint
cat tests/fixtures/ed25519_test_key.pub              # capture the exact ssh-ed25519 AAAA… line
```

Record the printed `SHA256:…` fingerprint and the exact `.pub` line — they become the expected values in Step 3. Commit both fixture files.

- [ ] **Step 3: Write the failing tests**

Create `crates/semicolyn-ssh-core/src/keys.rs` ending with a `#[cfg(test)] mod tests`. Paste the **exact** captured fixture values into `EXPECTED_PUBLIC` / `EXPECTED_FINGERPRINT`.

```rust
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
//! SSH identity key material: generate a fresh ed25519 keypair or import an
//! existing OpenSSH private key, returning its OpenSSH public form + SHA256
//! fingerprint for storage as a Semicolyn identity. Private bytes are returned to
//! the caller (Swift) which stores them in the Keychain-backed SecretStore;
//! this module never persists anything.

use russh::keys::ssh_key::{Algorithm, EcdsaCurve, HashAlg, LineEnding, PrivateKey};

#[derive(uniffi::Record)]
pub struct KeyMaterial {
    pub private_key_openssh: String,
    pub public_key_openssh: String,
    pub fingerprint_sha256: String,
    pub algorithm: String,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum KeyError {
    #[error("key generation failed: {message}")]
    Generation { message: String },
    #[error("could not parse private key: {message}")]
    Parse { message: String },
    #[error("could not decrypt private key (wrong or missing passphrase): {message}")]
    Decrypt { message: String },
    #[error("unsupported key algorithm: {algorithm}")]
    UnsupportedAlgorithm { algorithm: String },
}

/// Maps an ssh-key `Algorithm` to Semicolyn's `KeyAlgorithm` raw value, or `None`
/// for algorithms Semicolyn does not model (dsa, p521, sk-*, etc.).
fn algorithm_tag(alg: &Algorithm) -> Option<&'static str> {
    match alg {
        Algorithm::Ed25519 => Some("ed25519"),
        Algorithm::Ecdsa { curve: EcdsaCurve::NistP256 } => Some("ecdsa-p256"),
        Algorithm::Ecdsa { curve: EcdsaCurve::NistP384 } => Some("ecdsa-p384"),
        Algorithm::Rsa { .. } => Some("rsa"),
        _ => None,
    }
}

/// Builds `KeyMaterial` from a decrypted `PrivateKey`, rejecting unmodeled algorithms.
fn material(key: &PrivateKey) -> Result<KeyMaterial, KeyError> {
    let alg = key.algorithm();
    let tag = algorithm_tag(&alg)
        .ok_or_else(|| KeyError::UnsupportedAlgorithm { algorithm: alg.to_string() })?;
    let private = key
        .to_openssh(LineEnding::LF)
        .map_err(|e| KeyError::Generation { message: e.to_string() })?
        .to_string();
    let public = key
        .public_key()
        .to_openssh()
        .map_err(|e| KeyError::Generation { message: e.to_string() })?;
    let fingerprint = key.fingerprint(HashAlg::Sha256).to_string();
    Ok(KeyMaterial {
        private_key_openssh: private,
        public_key_openssh: public,
        fingerprint_sha256: fingerprint,
        algorithm: tag.to_string(),
    })
}

#[uniffi::export]
pub fn mint_ed25519_identity() -> Result<KeyMaterial, KeyError> {
    let key = PrivateKey::random(&mut russh::keys::ssh_key::rand_core::OsRng, Algorithm::Ed25519)
        .map_err(|e| KeyError::Generation { message: e.to_string() })?;
    material(&key)
}

#[uniffi::export]
pub fn import_private_key(openssh: String, passphrase: Option<String>) -> Result<KeyMaterial, KeyError> {
    let key = PrivateKey::from_openssh(openssh.as_bytes())
        .map_err(|e| KeyError::Parse { message: e.to_string() })?;
    let decrypted = if key.is_encrypted() {
        let pass = passphrase.ok_or_else(|| KeyError::Decrypt {
            message: "passphrase required for an encrypted key".to_string(),
        })?;
        key.decrypt(pass.as_bytes())
            .map_err(|e| KeyError::Decrypt { message: e.to_string() })?
    } else {
        key
    };
    material(&decrypted)
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = include_str!("../tests/fixtures/ed25519_test_key");
    // Paste the EXACT values captured in Step 2:
    const EXPECTED_PUBLIC: &str = "ssh-ed25519 AAAA…== semicolyn-test";
    const EXPECTED_FINGERPRINT: &str = "SHA256:…";

    #[test]
    fn mint_produces_a_round_trippable_ed25519_key() {
        let m = mint_ed25519_identity().expect("mint");
        assert_eq!(m.algorithm, "ed25519");
        assert!(m.fingerprint_sha256.starts_with("SHA256:"));
        assert!(m.public_key_openssh.starts_with("ssh-ed25519 "));
        // The minted private key parses back and yields the SAME public + fingerprint.
        let reparsed = import_private_key(m.private_key_openssh.clone(), None).expect("reparse");
        assert_eq!(reparsed.public_key_openssh, m.public_key_openssh);
        assert_eq!(reparsed.fingerprint_sha256, m.fingerprint_sha256);
    }

    #[test]
    fn mint_keys_are_distinct() {
        let a = mint_ed25519_identity().unwrap();
        let b = mint_ed25519_identity().unwrap();
        assert_ne!(a.fingerprint_sha256, b.fingerprint_sha256);
    }

    #[test]
    fn import_unencrypted_fixture_yields_known_public_and_fingerprint() {
        let m = import_private_key(FIXTURE.to_string(), None).expect("import");
        assert_eq!(m.algorithm, "ed25519");
        assert_eq!(m.public_key_openssh, EXPECTED_PUBLIC);
        assert_eq!(m.fingerprint_sha256, EXPECTED_FINGERPRINT);
    }

    #[test]
    fn import_rejects_malformed_key() {
        let err = import_private_key("not a key".to_string(), None).unwrap_err();
        assert!(matches!(err, KeyError::Parse { .. }));
    }

    #[test]
    fn import_encrypted_key_without_passphrase_is_a_decrypt_error() {
        // An encrypted key generated for this test:
        let enc = encrypted_fixture();
        let err = import_private_key(enc, None).unwrap_err();
        assert!(matches!(err, KeyError::Decrypt { .. }));
    }

    #[test]
    fn import_encrypted_key_with_wrong_passphrase_is_a_decrypt_error() {
        let enc = encrypted_fixture();
        let err = import_private_key(enc, Some("wrong".to_string())).unwrap_err();
        assert!(matches!(err, KeyError::Decrypt { .. }));
    }

    /// Generates an in-test passphrase-encrypted ed25519 key (`hunter2`) in
    /// OpenSSH format, so the encrypted-import cases need no committed secret.
    fn encrypted_fixture() -> String {
        let key = PrivateKey::random(
            &mut russh::keys::ssh_key::rand_core::OsRng, Algorithm::Ed25519).unwrap();
        key.encrypt(&mut russh::keys::ssh_key::rand_core::OsRng, b"hunter2")
            .unwrap()
            .to_openssh(LineEnding::LF)
            .unwrap()
            .to_string()
    }
}
```

> If `PrivateKey::encrypt`'s signature differs in 0.7.0-rc.10 (e.g. it takes only the passphrase), adjust the `encrypted_fixture` helper accordingly — the assertion contract (encrypted key without/with-wrong passphrase ⇒ `KeyError::Decrypt`) is what matters.

- [ ] **Step 4: Register the module**

In `crates/semicolyn-ssh-core/src/lib.rs`, add after the existing `mod` lines:

```rust
pub mod keys;
```

- [ ] **Step 5: Run the tests — expect them to pass**

```bash
docker compose run --rm dev cargo test -p semicolyn-ssh-core keys
```

Expected: all `keys::tests::*` pass. If `mint_…` or `import_…` fail to compile on a feature, revisit Step 1's feature list.

- [ ] **Step 6: License gate + commit**

```bash
docker compose run --rm dev cargo deny check licenses
git add crates/semicolyn-ssh-core/Cargo.toml crates/semicolyn-ssh-core/src/keys.rs \
        crates/semicolyn-ssh-core/src/lib.rs crates/semicolyn-ssh-core/tests/fixtures Cargo.lock
git commit -m "feat: ssh key minting + import in the Rust core"
```

---

### Task 2: `IdentityService` orchestration (SemicolynKit, Linux-tested)

Pure-Swift orchestration over the **existing** `HostStore` (identity metadata CRUD) and `SecretStore` (private-key storage), behind an `IdentityMinter` protocol so the whole flow tests on Linux with a fake. This is the heart of the feature and where the real assurance lives.

**Files:**
- Create: `Sources/SemicolynKit/Storage/IdentityService.swift`
- Test: `Tests/SemicolynKitTests/IdentityServiceTests.swift`

**Interfaces:**
- Consumes (exist): `Identity`, `IdentityFlavor`, `KeyAlgorithm`, `BiometricPolicy` (`Model/Identity.swift`); `HostStore.saveIdentity(_:)`, `.identity(id:)`, `.allIdentities()` (`Storage/HostStore.swift`); `SecretStore.setSecret(_:for:)`, `.getSecret(_:)`, `SecretRef.privateKey(identityID:)` (`Storage/SecretStore.swift`).
- Produces (consumed by Tasks 3–5):
  - `public struct KeyMaterial: Equatable, Sendable { public let privateKeyOpenSSH: String; public let publicKeyOpenSSH: String; public let fingerprintSHA256: String; public let algorithm: KeyAlgorithm; public init(...) }`
  - `public protocol IdentityMinter { func mintEd25519() throws -> KeyMaterial; func importPrivateKey(_ openssh: String, passphrase: String?) throws -> KeyMaterial }`
  - `public enum IdentityServiceError: Error, Equatable { case minting(String) }`
  - `public struct IdentityService` with:
    - `init(store: HostStore, secrets: SecretStore, minter: IdentityMinter)`
    - `func createGenerated(displayName: String, biometricPolicy: BiometricPolicy, now: Date) throws -> Identity` — mints ed25519, persists private key, saves `.iCloudKeychain` metadata.
    - `func importIdentity(displayName: String, openssh: String, passphrase: String?, biometricPolicy: BiometricPolicy, now: Date) throws -> Identity`
    - `func privateKeyOpenSSH(for identityID: UUID) throws -> String?`

  > No Secure-Enclave path exists in 2b-i: `IdentityService` only mints/imports the iCloud-Keychain flavor. SE minting + its typed error land in the future SE sub-phase.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SemicolynKitTests/IdentityServiceTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

private struct FakeMinter: IdentityMinter {
    var minted: KeyMaterial
    var imported: KeyMaterial
    var importError: Error?
    func mintEd25519() throws -> KeyMaterial { minted }
    func importPrivateKey(_ openssh: String, passphrase: String?) throws -> KeyMaterial {
        if let importError { throw importError }
        return imported
    }
}

final class IdentityServiceTests: XCTestCase {
    private func makeStore() -> HostStore {
        HostStore(records: EncryptedRecordStore(backend: InMemoryBlobStore(),
                                                key: SymmetricKey(size: .bits256)))
    }

    private let sampleMinted = KeyMaterial(
        privateKeyOpenSSH: "PRIVATE-MINTED", publicKeyOpenSSH: "ssh-ed25519 AAAAMINTED c",
        fingerprintSHA256: "SHA256:mintedfp", algorithm: .ed25519)
    private let sampleImported = KeyMaterial(
        privateKeyOpenSSH: "PRIVATE-IMPORTED", publicKeyOpenSSH: "ssh-rsa AAAAIMPORTED c",
        fingerprintSHA256: "SHA256:importedfp", algorithm: .rsa)

    func testCreateGeneratedPersistsKeyAndMetadata() throws {
        let store = makeStore()
        let secrets = InMemorySecretStore()
        let svc = IdentityService(store: store, secrets: secrets,
                                  minter: FakeMinter(minted: sampleMinted, imported: sampleImported))
        let when = Date(timeIntervalSince1970: 1_700_000_000)

        let id = try svc.createGenerated(displayName: "personal", biometricPolicy: .afterUnlock, now: when)

        // Metadata saved with exactly the minted material.
        let saved = try XCTUnwrap(try store.identity(id: id.id))
        XCTAssertEqual(saved.displayName, "personal")
        XCTAssertEqual(saved.flavor, .iCloudKeychain)
        XCTAssertEqual(saved.algorithm, .ed25519)
        XCTAssertEqual(saved.publicKey, "ssh-ed25519 AAAAMINTED c")
        XCTAssertEqual(saved.fingerprint, "SHA256:mintedfp")
        XCTAssertEqual(saved.biometricPolicy, .afterUnlock)
        XCTAssertEqual(saved.createdAt, when)

        // Private key stored ONLY in the secret store, under the identity's id.
        let stored = try XCTUnwrap(try secrets.getSecret(.privateKey(identityID: id.id)))
        XCTAssertEqual(String(decoding: stored, as: UTF8.self), "PRIVATE-MINTED")
    }

    func testPrivateKeyOpenSSHRoundTrips() throws {
        let store = makeStore(); let secrets = InMemorySecretStore()
        let svc = IdentityService(store: store, secrets: secrets,
                                  minter: FakeMinter(minted: sampleMinted, imported: sampleImported))
        let id = try svc.createGenerated(displayName: "p", biometricPolicy: .afterUnlock, now: Date())
        XCTAssertEqual(try svc.privateKeyOpenSSH(for: id.id), "PRIVATE-MINTED")
    }

    func testPrivateKeyOpenSSHNilForUnknownIdentity() throws {
        let store = makeStore(); let secrets = InMemorySecretStore()
        let svc = IdentityService(store: store, secrets: secrets,
                                  minter: FakeMinter(minted: sampleMinted, imported: sampleImported))
        XCTAssertNil(try svc.privateKeyOpenSSH(for: UUID()))
    }

    func testImportPersistsParsedMaterial() throws {
        let store = makeStore(); let secrets = InMemorySecretStore()
        let svc = IdentityService(store: store, secrets: secrets,
                                  minter: FakeMinter(minted: sampleMinted, imported: sampleImported))
        let id = try svc.importIdentity(displayName: "work", openssh: "ignored-by-fake",
                                        passphrase: nil, biometricPolicy: .anyUse, now: Date())
        let saved = try XCTUnwrap(try store.identity(id: id.id))
        XCTAssertEqual(saved.algorithm, .rsa)
        XCTAssertEqual(saved.publicKey, "ssh-rsa AAAAIMPORTED c")
        XCTAssertEqual(saved.biometricPolicy, .anyUse)
        XCTAssertEqual(String(decoding: try XCTUnwrap(try secrets.getSecret(.privateKey(identityID: id.id))),
                              as: UTF8.self), "PRIVATE-IMPORTED")
    }

    func testImportSurfacesMinterFailureAsTypedError() throws {
        struct Boom: Error {}
        let store = makeStore(); let secrets = InMemorySecretStore()
        let svc = IdentityService(store: store, secrets: secrets,
                                  minter: FakeMinter(minted: sampleMinted, imported: sampleImported,
                                                     importError: Boom()))
        XCTAssertThrowsError(try svc.importIdentity(displayName: "x", openssh: "bad",
                                                    passphrase: nil, biometricPolicy: .afterUnlock, now: Date())) {
            XCTAssertEqual($0 as? IdentityServiceError, .minting("\(Boom())"))
        }
        // No partial write: neither metadata nor a secret was persisted.
        XCTAssertTrue(try store.allIdentities().isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
docker compose run --rm dev swift test --filter IdentityServiceTests
```

Expected: FAIL — `KeyMaterial`/`IdentityService` undefined.

- [ ] **Step 3: Implement `IdentityService.swift`**

```swift
// Sources/SemicolynKit/Storage/IdentityService.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Key material produced by an `IdentityMinter`. Pure value type — the private
/// key is plumbed straight into the `SecretStore` and never logged or copied
/// elsewhere. Mirrors the Rust core's `KeyMaterial` UniFFI record.
public struct KeyMaterial: Equatable, Sendable {
    public let privateKeyOpenSSH: String
    public let publicKeyOpenSSH: String
    public let fingerprintSHA256: String
    public let algorithm: KeyAlgorithm
    public init(privateKeyOpenSSH: String, publicKeyOpenSSH: String,
                fingerprintSHA256: String, algorithm: KeyAlgorithm) {
        self.privateKeyOpenSSH = privateKeyOpenSSH
        self.publicKeyOpenSSH = publicKeyOpenSSH
        self.fingerprintSHA256 = fingerprintSHA256
        self.algorithm = algorithm
    }
}

/// Generates and parses SSH key material. The Linux-testable seam: `SemicolynKit`
/// holds only the protocol; the concrete `CoreIdentityMinter` (App target,
/// macOS) bridges to the Rust core.
public protocol IdentityMinter {
    /// Generate a fresh ed25519 keypair.
    func mintEd25519() throws -> KeyMaterial
    /// Parse an OpenSSH private key (optionally passphrase-protected), deriving
    /// its public key + fingerprint.
    func importPrivateKey(_ openssh: String, passphrase: String?) throws -> KeyMaterial
}

/// Errors surfaced when creating or importing an identity.
public enum IdentityServiceError: Error, Equatable {
    /// The minter failed (generation or parse/decrypt). Carries its description.
    case minting(String)
}

/// Mints/imports an identity and persists it: private key → `SecretStore`,
/// metadata → `HostStore`. The only place the two stores are written together,
/// so the "private key in Keychain, metadata in records" invariant holds in one
/// spot. Writes the secret first, then metadata; on a minter failure nothing is
/// written (the throw happens before any store call).
public struct IdentityService {
    private let store: HostStore
    private let secrets: SecretStore
    private let minter: IdentityMinter

    public init(store: HostStore, secrets: SecretStore, minter: IdentityMinter) {
        self.store = store
        self.secrets = secrets
        self.minter = minter
    }

    /// Generate a new iCloud-Keychain ed25519 identity.
    @discardableResult
    public func createGenerated(displayName: String, biometricPolicy: BiometricPolicy,
                                now: Date) throws -> Identity {
        let material: KeyMaterial
        do { material = try minter.mintEd25519() }
        catch { throw IdentityServiceError.minting("\(error)") }
        return try persist(material, displayName: displayName,
                           biometricPolicy: biometricPolicy, now: now)
    }

    /// Import an existing private key as an iCloud-Keychain identity.
    @discardableResult
    public func importIdentity(displayName: String, openssh: String, passphrase: String?,
                               biometricPolicy: BiometricPolicy, now: Date) throws -> Identity {
        let material: KeyMaterial
        do { material = try minter.importPrivateKey(openssh, passphrase: passphrase) }
        catch { throw IdentityServiceError.minting("\(error)") }
        return try persist(material, displayName: displayName,
                           biometricPolicy: biometricPolicy, now: now)
    }

    /// The stored OpenSSH private key for `identityID`, or `nil` if absent.
    public func privateKeyOpenSSH(for identityID: UUID) throws -> String? {
        guard let data = try secrets.getSecret(.privateKey(identityID: identityID)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Shared persistence: secret first, then metadata. Both keyed by a fresh UUID.
    private func persist(_ material: KeyMaterial, displayName: String,
                         biometricPolicy: BiometricPolicy, now: Date) throws -> Identity {
        let id = UUID()
        try secrets.setSecret(Data(material.privateKeyOpenSSH.utf8),
                              for: .privateKey(identityID: id))
        let identity = Identity(
            id: id, displayName: displayName, flavor: .iCloudKeychain,
            algorithm: material.algorithm, publicKey: material.publicKeyOpenSSH,
            fingerprint: material.fingerprintSHA256, createdAt: now,
            biometricPolicy: biometricPolicy)
        try store.saveIdentity(identity)
        return identity
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
docker compose run --rm dev swift test --filter IdentityServiceTests
```

Expected: PASS (5/5).

- [ ] **Step 5: Commit**

```bash
git add Sources/SemicolynKit/Storage/IdentityService.swift Tests/SemicolynKitTests/IdentityServiceTests.swift
git commit -m "feat: IdentityService — mint/import + persist identities (Linux-tested)"
```

---

### Task 3: `CoreIdentityMinter` bridge (App target, macOS)

The real `IdentityMinter` that calls the Rust core. macOS-only (the bridge module is `#if os(macOS)`). Verified by a `BridgeTests` round-trip in macOS CI.

**Files:**
- Create: `App/CoreIdentityMinter.swift`
- Create: `Tests/BridgeTests/CoreIdentityMinterTests.swift`

**Interfaces:**
- Consumes: `SemicolynSSHCoreFFI.mintEd25519Identity()`, `SemicolynSSHCoreFFI.importPrivateKey(openssh:passphrase:)`, `SemicolynSSHCoreFFI.KeyMaterial`, `SemicolynSSHCoreFFI.KeyError` (generated from Task 1); `KeyMaterial`, `IdentityMinter`, `KeyAlgorithm` (Task 2).
- Produces: `struct CoreIdentityMinter: IdentityMinter` (consumed by Task 4).

- [ ] **Step 1: Write the bridge**

```swift
// App/CoreIdentityMinter.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SemicolynKit
import SemicolynSSHCoreFFI

/// `IdentityMinter` backed by the Rust SSH core. Translates the UniFFI
/// `KeyMaterial`/`KeyError` into SemicolynKit's pure value types. Errors propagate
/// as-is; `IdentityService` wraps them in `IdentityServiceError.minting`.
struct CoreIdentityMinter: IdentityMinter {
    func mintEd25519() throws -> SemicolynKit.KeyMaterial {
        try map(SemicolynSSHCoreFFI.mintEd25519Identity())
    }

    func importPrivateKey(_ openssh: String, passphrase: String?) throws -> SemicolynKit.KeyMaterial {
        try map(SemicolynSSHCoreFFI.importPrivateKey(openssh: openssh, passphrase: passphrase))
    }

    /// Maps an FFI `KeyMaterial`; an unmodeled algorithm string is a programmer
    /// error (the Rust side already rejects them) but is surfaced, not crashed.
    private func map(_ m: SemicolynSSHCoreFFI.KeyMaterial) throws -> SemicolynKit.KeyMaterial {
        guard let alg = KeyAlgorithm(rawValue: m.algorithm) else {
            throw IdentityServiceError.minting("unsupported algorithm: \(m.algorithm)")
        }
        return SemicolynKit.KeyMaterial(
            privateKeyOpenSSH: m.privateKeyOpenSSH, publicKeyOpenSSH: m.publicKeyOpenSSH,
            fingerprintSHA256: m.fingerprintSha256, algorithm: alg)
    }
}
```

> Confirm the generated Swift field name for `fingerprint_sha256` — UniFFI lower-camel-cases to `fingerprintSha256`. If the binding emits `fingerprintSHA256`, adjust.

- [ ] **Step 2: Write the macOS round-trip test**

```swift
// Tests/BridgeTests/CoreIdentityMinterTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import SemicolynSSHCoreFFI

final class CoreIdentityMinterTests: XCTestCase {
    func testMintProducesParsableEd25519() throws {
        let m = try SemicolynSSHCoreFFI.mintEd25519Identity()
        XCTAssertEqual(m.algorithm, "ed25519")
        XCTAssertTrue(m.publicKeyOpenSSH.hasPrefix("ssh-ed25519 "))
        XCTAssertTrue(m.fingerprintSha256.hasPrefix("SHA256:"))
        // Round-trips: the minted private key re-imports to the same public key.
        let reparsed = try SemicolynSSHCoreFFI.importPrivateKey(openssh: m.privateKeyOpenSSH, passphrase: nil)
        XCTAssertEqual(reparsed.publicKeyOpenSSH, m.publicKeyOpenSSH)
        XCTAssertEqual(reparsed.fingerprintSha256, m.fingerprintSha256)
    }

    func testImportRejectsGarbage() {
        XCTAssertThrowsError(try SemicolynSSHCoreFFI.importPrivateKey(openssh: "nope", passphrase: nil))
    }
}
```

> This test targets `SemicolynSSHCoreFFI` directly (the `BridgeTests` target already links it). `CoreIdentityMinter` itself is exercised through the app in Tasks 4–5; its only logic is the value mapping, covered by the round-trip's field assertions.

- [ ] **Step 3: Commit (CI builds/runs it on macOS)**

```bash
git add App/CoreIdentityMinter.swift Tests/BridgeTests/CoreIdentityMinterTests.swift
git commit -m "feat: CoreIdentityMinter bridge + macOS round-trip test"
```

---

### Task 4: Connect-with-identity (App, publickey auth path)

`authenticate_publickey` already exists in the Rust bridge and `connect…` already does password auth. Add an identity-aware path: when a host references a publickey identity, load its stored private key and authenticate with it.

**Files:**
- Modify: `App/AppStores.swift`
- Modify: `App/ConnectionViewModel.swift`

**Interfaces:**
- Consumes: `IdentityService` (Task 2), `CoreIdentityMinter` (Task 3), `Connection.authenticatePublickey(user:privateKeyOpenssh:)` (exists), `Host.identities: Inherited<[UUID]>`, `Host.preferredAuthentications` (exist).
- Produces: `AppStores.shared.identities: IdentityService`; a private `authenticate(conn:user:host:password:)` helper on `ConnectionViewModel`.

- [ ] **Step 1: Expose `IdentityService` from `AppStores`**

In `App/AppStores.swift`, add a stored property and build it in `init()` after `self.hosts` is set:

```swift
    /// Mint/import + resolve SSH identities (publickey auth).
    let identities: IdentityService
```

```swift
        // After `self.hosts = HostStore(...)` and `self.secrets = secrets`:
        self.identities = IdentityService(store: self.hosts, secrets: secrets, minter: CoreIdentityMinter())
```

> `self.hosts` is assigned before `self.secrets` today; reorder so `secrets` and `hosts` both exist before constructing `identities` (move the `self.identities = …` line to the end of `init`).

- [ ] **Step 2: Add an auth resolver to `ConnectionViewModel`**

Add a helper that prefers a stored publickey identity, else password. Insert into `ConnectionViewModel`:

```swift
    /// Authenticate `conn` for `host`: if the host references a stored identity
    /// whose private key is available, use publickey; otherwise fall back to the
    /// supplied password. Returns the outcome; the caller maps non-success to a
    /// `.failed` state.
    private func authenticate(conn: Connection, user: String, host: Host,
                              password: String) async throws -> AuthOutcome {
        if let identityID = host.identities.value?.first,
           let key = try? AppStores.shared.identities.privateKeyOpenSSH(for: identityID) {
            let outcome = try await conn.authenticatePublickey(user: user, privateKeyOpenssh: key)
            if case .success = outcome { return outcome }
            // Publickey present but rejected: do not silently fall through to
            // password — surface the failure (matches the cert-auth no-fallback rule).
            return outcome
        }
        return try await conn.authenticatePassword(user: user, password: password)
    }
```

> Confirm the generated Swift label for `authenticate_publickey`'s `private_key_openssh` parameter — likely `privateKeyOpenssh`. Adjust if the binding differs.

- [ ] **Step 3: Use the resolver in both connect paths**

In `connect(savedHost:password:)` and `connect(host:port:user:password:)`, replace the existing:

```swift
                let outcome = try await conn.authenticatePassword(user: user, password: password)
```

with (using `savedHost`/`hostRecord` respectively):

```swift
                let outcome = try await authenticate(conn: conn, user: user, host: savedHost, password: password)
```

(In `connect(host:port:user:password:)` the host value is `hostRecord`.)

- [ ] **Step 4: Compile gate (macOS CI)**

This is App-target code; it builds on the macOS runner via the PR's existing CI. Locally, confirm the change is self-consistent (no Linux build covers `App/`). Commit:

```bash
git add App/AppStores.swift App/ConnectionViewModel.swift
git commit -m "feat: prefer stored publickey identity over password when connecting"
```

---

### Task 5: Create-new / Import-existing tabs in `IdentityPickerSheet`

Replace the two stub tabs ("Key generation arrives with Secure-Enclave support") with working flows that call `IdentityService`. SE stays disabled with an explainer (the deferral).

**Files:**
- Modify: `App/IdentityPickerSheet.swift`

**Interfaces:**
- Consumes: `AppStores.shared.identities` (Task 4: `createGenerated`, `importIdentity`), `BiometricPolicy`, `IdentityServiceError`.
- Produces: no new public API — `onPick(Identity)` already dismisses and returns the new identity to the host editor.

- [ ] **Step 1: Replace the `stubTab` with real Create-new and Import-existing views**

In `App/IdentityPickerSheet.swift`, update the `switch selectedTab` to route `case 1: createNewTab` and `case 2: importExistingTab`, then add these to the struct (replacing `stubTab`). Use `@State` for the form fields and an `@State private var errorText: String?` for failures.

```swift
    // Shared form state
    @State private var newName = ""
    @State private var biometricPolicy: BiometricPolicy = .afterUnlock
    @State private var importName = ""
    @State private var pastedKey = ""
    @State private var passphrase = ""
    @State private var errorText: String?

    // MARK: - Create new tab (mint ed25519, iCloud Keychain)

    private var createNewTab: some View {
        Form {
            Section("New ed25519 key") {
                TextField("Display name", text: $newName)
                biometricPolicyPicker
            }
            Section {
                Button("Generate & Save") { generate() }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                if let errorText { Text(errorText).foregroundStyle(.red) }
            }
            secureEnclaveExplainer
        }
    }

    // MARK: - Import existing tab

    private var importExistingTab: some View {
        Form {
            Section("Display name") { TextField("Display name", text: $importName) }
            Section("Private key (OpenSSH)") {
                TextEditor(text: $pastedKey).font(.caption.monospaced()).frame(minHeight: 120)
            }
            Section("Passphrase (if the key is encrypted)") {
                SecureField("Optional", text: $passphrase)
            }
            Section { biometricPolicyPicker }
            Section {
                Button("Import & Save") { importKey() }
                    .disabled(importName.trimmingCharacters(in: .whitespaces).isEmpty || pastedKey.isEmpty)
            } footer: {
                if let errorText { Text(errorText).foregroundStyle(.red) }
            }
        }
    }

    private var biometricPolicyPicker: some View {
        Picker("Biometric", selection: $biometricPolicy) {
            Text("Never").tag(BiometricPolicy.never)
            Text("Per-unlock").tag(BiometricPolicy.afterUnlock)
            Text("Per-use").tag(BiometricPolicy.anyUse)
        }
    }

    /// SE deferral explainer (Phase 2b-i: iCloud Keychain only).
    private var secureEnclaveExplainer: some View {
        Section {
            Label("Secure Enclave keys arrive in a later update.", systemImage: "bolt.slash")
                .font(.caption).foregroundStyle(Color(theme.text.secondary))
        }
    }

    private func generate() {
        errorText = nil
        do {
            let id = try AppStores.shared.identities.createGenerated(
                displayName: newName.trimmingCharacters(in: .whitespaces),
                biometricPolicy: biometricPolicy, now: Date())
            onPick(id); dismiss()
        } catch { errorText = friendly(error) }
    }

    private func importKey() {
        errorText = nil
        do {
            let id = try AppStores.shared.identities.importIdentity(
                displayName: importName.trimmingCharacters(in: .whitespaces),
                openssh: pastedKey, passphrase: passphrase.isEmpty ? nil : passphrase,
                biometricPolicy: biometricPolicy, now: Date())
            onPick(id); dismiss()
        } catch { errorText = friendly(error) }
    }

    /// User-facing message for a service error.
    private func friendly(_ error: Error) -> String {
        switch error as? IdentityServiceError {
        case .minting(let m): return "Couldn't read that key: \(m)"
        case nil: return "Couldn't save the identity: \(error.localizedDescription)"
        }
    }
```

Then change the tab `switch` body:

```swift
                switch selectedTab {
                case 0: pickExistingTab
                case 1: createNewTab
                default: importExistingTab
                }
```

and delete the now-unused `stubTab`.

- [ ] **Step 2: Compile gate (macOS CI) + commit**

```bash
git add App/IdentityPickerSheet.swift
git commit -m "feat: real Create-new / Import-existing identity tabs"
```

---

### Task 6: CI gate, docs, and final review

- [ ] **Step 1: Open/refresh the PR and confirm CI is green**

Push the branch and open a draft PR (base `main`). Confirm both Linux jobs (`cargo test` incl. `keys::tests`, `swift test` incl. `IdentityServiceTests`) and the macOS job (XCFramework build → `BridgeTests` incl. `CoreIdentityMinterTests` → app build) are green.

```bash
git push -u github feat/phase-2b-i-apple-key-minting
gh pr create --draft --base main --title "feat: Phase 2b-i — Apple key-minting (iCloud Keychain)" \
  --body "Mint/import ed25519 identities + publickey connect. SE flavor + CloudKit deferred. See plan doc."
```

- [ ] **Step 2: Update project docs**

- `README.md` status table: mark identity create/import + publickey connect as shipped; note SE + CloudKit still pending.
- Append a Phase 2b-i section to `.git/sdd/progress.md` (or the active progress file) recording each task's commit range and the SE/CloudKit deferrals.

```bash
git add README.md
git commit -m "docs: mark identity minting + publickey connect shipped (Phase 2b-i)"
```

- [ ] **Step 3: Run `superpowers:requesting-code-review`**

Request review of the full branch diff. Resolve Critical/Important findings; commit fixes.

- [ ] **Step 4: Squash-merge**

Once CI is green and review is clean, squash-merge the PR to `main` and delete the branch.

## Self-Review (author checklist — completed)

- **Spec coverage:** `identities-keys-management` create/import sub-flow → Tasks 2/5; private-key-in-Keychain + metadata-in-records storage backbone (`host-config-model`) → Task 2 (`IdentityService.persist`); publickey auth → Task 4; SE flavor + CloudKit explicitly deferred with rationale (Scope). Standalone Identities & Keys management screens are Phase 5 (out of scope, noted).
- **Placeholder scan:** Two intentional capture-then-inline values in Task 1 (`EXPECTED_PUBLIC`/`EXPECTED_FINGERPRINT`) — the plan gives the exact `ssh-keygen` commands to produce them; this is a real-fixture instruction, not a TODO. No other placeholders.
- **Type consistency:** `KeyMaterial` (SemicolynKit, `fingerprintSHA256`) vs `SemicolynSSHCoreFFI.KeyMaterial` (`fingerprintSha256`) are distinct types mapped in Task 3 — flagged with a verify-the-generated-name note. `IdentityServiceError.minting(String)` (single case — no unused SE case, YAGNI) raised in Task 2, consumed in Task 5's `friendly(_:)`. `IdentityMinter` method names (`mintEd25519`, `importPrivateKey`) consistent across Tasks 2/3.
- **Open verification points for the implementer (flagged inline):** exact `ssh-key 0.7.0-rc.10` feature set for `PrivateKey::random`/`encrypt`/`decrypt`; UniFFI-generated Swift names (`fingerprintSha256`, `privateKeyOpenssh` param label).
