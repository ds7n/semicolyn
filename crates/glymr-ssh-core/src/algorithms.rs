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
//!
//! The spec also lists `ssh-ed25519-cert-v01@openssh.com` as a Tier-1 host-key
//! algorithm, but russh 0.61.2's *client* cannot verify a server host
//! *certificate*: the client kex (`client/kex.rs`) decodes the server host key
//! as a plain `PublicKey` (`parse_public_key`) and the trust delegate only ever
//! sees a `PublicKey` — there is no CA-signature / principal / validity path.
//! Advertising the cert variant would therefore promise a capability we cannot
//! honor, so the host-key list stays bare-key only and the
//! `host_key_list_excludes_unverifiable_cert_variants` test guards against
//! re-adding it. This lifts when russh gains client-side host-cert verification.

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

    // Tier 2 — legacy but allowed (per-host `glymr.allowLegacyAlgorithms`).
    if allow_legacy {
        kex_algs.push(kex::DH_G14_SHA256);
        kex_algs.push(kex::DH_GEX_SHA256);
        cipher_algs.push(cipher::AES_256_CBC);
        cipher_algs.push(cipher::AES_192_CBC);
        cipher_algs.push(cipher::AES_128_CBC);
    }

    // Tier 3 — legacy & risky (per-host `glymr.allowDeprecatedAlgorithms`).
    // Every connection that negotiates one of these shows a warning (Phase 1b
    // uses `is_tier3` to detect it). hmac-sha1-96 is spec'd here but absent from
    // russh 0.61 (omitted).
    if allow_deprecated {
        kex_algs.push(kex::DH_G14_SHA1);
        kex_algs.push(kex::DH_GEX_SHA1);
        mac_algs.push(mac::HMAC_SHA1);
        host_keys.push(Algorithm::Rsa { hash: None }); // ssh-rsa (SHA-1)
    }

    Preferred {
        kex: Cow::Owned(kex_algs),
        key: Cow::Owned(host_keys),
        cipher: Cow::Owned(cipher_algs),
        mac: Cow::Owned(mac_algs),
        compression: Cow::Borrowed(&[compression::NONE]),
    }
}

/// Wire names of the Tier-3 algorithms Glymr can offer. After a handshake,
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
    fn comp_wire(p: &russh::Preferred) -> Vec<&str> {
        p.compression.iter().map(|n| n.as_ref()).collect::<Vec<&str>>()
    }

    // Expected Tier-1 lists, in exact preference order (strongest first). The
    // exact-equality assertions below catch any drop, addition, reorder, or
    // typo — far stronger than membership checks. Tier-4 dead algorithms are
    // proven absent by exact equality (they appear in no expected list).
    const T1_KEX: &[&str] = &[
        "mlkem768x25519-sha256",
        "curve25519-sha256",
        "curve25519-sha256@libssh.org",
        "ecdh-sha2-nistp256",
        "ecdh-sha2-nistp384",
        "ecdh-sha2-nistp521",
        "diffie-hellman-group16-sha512",
        "diffie-hellman-group18-sha512",
    ];
    const T1_CIPHER: &[&str] = &[
        "chacha20-poly1305@openssh.com",
        "aes256-gcm@openssh.com",
        "aes128-gcm@openssh.com",
        "aes256-ctr",
        "aes192-ctr",
        "aes128-ctr",
    ];
    const T1_MAC: &[&str] = &[
        "hmac-sha2-256-etm@openssh.com",
        "hmac-sha2-512-etm@openssh.com",
        "hmac-sha2-256",
        "hmac-sha2-512",
    ];
    const T1_KEY: &[&str] = &[
        "ssh-ed25519",
        "rsa-sha2-512",
        "rsa-sha2-256",
        "ecdsa-sha2-nistp256",
        "ecdsa-sha2-nistp384",
        "ecdsa-sha2-nistp521",
    ];

    // Tier-2 (legacy) appends, in append order.
    const T2_KEX: &[&str] = &[
        "diffie-hellman-group14-sha256",
        "diffie-hellman-group-exchange-sha256",
    ];
    const T2_CIPHER: &[&str] = &["aes256-cbc", "aes192-cbc", "aes128-cbc"];

    // Tier-3 (deprecated) appends, in append order.
    const T3_KEX: &[&str] = &[
        "diffie-hellman-group14-sha1",
        "diffie-hellman-group-exchange-sha1",
    ];
    const T3_MAC: &[&str] = &["hmac-sha1"];
    const T3_KEY: &[&str] = &["ssh-rsa"];

    #[test]
    fn tier1_only_exact_ordered() {
        let p = build_preferred(false, false);
        assert_eq!(kex_wire(&p), T1_KEX);
        assert_eq!(cipher_wire(&p), T1_CIPHER);
        assert_eq!(mac_wire(&p), T1_MAC);
        assert_eq!(key_wire(&p), T1_KEY);
        assert_eq!(comp_wire(&p), ["none"]);
    }

    #[test]
    fn legacy_adds_tier2_exact_ordered() {
        let p = build_preferred(true, false);
        assert_eq!(kex_wire(&p), [T1_KEX, T2_KEX].concat());
        assert_eq!(cipher_wire(&p), [T1_CIPHER, T2_CIPHER].concat());
        // legacy touches only KEX + cipher; MAC and host-key stay Tier-1.
        assert_eq!(mac_wire(&p), T1_MAC);
        assert_eq!(key_wire(&p), T1_KEY);
    }

    #[test]
    fn deprecated_adds_tier3_exact_ordered() {
        let p = build_preferred(false, true);
        assert_eq!(kex_wire(&p), [T1_KEX, T3_KEX].concat());
        assert_eq!(mac_wire(&p), [T1_MAC, T3_MAC].concat());
        assert_eq!(key_wire(&p), [T1_KEY, T3_KEY].concat());
        // deprecated does not pull in Tier-2 ciphers.
        assert_eq!(cipher_wire(&p), T1_CIPHER);
    }

    #[test]
    fn both_toggles_exact_ordered_tier2_before_tier3() {
        let p = build_preferred(true, true);
        // Tier-2 appends precede Tier-3 appends (legacy block runs first).
        assert_eq!(kex_wire(&p), [T1_KEX, T2_KEX, T3_KEX].concat());
        assert_eq!(cipher_wire(&p), [T1_CIPHER, T2_CIPHER].concat());
        assert_eq!(mac_wire(&p), [T1_MAC, T3_MAC].concat());
        assert_eq!(key_wire(&p), [T1_KEY, T3_KEY].concat());
        // Tier-4 floor: dead algorithms appear in no list even with both toggles.
        for dead in ["3des-cbc", "ssh-dss", "hmac-md5", "arcfour", "diffie-hellman-group1-sha1"] {
            assert!(!kex_wire(&p).contains(&dead));
            assert!(!cipher_wire(&p).contains(&dead));
            assert!(!mac_wire(&p).contains(&dead));
            assert!(!key_wire(&p).contains(&dead));
        }
    }

    #[test]
    fn host_key_list_excludes_unverifiable_cert_variants() {
        // russh 0.61's client cannot verify a server host *certificate* (kex
        // parses the host key as a plain PublicKey; the trust delegate sees no
        // CA / principals / validity). Offering a `*-cert-v01@openssh.com`
        // host-key algorithm would advertise a capability we cannot honor, so no
        // tier — not even with both toggles on — may include one. Asserting this
        // across all four toggle combinations fails the moment a cert variant is
        // added before russh can back it.
        for (legacy, deprecated) in [(false, false), (true, false), (false, true), (true, true)] {
            let p = build_preferred(legacy, deprecated);
            for name in key_wire(&p) {
                assert!(
                    !name.ends_with("-cert-v01@openssh.com"),
                    "host-key list must not offer unverifiable cert variant {name} \
                     (legacy={legacy}, deprecated={deprecated})"
                );
            }
        }
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

    #[test]
    fn classifier_matches_what_the_deprecated_toggle_actually_adds() {
        // Every Tier-3 algorithm the builder appends must be classified Tier-3,
        // and nothing the Tier-1 builder offers may be — keeps the warning hook
        // and the offered set from drifting apart.
        let tier1 = build_preferred(false, false);
        let offered: Vec<&str> =
            [kex_wire(&tier1), cipher_wire(&tier1), mac_wire(&tier1), key_wire(&tier1)].concat();
        for name in offered {
            assert!(!is_tier3(name), "Tier-1 algorithm {name} must not be Tier-3");
        }
        for name in [T3_KEX, T3_MAC, T3_KEY].concat() {
            assert!(is_tier3(name), "appended Tier-3 algorithm {name} must classify as Tier-3");
        }
    }
}
