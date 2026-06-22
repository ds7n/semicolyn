// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
use glymr_ssh_core::connection::{
    connect_core, AuthOutcome, Connection, HostKeyInfo, HostKeyVerifier,
};
use std::sync::Arc;
use std::time::Duration;
#[allow(unused_imports)]
use tokio::io::{AsyncReadExt, AsyncWriteExt};

struct TrustAll;
#[async_trait::async_trait]
impl HostKeyVerifier for TrustAll {
    async fn verify(&self, _info: HostKeyInfo) -> bool {
        true
    }
}

fn sshd_addr() -> Option<String> {
    std::env::var("GLYMR_TEST_SSHD").ok()
}
fn sshd_host() -> Option<String> {
    sshd_addr().map(|a| a.split(':').next().unwrap_or("sshd").to_string())
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

// Tunnel local:0 -> (server) -> 127.0.0.1:22 (sshd's own port); reading the
// tunnel must yield sshd's SSH banner, proving end-to-end bidirectional flow.
#[tokio::test]
async fn local_forward_tunnels_to_remote_service() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set GLYMR_TEST_SSHD");
        return;
    };
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
    assert!(
        n >= 4 && &buf[..4] == b"SSH-",
        "expected SSH banner through tunnel, got {:?}",
        &buf[..n]
    );
    fwd.close().await;
}

#[tokio::test]
async fn local_forward_reports_bound_port() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set GLYMR_TEST_SSHD");
        return;
    };
    let conn = connect_and_auth(addr).await;
    let fwd = conn
        .open_local_forward("127.0.0.1".into(), 0, "127.0.0.1".into(), 22)
        .await
        .expect("open local forward");
    assert_ne!(
        fwd.bound_port(),
        0,
        "ephemeral bind must report a real port"
    );
    fwd.close().await;
}

#[tokio::test]
async fn local_forward_close_frees_the_port() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set GLYMR_TEST_SSHD");
        return;
    };
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
    )
    .await
    .expect("connect attempt timed out");
    assert!(res.is_err(), "port {port} should be refused after close");
}

// Perform a SOCKS5 no-auth CONNECT handshake over `sock` to `host:port`.
// Returns the server's reply byte (0x00 = success) after the greeting.
async fn socks5_connect(sock: &mut tokio::net::TcpStream, host: &str, port: u16) -> u8 {
    // greeting: VER=5, 1 method, method=0 (no auth)
    sock.write_all(&[0x05, 0x01, 0x00]).await.expect("greeting");
    let mut g = [0u8; 2];
    sock.read_exact(&mut g).await.expect("greeting reply");
    assert_eq!(g, [0x05, 0x00], "server must select no-auth");
    // request: VER=5, CMD=CONNECT(1), RSV=0, ATYP=domain(3), len, host, port
    let mut req = vec![0x05, 0x01, 0x00, 0x03, host.len() as u8];
    req.extend_from_slice(host.as_bytes());
    req.extend_from_slice(&port.to_be_bytes());
    sock.write_all(&req).await.expect("request");
    // reply: VER, REP, RSV, ATYP, BND.ADDR(4 for v4), BND.PORT(2)
    let mut rep = [0u8; 10];
    sock.read_exact(&mut rep).await.expect("reply");
    assert_eq!(rep[0], 0x05);
    rep[1]
}

#[tokio::test]
async fn dynamic_forward_socks5_connect_reaches_target() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set GLYMR_TEST_SSHD");
        return;
    };
    let conn = connect_and_auth(addr).await;
    let fwd = conn
        .open_dynamic_forward("127.0.0.1".into(), 0)
        .await
        .expect("open dynamic forward");
    let mut sock = tokio::net::TcpStream::connect(("127.0.0.1", fwd.bound_port()))
        .await
        .expect("connect proxy");
    let rep = socks5_connect(&mut sock, "127.0.0.1", 22).await;
    assert_eq!(rep, 0x00, "SOCKS5 CONNECT to 127.0.0.1:22 must succeed");
    let mut buf = [0u8; 8];
    let n = tokio::time::timeout(Duration::from_secs(5), sock.read(&mut buf))
        .await
        .expect("timeout")
        .expect("read");
    assert!(
        n >= 4 && &buf[..4] == b"SSH-",
        "expected SSH banner through SOCKS tunnel, got {:?}",
        &buf[..n]
    );
    fwd.close().await;
}

#[tokio::test]
async fn dynamic_forward_rejects_non_socks5_greeting() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set GLYMR_TEST_SSHD");
        return;
    };
    let conn = connect_and_auth(addr).await;
    let fwd = conn
        .open_dynamic_forward("127.0.0.1".into(), 0)
        .await
        .expect("open dynamic forward");
    let mut sock = tokio::net::TcpStream::connect(("127.0.0.1", fwd.bound_port()))
        .await
        .expect("connect proxy");
    // SOCKS4 greeting (VER=4) — unsupported; server must close without a v5 reply.
    sock.write_all(&[0x04, 0x01, 0x00, 0x16])
        .await
        .expect("write");
    let mut buf = [0u8; 2];
    let r = tokio::time::timeout(Duration::from_secs(2), sock.read(&mut buf))
        .await
        .expect("timeout");
    // Either EOF (0 bytes) or a non-0x05 first byte — never a SOCKS5 success.
    match r {
        Ok(0) => {} // connection closed: acceptable
        Ok(_) => assert_ne!(buf[0], 0x05, "must not speak SOCKS5 to a v4 client"),
        Err(e) => panic!("unexpected read error: {e}"),
    }
    fwd.close().await;
}

#[tokio::test]
async fn dynamic_forward_rejects_unsupported_command() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set GLYMR_TEST_SSHD");
        return;
    };
    let conn = connect_and_auth(addr).await;
    let fwd = conn
        .open_dynamic_forward("127.0.0.1".into(), 0)
        .await
        .expect("open dynamic forward");
    let mut sock = tokio::net::TcpStream::connect(("127.0.0.1", fwd.bound_port()))
        .await
        .expect("connect proxy");
    sock.write_all(&[0x05, 0x01, 0x00]).await.expect("greeting");
    let mut g = [0u8; 2];
    sock.read_exact(&mut g).await.expect("greeting reply");
    assert_eq!(g, [0x05, 0x00]);
    // CMD=BIND(2) is unsupported → reply code 0x07 (command not supported).
    let mut req = vec![0x05, 0x02, 0x00, 0x03, 0x09];
    req.extend_from_slice(b"127.0.0.1");
    req.extend_from_slice(&22u16.to_be_bytes());
    sock.write_all(&req).await.expect("request");
    let mut rep = [0u8; 10];
    sock.read_exact(&mut rep).await.expect("reply");
    assert_eq!(
        rep[1], 0x07,
        "BIND must be rejected with 0x07 command-not-supported"
    );
    fwd.close().await;
}

// Remote forward: ask the server to listen on a fixed port and route inbound
// connections back to a device-local target serving a known banner. Connect to
// the server's port (reachable as <sshd-host>:PORT thanks to GatewayPorts yes)
// and expect the banner.
#[tokio::test]
async fn remote_forward_routes_inbound_to_local_target() {
    let Some(addr) = sshd_addr() else {
        eprintln!("skipping: set GLYMR_TEST_SSHD");
        return;
    };
    let Some(host) = sshd_host() else { return };
    const REMOTE_PORT: u16 = 13389;
    const BANNER: &[u8] = b"HELLO-GLYMR\n";

    // Device-local target: accept one connection and write the banner.
    let target = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind target");
    let target_port = target.local_addr().unwrap().port();
    tokio::spawn(async move {
        if let Ok((mut s, _)) = target.accept().await {
            let _ = s.write_all(BANNER).await;
            let _ = s.flush().await;
        }
    });

    let conn = connect_and_auth(addr).await;
    let fwd = conn
        .open_remote_forward(
            "0.0.0.0".into(),
            REMOTE_PORT,
            "127.0.0.1".into(),
            target_port,
        )
        .await
        .expect("open remote forward");
    assert_eq!(fwd.bound_port(), REMOTE_PORT);

    // Connect to the server's forwarded port from the dev container.
    let mut sock = tokio::time::timeout(
        Duration::from_secs(5),
        tokio::net::TcpStream::connect((host.as_str(), REMOTE_PORT)),
    )
    .await
    .expect("connect timeout")
    .expect("connect to server forward port");
    let mut buf = vec![0u8; BANNER.len()];
    tokio::time::timeout(Duration::from_secs(5), sock.read_exact(&mut buf))
        .await
        .expect("read timeout")
        .expect("read banner");
    assert_eq!(
        &buf, BANNER,
        "remote forward must deliver the local target's banner"
    );

    fwd.close().await.expect("close remote forward");
}
