// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
use std::sync::{Arc, Mutex};
use glymr_ssh_core::connection::{connect_core, ConnectError, HostKeyInfo, HostKeyVerifier};

/// Records what the delegate was shown, and returns a fixed decision.
struct RecordingVerifier {
    trust: bool,
    seen: Mutex<Option<HostKeyInfo>>,
}
#[async_trait::async_trait]
impl HostKeyVerifier for RecordingVerifier {
    async fn verify(&self, info: HostKeyInfo) -> bool {
        *self.seen.lock().unwrap() = Some(info);
        self.trust
    }
}

fn sshd_addr() -> Option<String> {
    std::env::var("GLYMR_TEST_SSHD").ok()
}

#[tokio::test]
async fn connect_presents_well_formed_host_key_then_trusts() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set GLYMR_TEST_SSHD (run via docker compose)");
        return;
    };
    let v = Arc::new(RecordingVerifier { trust: true, seen: Mutex::new(None) });
    let conn = connect_core(addr, false, false, v.clone()).await;
    assert!(conn.is_ok(), "trusted connection should succeed: {conn:?}");

    let seen = v.seen.lock().unwrap().clone().expect("verifier was consulted");
    assert!(seen.fingerprint.starts_with("SHA256:"), "got {}", seen.fingerprint);
    assert!(!seen.key_type.is_empty());
}

#[tokio::test]
async fn connect_aborts_when_delegate_rejects() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set GLYMR_TEST_SSHD");
        return;
    };
    let v = Arc::new(RecordingVerifier { trust: false, seen: Mutex::new(None) });
    let err = connect_core(addr, false, false, v).await.unwrap_err();
    assert!(matches!(err, ConnectError::HostKeyRejected), "got {err:?}");
}
