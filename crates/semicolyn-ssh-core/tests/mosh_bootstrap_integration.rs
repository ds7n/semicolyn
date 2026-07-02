// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
//! Bootstrap interop: SSH-authenticate, run `mosh-server new` via open_exec, and
//! assert a well-formed `MOSH CONNECT <port> <key>` line comes back from a REAL
//! mosh-server. The UDP session itself is Apple-only (libmoshios) and not tested here.

use semicolyn_ssh_core::connection::{
    connect_core, AuthOutcome, Connection, HostKeyInfo, HostKeyVerifier, ShellExit, ShellOutput,
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

/// Test double: accumulates streaming output and records the close event so
/// tests can assert on observable channel behavior.
#[derive(Clone)]
struct Collector(Arc<Mutex<Collected>>);
impl Collector {
    fn new() -> Self {
        Collector(Arc::new(Mutex::new(Collected::default())))
    }
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.0.lock().unwrap().out).into_owned()
    }
    #[allow(dead_code)]
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
    std::env::var("SEMICOLYN_TEST_SSHD").ok()
}

/// Poll `pred` up to ~10s. Returns its final value so a real timeout fails the
/// test rather than hanging. mosh-server daemonizes and may take longer than
/// tmux to emit its MOSH CONNECT line, so we use a 10s budget.
async fn wait_until(mut pred: impl FnMut() -> bool) -> bool {
    for _ in 0..200 {
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

/// Proves the SSH→mosh-server bootstrap works end-to-end:
/// 1. Authenticates via password to the test fixture sshd.
/// 2. Runs `mosh-server new` via open_exec (streaming API).
/// 3. Asserts a well-formed `MOSH CONNECT <port> <key>` line arrives.
/// 4. Validates the port is a valid u16 and the key is non-empty.
///
/// The UDP session itself is Apple-only and not exercised here.
#[tokio::test]
async fn mosh_server_emits_connect_line() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD to run mosh bootstrap test");
        return;
    };
    let conn = connect_and_auth(addr).await;
    let col = Collector::new();
    let session = conn
        .open_exec(
            "mosh-server new -s -c 256 -l LANG=C.UTF-8".into(),
            "xterm-256color".into(),
            80,
            24,
            Arc::new(col.clone()),
        )
        .await
        .expect("open_exec mosh-server");

    // mosh-server daemonizes: it forks, the parent prints "MOSH CONNECT <port> <key>"
    // to stdout (which the SSH channel captures), then exits. We poll up to 10s.
    let saw = wait_until(|| col.text().lines().any(|l| l.starts_with("MOSH CONNECT "))).await;

    let collected = col.text();
    assert!(
        saw,
        "expected a 'MOSH CONNECT <port> <key>' line from mosh-server, got: {:?}",
        collected
    );

    // Pull the specific line and validate its structure precisely.
    let connect_line = collected
        .lines()
        .find(|l| l.starts_with("MOSH CONNECT "))
        .expect("MOSH CONNECT line must exist (already asserted saw=true)");

    let parts: Vec<&str> = connect_line.split(' ').collect();
    assert_eq!(
        parts.len(),
        4,
        "MOSH CONNECT line must have exactly 4 space-separated parts (MOSH CONNECT <port> <key>), got: {:?}",
        connect_line
    );
    assert_eq!(
        parts[0], "MOSH",
        "first token must be 'MOSH', got: {:?}",
        parts[0]
    );
    assert_eq!(
        parts[1], "CONNECT",
        "second token must be 'CONNECT', got: {:?}",
        parts[1]
    );

    let port: u16 = parts[2]
        .parse()
        .unwrap_or_else(|_| panic!("port {:?} must parse as u16 (0–65535)", parts[2]));
    // mosh-server defaults to the 60000–61000 range; validate it's in the expected range.
    assert!(
        (60000..=61000).contains(&port),
        "mosh-server port {port} should be in the default range 60000–61000"
    );

    let key = parts[3];
    assert!(
        !key.is_empty(),
        "mosh session key must be non-empty, got: {:?}",
        connect_line
    );
    // mosh keys are base64-encoded 22-character strings (128-bit key → 22 base64 chars).
    assert_eq!(
        key.len(),
        22,
        "mosh session key should be 22 base64 characters, got len={} key={:?}",
        key.len(),
        key
    );

    // mosh-server daemonizes and will self-terminate after ~60s of UDP inactivity.
    // close() is best-effort cleanup of the SSH exec channel (the parent process
    // already exited; the child mosh-server process is independent).
    let _ = session.close().await;
}
