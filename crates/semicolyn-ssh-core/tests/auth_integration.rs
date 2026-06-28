// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
use semicolyn_ssh_core::connection::{connect_core, AuthOutcome, HostKeyInfo, HostKeyVerifier};
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
    let conn = connect_core(addr, false, false, Arc::new(TrustAll))
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
    let conn = connect_core(addr, false, false, Arc::new(TrustAll))
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
    let conn = connect_core(addr, false, false, Arc::new(TrustAll))
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
    let conn = connect_core(addr, false, false, Arc::new(TrustAll))
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
    let conn = connect_core(addr, false, false, Arc::new(TrustAll))
        .await
        .expect("connect");
    let outcome = conn
        .authenticate_keyboard_interactive("tester".into(), vec!["wrong".into()])
        .await
        .expect("auth call");
    assert_eq!(outcome, AuthOutcome::Failure);
}

// silence unused import warning until Task 2 uses Mutex
#[allow(dead_code)]
fn _uses_mutex() -> Mutex<()> {
    Mutex::new(())
}
