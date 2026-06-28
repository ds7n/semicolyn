// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
//! SSH identity key material: generate a fresh ed25519 keypair or import an
//! existing OpenSSH private key, returning its OpenSSH public form + SHA256
//! fingerprint for storage as a Semicolyn identity. Private bytes are returned to
//! the caller (Swift) which stores them in the Keychain-backed SecretStore;
//! this module never persists anything.

use getrandom::SysRng;
use rand_core::UnwrapErr;
use russh::keys::ssh_key::{Algorithm, EcdsaCurve, HashAlg, LineEnding, PrivateKey};

#[derive(Debug, uniffi::Record)]
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
        Algorithm::Ecdsa {
            curve: EcdsaCurve::NistP256,
        } => Some("ecdsa-p256"),
        Algorithm::Ecdsa {
            curve: EcdsaCurve::NistP384,
        } => Some("ecdsa-p384"),
        Algorithm::Rsa { .. } => Some("rsa"),
        _ => None,
    }
}

/// Builds `KeyMaterial` from a decrypted `PrivateKey`, rejecting unmodeled algorithms.
fn material(key: &PrivateKey) -> Result<KeyMaterial, KeyError> {
    let alg = key.algorithm();
    let tag = algorithm_tag(&alg).ok_or_else(|| KeyError::UnsupportedAlgorithm {
        algorithm: alg.to_string(),
    })?;
    let private = key
        .to_openssh(LineEnding::LF)
        .map_err(|e| KeyError::Generation {
            message: e.to_string(),
        })?
        .to_string();
    let public = key
        .public_key()
        .to_openssh()
        .map_err(|e| KeyError::Generation {
            message: e.to_string(),
        })?;
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
    let key = PrivateKey::random(&mut UnwrapErr(SysRng), Algorithm::Ed25519).map_err(|e| {
        KeyError::Generation {
            message: e.to_string(),
        }
    })?;
    material(&key)
}

#[uniffi::export]
pub fn import_private_key(
    openssh: String,
    passphrase: Option<String>,
) -> Result<KeyMaterial, KeyError> {
    let key = PrivateKey::from_openssh(openssh.as_bytes()).map_err(|e| KeyError::Parse {
        message: e.to_string(),
    })?;
    let decrypted = if key.is_encrypted() {
        let pass = passphrase.ok_or_else(|| KeyError::Decrypt {
            message: "passphrase required for an encrypted key".to_string(),
        })?;
        key.decrypt(pass.as_bytes())
            .map_err(|e| KeyError::Decrypt {
                message: e.to_string(),
            })?
    } else {
        key
    };
    material(&decrypted)
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = include_str!("../tests/fixtures/ed25519_test_key");
    // Exact values captured from ssh-keygen in Step 2:
    const EXPECTED_PUBLIC: &str =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHdjdNaZLZK183o6Pa7qySNDPXxGuHmDtFflqfOqtEod glymr-test";
    const EXPECTED_FINGERPRINT: &str = "SHA256:PtkDvL4UyR3eqdGREgOkWeVVVVs4HqzNN3IRI/pohX8";

    #[test]
    fn mint_produces_a_round_trippable_ed25519_key() {
        let m = mint_ed25519_identity().expect("mint");
        assert_eq!(m.algorithm, "ed25519");
        let parts: Vec<&str> = m.public_key_openssh.split_whitespace().collect();
        assert_eq!(parts.first(), Some(&"ssh-ed25519")); // exact algo field, not a prefix
        assert!(
            parts.len() >= 2,
            "public key must have an algo + base64 body"
        );
        assert!(parts[1].starts_with("AAAA"), "base64 body present");
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

    #[test]
    fn algorithm_tag_returns_some_for_supported_and_none_for_unsupported() {
        // Positive anchor: ed25519 is supported.
        assert_eq!(algorithm_tag(&Algorithm::Ed25519), Some("ed25519"));
        // DSA has never been modeled in Semicolyn.
        assert_eq!(algorithm_tag(&Algorithm::Dsa), None);
        // P-521 is not modeled (russh 0.61 client can't verify p521 host certs either).
        assert_eq!(
            algorithm_tag(&Algorithm::Ecdsa {
                curve: EcdsaCurve::NistP521
            }),
            None
        );
    }

    const P521_FIXTURE: &str = include_str!("../tests/fixtures/ecdsa_p521_test_key");

    #[test]
    fn import_p521_key_is_an_unsupported_algorithm_error() {
        // P-521 is parsed fine by ssh-key but rejected by algorithm_tag —
        // ssh-key's `p521` feature is enabled transitively, so it reaches the
        // Semicolyn UnsupportedAlgorithm gate rather than failing at parse.
        let err = import_private_key(P521_FIXTURE.to_string(), None).unwrap_err();
        assert!(matches!(err, KeyError::UnsupportedAlgorithm { .. }));
    }

    /// Generates an in-test passphrase-encrypted ed25519 key (`hunter2`) in
    /// OpenSSH format, so the encrypted-import cases need no committed secret.
    fn encrypted_fixture() -> String {
        let key = PrivateKey::random(&mut UnwrapErr(SysRng), Algorithm::Ed25519).unwrap();
        key.encrypt(&mut SysRng, b"hunter2")
            .unwrap()
            .to_openssh(LineEnding::LF)
            .unwrap()
            .to_string()
    }
}
