// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
//! Phase 3e — `open_exec` (PTY-backed exec channel): the transport that carries
//! a `tmux -CC` control-mode stream. Generic-exec cases prove the channel works
//! independent of tmux; the `tmux -CC` smoke proves the real target command
//! produces a control-mode handshake. Gated on `SEMICOLYN_TEST_SSHD`.
use semicolyn_ssh_core::connection::{
    connect_core, AuthOutcome, Connection, HostKeyInfo, HostKeyVerifier, KeepaliveConfig,
    ShellExit, ShellOutput,
};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;
use tokio::sync::Mutex as AsyncMutex;

/// Serialise all tmux control-mode tests against the shared fixture server.
/// Two concurrent `tmux -CC` attach sessions on the same server cause one to
/// receive `%exit server exited unexpectedly` — the close() from one test tears
/// down the server before the other test finishes.
fn tmux_lock() -> &'static AsyncMutex<()> {
    static LOCK: OnceLock<AsyncMutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| AsyncMutex::new(()))
}

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
/// assert on observable channel behavior (streamed bytes, exit code).
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
    std::env::var("SEMICOLYN_TEST_SSHD").ok()
}

/// Poll `pred` up to ~5s. Returns its final value so a real timeout fails the
/// test rather than hanging.
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
    conn
}

#[tokio::test]
async fn exec_streams_command_stdout() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD");
        return;
    };
    let conn = connect_and_auth(addr).await;
    let col = Collector::new();
    // No close(): `printf` self-exits, so the channel closes on its own — unlike
    // the `tmux -CC` attach below, which stays live until told to close.
    let _session = conn
        .open_exec(
            "printf semicolyn-exec-marker".into(),
            "xterm".into(),
            80,
            24,
            Arc::new(col.clone()),
        )
        .await
        .expect("open exec");
    let saw = wait_until(|| col.text().contains("semicolyn-exec-marker")).await;
    assert!(
        saw,
        "expected exec stdout to contain marker, got: {:?}",
        col.text()
    );
}

#[tokio::test]
async fn exec_clean_exit_reports_status_zero() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD");
        return;
    };
    let conn = connect_and_auth(addr).await;
    let col = Collector::new();
    let _session = conn
        .open_exec(
            "sh -c 'exit 0'".into(),
            "xterm".into(),
            80,
            24,
            Arc::new(col.clone()),
        )
        .await
        .expect("open exec");
    let closed = wait_until(|| col.exit().is_some()).await;
    assert!(closed, "exec did not report closure");
    let exit = col.exit().unwrap();
    assert_eq!(exit.exit_status, Some(0));
    assert_eq!(exit.signal, None);
    assert_eq!(exit.error, None);
}

#[tokio::test]
async fn exec_nonzero_exit_reports_real_code() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD");
        return;
    };
    let conn = connect_and_auth(addr).await;
    let col = Collector::new();
    let _session = conn
        .open_exec(
            "sh -c 'exit 7'".into(),
            "xterm".into(),
            80,
            24,
            Arc::new(col.clone()),
        )
        .await
        .expect("open exec");
    let closed = wait_until(|| col.exit().is_some()).await;
    assert!(closed, "exec did not report closure");
    // Proves we surface the server's real exit code, not a hardcoded constant.
    assert_eq!(col.exit().unwrap().exit_status, Some(7));
}

#[tokio::test]
async fn tmux_control_mode_emits_handshake() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD");
        return;
    };
    let _guard = tmux_lock().lock().await;
    let conn = connect_and_auth(addr).await;
    let col = Collector::new();
    let session = conn
        .open_exec(
            "tmux -CC new-session -A -s semicolyn-test".into(),
            "xterm".into(),
            80,
            24,
            Arc::new(col.clone()),
        )
        .await
        .expect("open tmux control");
    // Assert on markers stable across BOTH fresh-create and re-attach (the
    // server-side session persists between runs — that is the reattach model):
    // the named-session notification and a control-mode `%begin` block. (A
    // `%window-add` only fires on fresh creation, so asserting it would make the
    // test pass once then fail on every re-run against the same tmux server.)
    // Both markers must be on the SAME line (`%session-changed $N semicolyn-test`) —
    // checking them independently could match across unrelated lines. The `$N`
    // session id is not pinned (it varies across tmux-server lifetimes), so the
    // assertion matches the line, not a fixed id.
    let saw = wait_until(|| {
        col.text()
            .lines()
            .any(|l| l.contains("%session-changed") && l.contains("semicolyn-test"))
    })
    .await;
    assert!(
        saw,
        "expected tmux -CC control handshake naming the session, got: {:?}",
        col.text()
    );
    // `%begin` proves a real control-mode command block framed the stream — not
    // an error line echoed back (which would lack the protocol framing).
    assert!(
        col.text().contains("%begin"),
        "expected a %begin control-mode block, got: {:?}",
        col.text()
    );
    let _ = session.close().await;
}

#[tokio::test]
async fn tmux_cc_new_session_produces_control_mode_handshake() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD");
        return;
    };
    let _guard = tmux_lock().lock().await;
    let conn = connect_and_auth(addr).await;
    let col = Collector::new();
    let session = conn
        .open_exec(
            "tmux -CC new-session -A -s semicolyn-itest".into(),
            "xterm-256color".into(),
            80,
            24,
            Arc::new(col.clone()),
        )
        .await
        .expect("open_exec tmux -CC");

    // Control mode must emit a `%begin` command-block framing the initial
    // exchange, and a `%session-changed`/`%output`/`%window` event proving the
    // protocol session is live — not just an error echoed back without framing.
    let saw = wait_until(|| col.text().contains("%begin")).await;
    let text = col.text();
    assert!(saw, "expected a control-mode %begin block, got: {text:?}");
    assert!(
        text.contains("%session-changed") || text.contains("%output") || text.contains("%window"),
        "expected control-mode session events, got: {text:?}"
    );
    let _ = session.close().await;
}
