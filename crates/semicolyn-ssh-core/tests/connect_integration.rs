// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
use semicolyn_ssh_core::connection::{
    connect_core, ConnectError, HostKeyInfo, HostKeyVerifier, KeepaliveConfig,
};
use std::sync::{Arc, Mutex};

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
    std::env::var("SEMICOLYN_TEST_SSHD").ok()
}

#[tokio::test]
async fn connect_presents_well_formed_host_key_then_trusts() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD (run via docker compose)");
        return;
    };
    let v = Arc::new(RecordingVerifier {
        trust: true,
        seen: Mutex::new(None),
    });
    let conn = connect_core(addr, false, false, KeepaliveConfig::default(), v.clone()).await;
    assert!(conn.is_ok(), "trusted connection should succeed: {conn:?}");

    let seen = v
        .seen
        .lock()
        .unwrap()
        .clone()
        .expect("verifier was consulted");
    assert!(
        seen.fingerprint.starts_with("SHA256:"),
        "got {}",
        seen.fingerprint
    );
    assert!(!seen.key_type.is_empty());
}

#[tokio::test]
async fn connect_aborts_when_delegate_rejects() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD");
        return;
    };
    let v = Arc::new(RecordingVerifier {
        trust: false,
        seen: Mutex::new(None),
    });
    let err = connect_core(addr, false, false, KeepaliveConfig::default(), v)
        .await
        .unwrap_err();
    assert!(matches!(err, ConnectError::HostKeyRejected), "got {err:?}");
}

#[tokio::test]
async fn tier3_algorithms_are_detected_when_negotiated() {
    let Some(addr) = std::env::var("SEMICOLYN_TEST_SSHD_LEGACY").ok() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD_LEGACY");
        return;
    };
    // allow_deprecated so build_preferred offers the Tier-3 algorithms the
    // legacy server requires; without it, negotiation would fail outright.
    let v = Arc::new(RecordingVerifier {
        trust: true,
        seen: Mutex::new(None),
    });
    let conn = connect_core(addr, false, true, KeepaliveConfig::default(), v)
        .await
        .expect("legacy connect");

    let flagged = conn.tier3_in_use();
    assert!(flagged.contains(&"ssh-rsa".to_string()), "got {flagged:?}");
    assert!(
        flagged.contains(&"diffie-hellman-group14-sha1".to_string()),
        "got {flagged:?}"
    );
    assert!(
        flagged.contains(&"hmac-sha1".to_string()),
        "got {flagged:?}"
    );
}

#[tokio::test]
async fn modern_session_flags_no_tier3() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD");
        return;
    };
    let v = Arc::new(RecordingVerifier {
        trust: true,
        seen: Mutex::new(None),
    });
    let conn = connect_core(addr, false, false, KeepaliveConfig::default(), v)
        .await
        .expect("modern connect");
    assert!(conn.tier3_in_use().is_empty());
}
