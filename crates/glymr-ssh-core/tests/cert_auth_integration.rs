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
        Err(e) => { eprintln!("skipping: /testkeys/{name}: {e}"); None }
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
