// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

//! SSH algorithm allowlist — the closed set of algorithms Glymr offers during
//! negotiation, per docs/superpowers/specs/2026-06-17-ssh-algorithms-design.md.
//!
//! Three spec'd algorithms are absent from russh 0.61.2 and omitted from v1
//! (they auto-enter when russh gains them):
//!   - sntrup761x25519-sha512@openssh.com (Tier 1 KEX) — ML-KEM remains the PQC KEX.
//!   - umac-128-etm@openssh.com (Tier 1 MAC).
//!   - hmac-sha1-96 (Tier 3 MAC).

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
