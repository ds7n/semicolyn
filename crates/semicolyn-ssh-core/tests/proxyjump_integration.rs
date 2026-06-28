// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

//! ProxyJump (jump-host chain) integration tests. A chain is built one hop at a
//! time: connect + authenticate to the jump host, then `connect_jump` to the
//! next hop and authenticate that, and so on. See
//! docs/superpowers/plans/2026-06-19-phase-1f-proxyjump.md.
//!
//! Topology: the dev container reaches `sshd` directly; `sshd` and `sshd-legacy`
//! share the compose network, so from a jump host the next hop (`sshd-legacy:22`
//! or `127.0.0.1:22` = the jump host itself) is reachable.

use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::AsyncReadExt;

use semicolyn_ssh_core::connection::{
    connect_core, AuthOutcome, ConnectError, Connection, HostKeyInfo, HostKeyVerifier, ShellExit,
    ShellOutput,
};

struct TrustAll;
#[async_trait::async_trait]
impl HostKeyVerifier for TrustAll {
    async fn verify(&self, _info: HostKeyInfo) -> bool {
        true
    }
}

struct RejectAll;
#[async_trait::async_trait]
impl HostKeyVerifier for RejectAll {
    async fn verify(&self, _info: HostKeyInfo) -> bool {
        false
    }
}

#[derive(Default)]
struct Collected {
    out: Vec<u8>,
    exit: Option<ShellExit>,
}

#[derive(Clone)]
struct Collector(Arc<Mutex<Collected>>);
impl Collector {
    fn new() -> Self {
        Collector(Arc::new(Mutex::new(Collected::default())))
    }
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.0.lock().unwrap().out).into_owned()
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

/// Service name of the legacy (Tier-3-only) sshd, derived from its addr env var.
fn legacy_host() -> Option<String> {
    std::env::var("SEMICOLYN_TEST_SSHD_LEGACY")
        .ok()
        .map(|a| a.split(':').next().unwrap_or("sshd-legacy").to_string())
}

async fn wait_until(mut pred: impl FnMut() -> bool) -> bool {
    for _ in 0..100 {
        if pred() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    pred()
}

/// Connect + password-auth to the jump host (modern algorithms).
async fn connect_jump_host(addr: String) -> Connection {
    let conn = connect_core(addr, false, false, Arc::new(TrustAll))
        .await
        .expect("connect to jump host");
    let outcome = conn
        .authenticate_password("tester".into(), "testpass".into())
        .await
        .expect("jump auth call");
    assert_eq!(outcome, AuthOutcome::Success, "jump-host auth must succeed");
    conn
}

// A two-hop chain: dev -> sshd (jump) -> sshd-legacy (target). The target hop is
// the Tier-3-only server, so it requires allow_deprecated — this also exercises
// per-hop algorithm policy. Opening a shell on the jumped connection and running
// a command proves the full nested path carries channel traffic end to end.
#[tokio::test]
async fn two_hop_chain_runs_shell_on_target() {
    let Some(jump) = sshd_addr() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD");
        return;
    };
    let Some(target_host) = legacy_host() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD_LEGACY");
        return;
    };

    let jump = connect_jump_host(jump).await;
    // allow_deprecated=true: the legacy target offers only Tier-3 algorithms.
    let target = jump
        .connect_jump(target_host, 22, false, true, Arc::new(TrustAll))
        .await
        .expect("jump to target");
    let outcome = target
        .authenticate_password("tester".into(), "testpass".into())
        .await
        .expect("target auth call");
    assert_eq!(outcome, AuthOutcome::Success, "target auth must succeed");

    // The negotiation at the target hop must reflect that hop's algorithms, not
    // the jump host's — the legacy target is Tier-3.
    assert!(
        target.tier3_in_use().contains(&"ssh-rsa".to_string()),
        "target hop should report its own Tier-3 algorithms, got {:?}",
        target.tier3_in_use()
    );

    let col = Collector::new();
    let session = target
        .open_shell("xterm".into(), 80, 24, Arc::new(col.clone()))
        .await
        .expect("open shell on target");
    session
        .write(b"echo proxyjump-marker\n".to_vec())
        .await
        .expect("write");
    let saw = wait_until(|| col.text().contains("proxyjump-marker")).await;
    assert!(
        saw,
        "expected marker from target shell, got: {:?}",
        col.text()
    );
    let _ = session.close().await;
}

// A forward opened on a *jumped* connection must work: dev -> sshd (jump) ->
// sshd (target, reached as 127.0.0.1:22 from the jump host's view). Open a local
// forward on the target connection to its own sshd and read the SSH banner.
#[tokio::test]
async fn local_forward_works_over_a_jump() {
    let Some(jump) = sshd_addr() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD");
        return;
    };

    let jump = connect_jump_host(jump).await;
    // Target = the jump host itself, reached as 127.0.0.1:22 from its own view.
    let target = jump
        .connect_jump("127.0.0.1".into(), 22, false, false, Arc::new(TrustAll))
        .await
        .expect("jump to target");
    let outcome = target
        .authenticate_password("tester".into(), "testpass".into())
        .await
        .expect("target auth call");
    assert_eq!(outcome, AuthOutcome::Success);

    let fwd = target
        .open_local_forward("127.0.0.1".into(), 0, "127.0.0.1".into(), 22)
        .await
        .expect("open local forward on jumped connection");
    let mut sock = tokio::net::TcpStream::connect(("127.0.0.1", fwd.bound_port()))
        .await
        .expect("connect to forward");
    let mut buf = [0u8; 8];
    let n = tokio::time::timeout(Duration::from_secs(5), sock.read(&mut buf))
        .await
        .expect("read timed out")
        .expect("read");
    assert!(
        n >= 4 && &buf[..4] == b"SSH-",
        "expected SSH banner through forward-over-jump, got {:?}",
        &buf[..n]
    );
    fwd.close().await;
}

// The jumped connection must keep the jump host's transport alive on its own:
// after the caller drops the intermediate `Connection`, the target — whose
// transport rides inside a channel on the jump host — must still work. This is
// the whole point of the `parents` keep-alive; without it the jump transport
// would close when `jump` drops and the target shell would fail.
#[tokio::test]
async fn dropping_intermediate_connection_keeps_chain_alive() {
    let Some(jump_addr) = sshd_addr() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD");
        return;
    };

    let jump = connect_jump_host(jump_addr).await;
    let target = jump
        .connect_jump("127.0.0.1".into(), 22, false, false, Arc::new(TrustAll))
        .await
        .expect("jump to target");
    let outcome = target
        .authenticate_password("tester".into(), "testpass".into())
        .await
        .expect("target auth call");
    assert_eq!(outcome, AuthOutcome::Success);

    // Drop the intermediate connection; only `target` (which holds the jump
    // host's handle in its `parents`) keeps the chain up now.
    drop(jump);

    let col = Collector::new();
    let session = target
        .open_shell("xterm".into(), 80, 24, Arc::new(col.clone()))
        .await
        .expect("open shell after dropping the intermediate connection");
    session
        .write(b"echo still-alive\n".to_vec())
        .await
        .expect("write");
    let saw = wait_until(|| col.text().contains("still-alive")).await;
    assert!(
        saw,
        "target shell must work after the intermediate connection is dropped, got: {:?}",
        col.text()
    );
    let _ = session.close().await;
}

// The target hop verifies its own host key. A rejecting verifier on the target
// must surface the specific HostKeyRejected variant, not a generic transport
// error — proving per-hop trust is enforced independently of the jump host.
#[tokio::test]
async fn target_host_key_rejection_is_typed() {
    let Some(jump) = sshd_addr() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD");
        return;
    };

    let jump = connect_jump_host(jump).await;
    let err = jump
        .connect_jump("127.0.0.1".into(), 22, false, false, Arc::new(RejectAll))
        .await
        .expect_err("rejecting verifier on target must fail the jump");
    assert!(
        matches!(err, ConnectError::HostKeyRejected),
        "expected HostKeyRejected, got {err:?}"
    );
}

// Each hop authenticates independently: the jump host succeeds, but a wrong
// password at the target is a plain Failure outcome (not an error), and the jump
// transport is unaffected (the target connection is still usable for a retry).
#[tokio::test]
async fn target_auth_failure_is_independent_of_jump() {
    let Some(jump) = sshd_addr() else {
        eprintln!("skipping: set SEMICOLYN_TEST_SSHD");
        return;
    };

    let jump = connect_jump_host(jump).await;
    let target = jump
        .connect_jump("127.0.0.1".into(), 22, false, false, Arc::new(TrustAll))
        .await
        .expect("jump to target");
    let outcome = target
        .authenticate_password("tester".into(), "wrong-password".into())
        .await
        .expect("target auth call should return an outcome, not error");
    assert_eq!(
        outcome,
        AuthOutcome::Failure,
        "wrong password at target must be a Failure outcome"
    );
}
