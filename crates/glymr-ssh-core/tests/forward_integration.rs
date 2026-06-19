// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
use std::sync::Arc;
use std::time::Duration;
#[allow(unused_imports)]
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use glymr_ssh_core::connection::{
    connect_core, AuthOutcome, Connection, ConnectError, HostKeyInfo, HostKeyVerifier,
};

struct TrustAll;
#[async_trait::async_trait]
impl HostKeyVerifier for TrustAll {
    async fn verify(&self, _info: HostKeyInfo) -> bool { true }
}

fn sshd_addr() -> Option<String> { std::env::var("GLYMR_TEST_SSHD").ok() }
#[allow(dead_code)]
fn sshd_host() -> Option<String> { sshd_addr().map(|a| a.split(':').next().unwrap_or("sshd").to_string()) }

async fn connect_and_auth(addr: String) -> Connection {
    let conn = connect_core(addr, false, false, Arc::new(TrustAll)).await.expect("connect");
    let outcome = conn.authenticate_password("tester".into(), "testpass".into()).await.expect("auth call");
    assert_eq!(outcome, AuthOutcome::Success);
    conn
}

// Tunnel local:0 -> (server) -> 127.0.0.1:22 (sshd's own port); reading the
// tunnel must yield sshd's SSH banner, proving end-to-end bidirectional flow.
#[tokio::test]
async fn local_forward_tunnels_to_remote_service() {
    let Some(addr) = sshd_addr() else { eprintln!("skipping: set GLYMR_TEST_SSHD"); return };
    let conn = connect_and_auth(addr).await;
    let fwd = conn
        .open_local_forward("127.0.0.1".into(), 0, "127.0.0.1".into(), 22)
        .await
        .expect("open local forward");
    let mut sock = tokio::net::TcpStream::connect(("127.0.0.1", fwd.bound_port()))
        .await
        .expect("connect to local forward");
    let mut buf = [0u8; 8];
    let n = tokio::time::timeout(Duration::from_secs(5), sock.read(&mut buf))
        .await
        .expect("read timed out")
        .expect("read");
    assert!(n >= 4 && &buf[..4] == b"SSH-", "expected SSH banner through tunnel, got {:?}", &buf[..n]);
    fwd.close().await;
}

#[tokio::test]
async fn local_forward_reports_bound_port() {
    let Some(addr) = sshd_addr() else { eprintln!("skipping: set GLYMR_TEST_SSHD"); return };
    let conn = connect_and_auth(addr).await;
    let fwd = conn
        .open_local_forward("127.0.0.1".into(), 0, "127.0.0.1".into(), 22)
        .await
        .expect("open local forward");
    assert_ne!(fwd.bound_port(), 0, "ephemeral bind must report a real port");
    fwd.close().await;
}

#[tokio::test]
async fn local_forward_close_frees_the_port() {
    let Some(addr) = sshd_addr() else { eprintln!("skipping: set GLYMR_TEST_SSHD"); return };
    let conn = connect_and_auth(addr).await;
    let fwd = conn
        .open_local_forward("127.0.0.1".into(), 0, "127.0.0.1".into(), 22)
        .await
        .expect("open local forward");
    let port = fwd.bound_port();
    fwd.close().await;
    // After close the accept loop is aborted and the listener dropped; give the
    // runtime a moment, then a fresh connect must be refused.
    tokio::time::sleep(Duration::from_millis(200)).await;
    let res = tokio::time::timeout(
        Duration::from_secs(2),
        tokio::net::TcpStream::connect(("127.0.0.1", port)),
    ).await.expect("connect attempt timed out");
    assert!(res.is_err(), "port {port} should be refused after close");
}

// Silence unused imports until later tasks use them.
#[allow(dead_code)]
fn _uses(_: Option<ConnectError>, _: fn(&mut [u8])) {}
