// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
use neotilde_ssh_core::connection::{
    connect_core, AuthOutcome, ConnectError, Connection, HostKeyInfo, HostKeyVerifier, ShellExit,
    ShellOutput,
};
use std::sync::{Arc, Mutex};
use std::time::Duration;

struct TrustAll;
#[async_trait::async_trait]
impl HostKeyVerifier for TrustAll {
    async fn verify(&self, _info: HostKeyInfo) -> bool {
        true
    }
}

#[derive(Default)]
struct Collected {
    out: Vec<u8>,
    exit: Option<ShellExit>,
}

/// Test double: accumulates output and records the close event so tests can
/// assert on observable shell behavior (echoed bytes, exit code, errors).
#[derive(Clone)]
struct Collector(Arc<Mutex<Collected>>);
impl Collector {
    fn new() -> Self {
        Collector(Arc::new(Mutex::new(Collected::default())))
    }
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.0.lock().unwrap().out).into_owned()
    }
    fn exit(&self) -> Option<ShellExit> {
        self.0.lock().unwrap().exit.clone()
    }
}
impl ShellOutput for Collector {
    fn on_output(&self, data: Vec<u8>) {
        self.0.lock().unwrap().out.extend_from_slice(&data);
    }
    fn on_closed(&self, exit: ShellExit) {
        self.0.lock().unwrap().exit = Some(exit);
    }
}

fn sshd_addr() -> Option<String> {
    std::env::var("NEOTILDE_TEST_SSHD").ok()
}

/// Poll `pred` up to ~5s (100 × 50ms). Returns its final value — true once the
/// async condition holds, false if it never did (so the test fails on a real
/// timeout rather than hanging).
async fn wait_until(mut pred: impl FnMut() -> bool) -> bool {
    for _ in 0..100 {
        if pred() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    pred()
}

async fn connect_and_auth(addr: String) -> Connection {
    let conn = connect_core(addr, false, false, Arc::new(TrustAll))
        .await
        .expect("connect");
    let outcome = conn
        .authenticate_password("tester".into(), "testpass".into())
        .await
        .expect("auth call");
    assert_eq!(outcome, AuthOutcome::Success);
    conn
}

#[tokio::test]
async fn shell_echoes_written_input() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set NEOTILDE_TEST_SSHD");
        return;
    };
    let conn = connect_and_auth(addr).await;
    let col = Collector::new();
    let session = conn
        .open_shell("xterm".into(), 80, 24, Arc::new(col.clone()))
        .await
        .expect("open shell");
    session
        .write(b"echo neotilde-marker\n".to_vec())
        .await
        .expect("write");
    let saw = wait_until(|| col.text().contains("neotilde-marker")).await;
    assert!(
        saw,
        "expected shell output to contain marker, got: {:?}",
        col.text()
    );
    let _ = session.close().await;
}

#[tokio::test]
async fn shell_clean_exit_reports_status_zero() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set NEOTILDE_TEST_SSHD");
        return;
    };
    let conn = connect_and_auth(addr).await;
    let col = Collector::new();
    let session = conn
        .open_shell("xterm".into(), 80, 24, Arc::new(col.clone()))
        .await
        .expect("open shell");
    session.write(b"exit 0\n".to_vec()).await.expect("write");
    let closed = wait_until(|| col.exit().is_some()).await;
    assert!(closed, "shell did not report closure");
    let exit = col.exit().unwrap();
    assert_eq!(exit.exit_status, Some(0));
    assert_eq!(exit.signal, None);
    assert_eq!(exit.error, None);
}

#[tokio::test]
async fn shell_resize_changes_window_size() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set NEOTILDE_TEST_SSHD");
        return;
    };
    let conn = connect_and_auth(addr).await;
    let col = Collector::new();
    let session = conn
        .open_shell("xterm".into(), 80, 24, Arc::new(col.clone()))
        .await
        .expect("open shell");
    session.resize(120, 40).await.expect("resize");
    session.write(b"stty size\n".to_vec()).await.expect("write");
    // `stty size` prints "<rows> <cols>" — the resized terminal is 40x120.
    let saw = wait_until(|| col.text().contains("40 120")).await;
    assert!(
        saw,
        "expected resized size 40 120 in output, got: {:?}",
        col.text()
    );
    let _ = session.close().await;
}

#[tokio::test]
async fn shell_nonzero_exit_reports_real_code() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set NEOTILDE_TEST_SSHD");
        return;
    };
    let conn = connect_and_auth(addr).await;
    let col = Collector::new();
    let session = conn
        .open_shell("xterm".into(), 80, 24, Arc::new(col.clone()))
        .await
        .expect("open shell");
    session.write(b"exit 3\n".to_vec()).await.expect("write");
    let closed = wait_until(|| col.exit().is_some()).await;
    assert!(closed, "shell did not report closure");
    // Proves we surface the server's real exit code, not a hardcoded constant.
    assert_eq!(col.exit().unwrap().exit_status, Some(3));
}

#[tokio::test]
async fn write_after_close_returns_typed_error() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set NEOTILDE_TEST_SSHD");
        return;
    };
    let conn = connect_and_auth(addr).await;
    let col = Collector::new();
    let session = conn
        .open_shell("xterm".into(), 80, 24, Arc::new(col.clone()))
        .await
        .expect("open shell");
    session.close().await.expect("close");
    // Wait for the pump task to actually finish (drops the receiver) — only then
    // is a further send guaranteed to fail rather than being buffered.
    let closed = wait_until(|| col.exit().is_some()).await;
    assert!(closed, "session did not close");
    let err = session
        .write(b"x".to_vec())
        .await
        .expect_err("write after close must fail");
    match err {
        ConnectError::Transport { message } => assert_eq!(message, "shell session closed"),
        other => panic!("expected Transport(\"shell session closed\"), got {other:?}"),
    }
}
