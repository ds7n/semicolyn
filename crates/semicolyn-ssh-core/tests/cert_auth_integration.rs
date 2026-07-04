// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
use semicolyn_ssh_core::connection::{
    connect_core, AuthOutcome, ConnectError, HostKeyInfo, HostKeyVerifier, KeepaliveConfig,
};
use std::sync::Arc;

struct TrustAll;
#[async_trait::async_trait]
impl HostKeyVerifier for TrustAll {
    async fn verify(&self, _info: HostKeyInfo) -> bool {
        true
    }
}

fn sshd_addr() -> Option<String> {
    std::env::var("SEMICOLYN_TEST_SSHD").ok()
}

fn read_testkey(name: &str) -> Option<String> {
    match std::fs::read_to_string(format!("/testkeys/{name}")) {
        Ok(s) => Some(s),
        Err(e) => {
            eprintln!("skipping: /testkeys/{name}: {e}");
            None
        }
    }
}

#[tokio::test]
async fn cert_auth_succeeds_with_valid_cert() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD");
        return;
    };
    let (Some(key), Some(cert)) = (read_testkey("id_ed25519"), read_testkey("valid-cert.pub"))
    else {
        return;
    };
    let conn = connect_core(
        addr,
        false,
        false,
        KeepaliveConfig::default(),
        Arc::new(TrustAll),
    )
    .await
    .expect("connect");
    let outcome = conn
        .authenticate_openssh_cert("tester".into(), key, cert)
        .await
        .expect("auth call");
    assert_eq!(outcome, AuthOutcome::Success);
}

#[tokio::test]
async fn cert_auth_rejects_expired_cert() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD");
        return;
    };
    let (Some(key), Some(cert)) = (read_testkey("id_ed25519"), read_testkey("expired-cert.pub"))
    else {
        return;
    };
    let conn = connect_core(
        addr,
        false,
        false,
        KeepaliveConfig::default(),
        Arc::new(TrustAll),
    )
    .await
    .expect("connect");
    let err = conn
        .authenticate_openssh_cert("tester".into(), key, cert)
        .await
        .expect_err("expired cert must be refused");
    match err {
        ConnectError::CertificateInvalid { message } => {
            assert_eq!(message, "certificate has expired")
        }
        other => panic!("expected CertificateInvalid(expired), got {other:?}"),
    }
}

#[tokio::test]
async fn cert_auth_rejects_not_yet_valid_cert() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD");
        return;
    };
    let (Some(key), Some(cert)) = (read_testkey("id_ed25519"), read_testkey("notyet-cert.pub"))
    else {
        return;
    };
    let conn = connect_core(
        addr,
        false,
        false,
        KeepaliveConfig::default(),
        Arc::new(TrustAll),
    )
    .await
    .expect("connect");
    let err = conn
        .authenticate_openssh_cert("tester".into(), key, cert)
        .await
        .expect_err("not-yet-valid cert must be refused");
    match err {
        ConnectError::CertificateInvalid { message } => {
            assert_eq!(message, "certificate is not yet valid")
        }
        other => panic!("expected CertificateInvalid(not yet valid), got {other:?}"),
    }
}

#[tokio::test]
async fn cert_auth_rejects_cert_for_a_different_key() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD");
        return;
    };
    // The CA private key is a valid ed25519 key unrelated to id_ed25519, so the
    // valid cert (which certifies id_ed25519) does not match it → pair failure.
    let (Some(wrong_key), Some(cert)) = (read_testkey("ca"), read_testkey("valid-cert.pub")) else {
        return;
    };
    let conn = connect_core(
        addr,
        false,
        false,
        KeepaliveConfig::default(),
        Arc::new(TrustAll),
    )
    .await
    .expect("connect");
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
