// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
use semicolyn_ssh_core::connection::{
    connect_core, AuthOutcome, ConnectError, HostKeyInfo, HostKeyVerifier, KeepaliveConfig,
};
use std::sync::{Arc, Mutex};

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

#[tokio::test]
async fn password_auth_succeeds_with_correct_credentials() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD");
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
        .authenticate_password("tester".into(), "testpass".into())
        .await
        .expect("auth call");
    assert_eq!(outcome, AuthOutcome::Success);
}

#[tokio::test]
async fn password_auth_fails_with_wrong_password() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD");
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
        .authenticate_password("tester".into(), "wrong".into())
        .await
        .expect("auth call");
    assert_eq!(outcome, AuthOutcome::Failure);
}

#[tokio::test]
async fn publickey_auth_succeeds_with_authorized_key() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD");
        return;
    };
    let key = match std::fs::read_to_string("/testkeys/id_ed25519") {
        Ok(k) => k,
        Err(_) => {
            eprintln!("skipping: /testkeys/id_ed25519 not mounted");
            return;
        }
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
        .authenticate_publickey("tester".into(), key)
        .await
        .expect("auth call");
    assert_eq!(outcome, AuthOutcome::Success);
}

#[tokio::test]
async fn keyboard_interactive_auth_succeeds_with_password_response() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD");
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
    // PAM keyboard-interactive presents a single password prompt.
    let outcome = conn
        .authenticate_keyboard_interactive("tester".into(), vec!["testpass".into()])
        .await
        .expect("auth call");
    assert_eq!(outcome, AuthOutcome::Success);
}

#[tokio::test]
async fn keyboard_interactive_auth_fails_with_wrong_response() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD");
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
        .authenticate_keyboard_interactive("tester".into(), vec!["wrong".into()])
        .await
        .expect("auth call");
    assert_eq!(outcome, AuthOutcome::Failure);
}

#[tokio::test]
async fn publickey_auth_fails_with_unauthorized_key() {
    // Adversarial "wrong key / credential" vector for the publickey path: a
    // well-formed key that is NOT in the fixture's authorized_keys must be
    // REJECTED (distinct from the malformed-key case below, which is a typed
    // parse error). Guards against a mapping that returns Success for any
    // parseable key.
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD");
        return;
    };
    // A freshly minted key is valid OpenSSH but was never added to the fixture.
    let unauthorized = semicolyn_ssh_core::keys::mint_ed25519_identity()
        .expect("mint")
        .private_key_openssh;
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
        .authenticate_publickey("tester".into(), unauthorized)
        .await
        .expect("auth call completes (a rejected key is a normal Failure, not an error)");
    assert_eq!(outcome, AuthOutcome::Failure);
}

#[tokio::test]
async fn publickey_auth_with_malformed_key_is_a_typed_error_not_a_panic() {
    // Adversarial "malformed input" vector: garbage in the private-key slot must
    // surface as a typed ConnectError::Transport ("invalid private key: …"), not
    // a panic across the FFI (an .unwrap() here would abort the app).
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD");
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
        .authenticate_publickey("tester".into(), "-----BEGIN nonsense-----".into())
        .await
        .expect_err("a malformed key must be a typed error");
    match err {
        ConnectError::Transport { message } => {
            assert!(
                message.starts_with("invalid private key"),
                "unexpected transport message: {message}"
            );
        }
        other => panic!("expected Transport(invalid private key), got {other:?}"),
    }
}

#[tokio::test]
async fn empty_password_auth_is_a_clean_failure() {
    // Empty/boundary auth vector: a zero-length password must be handled as a
    // normal Failure (server rejects it), never a panic or a hang.
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD");
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
        .authenticate_password("tester".into(), String::new())
        .await
        .expect("auth call completes");
    assert_eq!(outcome, AuthOutcome::Failure);
}

#[tokio::test]
async fn keyboard_interactive_with_no_responses_is_a_clean_failure() {
    // Empty/boundary auth for keyboard-interactive: with an empty `responses`
    // vec, the server's (non-empty) password prompt cannot be answered. This must
    // return a typed AuthOutcome::Failure — NOT send a short/blank reply that
    // trips the SSH reply-count mismatch and drops the transport, and NOT hang.
    // (Regression guard for the fail-fast-on-exhaustion fix.)
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD");
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
        .authenticate_keyboard_interactive("tester".into(), vec![])
        .await
        .expect("auth call completes (exhausted responses → typed Failure, not a transport drop)");
    assert_eq!(outcome, AuthOutcome::Failure);
}

// silence unused import warning until Task 2 uses Mutex
#[allow(dead_code)]
fn _uses_mutex() -> Mutex<()> {
    Mutex::new(())
}
