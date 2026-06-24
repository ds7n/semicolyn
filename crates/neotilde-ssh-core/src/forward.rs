// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

//! SSH port forwarding: local (direct-tcpip), dynamic (SOCKS5), and remote
//! (forwarded-tcpip). The russh `Handle` is not `Clone`, so listener tasks
//! share `Arc<Mutex<Handle>>` and lock it only to open a channel; bytes then
//! flow on the channel's `ChannelStream`, off-lock.

use std::sync::Arc;
use tokio::sync::Mutex;

use crate::connection::{ClientHandler, ConnectError, ForwardMap};

type Handle = russh::client::Handle<ClientHandler>;

/// Copy bytes both directions between a local socket and an SSH channel until
/// either side closes. Errors are swallowed — a broken tunnel ends that one
/// connection, not the forward.
async fn pump(mut sock: tokio::net::TcpStream, channel: russh::Channel<russh::client::Msg>) {
    let mut stream = channel.into_stream();
    let _ = tokio::io::copy_bidirectional(&mut sock, &mut stream).await;
}

/// A live local (direct-tcpip) forward. Dropping or `close()`ing it aborts the
/// accept loop; its `JoinSet` of per-connection pumps is then dropped, aborting
/// all in-flight tunnels and freeing the bound port.
#[derive(uniffi::Object)]
pub struct LocalForward {
    bound_port: u16,
    abort: tokio::task::AbortHandle,
}

#[uniffi::export(async_runtime = "tokio")]
impl LocalForward {
    /// The actual local port the forward is listening on (useful when opened
    /// with port 0).
    pub fn bound_port(&self) -> u16 {
        self.bound_port
    }

    /// Stop the forward: abort the accept loop and tear down all tunnels.
    pub async fn close(&self) {
        self.abort.abort();
    }
}

impl Drop for LocalForward {
    fn drop(&mut self) {
        self.abort.abort();
    }
}

pub(crate) async fn open_local(
    handle: Arc<Mutex<Handle>>,
    local_host: String,
    local_port: u16,
    remote_host: String,
    remote_port: u16,
) -> Result<LocalForward, ConnectError> {
    let listener = tokio::net::TcpListener::bind((local_host.as_str(), local_port))
        .await
        .map_err(|e| ConnectError::Transport {
            message: format!("failed to bind local forward {local_host}:{local_port}: {e}"),
        })?;
    let bound_port = listener
        .local_addr()
        .map_err(|e| ConnectError::Transport {
            message: format!("local_addr: {e}"),
        })?
        .port();
    let task = tokio::spawn(local_accept_loop(
        listener,
        handle,
        remote_host,
        remote_port,
    ));
    Ok(LocalForward {
        bound_port,
        abort: task.abort_handle(),
    })
}

/// A live dynamic (SOCKS5) forward — a device-local SOCKS5 proxy that opens a
/// direct-tcpip channel per CONNECT. Lifecycle identical to `LocalForward`.
#[derive(uniffi::Object)]
pub struct DynamicForward {
    bound_port: u16,
    abort: tokio::task::AbortHandle,
}

#[uniffi::export(async_runtime = "tokio")]
impl DynamicForward {
    pub fn bound_port(&self) -> u16 {
        self.bound_port
    }
    pub async fn close(&self) {
        self.abort.abort();
    }
}

impl Drop for DynamicForward {
    fn drop(&mut self) {
        self.abort.abort();
    }
}

pub(crate) async fn open_dynamic(
    handle: Arc<Mutex<Handle>>,
    local_host: String,
    local_port: u16,
) -> Result<DynamicForward, ConnectError> {
    let listener = tokio::net::TcpListener::bind((local_host.as_str(), local_port))
        .await
        .map_err(|e| ConnectError::Transport {
            message: format!("failed to bind dynamic forward {local_host}:{local_port}: {e}"),
        })?;
    let bound_port = listener
        .local_addr()
        .map_err(|e| ConnectError::Transport {
            message: format!("local_addr: {e}"),
        })?
        .port();
    let task = tokio::spawn(dynamic_accept_loop(listener, handle));
    Ok(DynamicForward {
        bound_port,
        abort: task.abort_handle(),
    })
}

async fn dynamic_accept_loop(listener: tokio::net::TcpListener, handle: Arc<Mutex<Handle>>) {
    let mut tunnels = tokio::task::JoinSet::new();
    loop {
        let Ok((sock, _peer)) = listener.accept().await else {
            break;
        };
        let handle = Arc::clone(&handle);
        tunnels.spawn(async move {
            let _ = socks5_serve(sock, handle).await;
        });
        while tunnels.try_join_next().is_some() {}
    }
}

/// Write an optional SOCKS reply, drain any unread client bytes (non-blocking),
/// then send FIN so the client sees a clean EOF rather than ECONNRESET.
/// Unread data in the kernel socket buffer causes the OS to send RST on close;
/// draining first ensures a graceful FIN regardless of how much was left unread.
async fn reject(mut sock: tokio::net::TcpStream, reply: Option<&[u8]>) -> std::io::Result<()> {
    use tokio::io::AsyncWriteExt;
    if let Some(r) = reply {
        let _ = sock.write_all(r).await;
    }
    let mut scratch = [0u8; 256];
    loop {
        match sock.try_read(&mut scratch) {
            Ok(0) => break,
            Ok(_) => continue,
            Err(_) => break, // WouldBlock or other: nothing more readable now
        }
    }
    let _ = sock.shutdown().await;
    Ok(())
}

/// Minimal SOCKS5 server: no-auth, CONNECT only. Replies with the correct SOCKS5
/// error code for unsupported versions/methods/commands/address types, then
/// closes gracefully via `reject`. On CONNECT, opens a direct-tcpip channel and pumps.
async fn socks5_serve(
    mut sock: tokio::net::TcpStream,
    handle: Arc<Mutex<Handle>>,
) -> std::io::Result<()> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    // Generic failure reply (VER, REP, RSV, ATYP=v4, 0.0.0.0:0).
    let fail = |code: u8| [0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0];

    // Greeting: VER, NMETHODS, METHODS...
    let mut head = [0u8; 2];
    sock.read_exact(&mut head).await?;
    if head[0] != 0x05 {
        return reject(sock, None).await;
    }
    let mut methods = vec![0u8; head[1] as usize];
    sock.read_exact(&mut methods).await?;
    if !methods.contains(&0x00) {
        return reject(sock, Some(&[0x05, 0xFF])).await; // no acceptable methods
    }
    sock.write_all(&[0x05, 0x00]).await?; // select no-auth

    // Request: VER, CMD, RSV, ATYP, ADDR, PORT
    let mut req = [0u8; 4];
    sock.read_exact(&mut req).await?;
    if req[0] != 0x05 {
        return reject(sock, None).await;
    }
    if req[1] != 0x01 {
        let r = fail(0x07); // command not supported
        return reject(sock, Some(&r)).await;
    }
    let host = match req[3] {
        0x01 => {
            let mut a = [0u8; 4];
            sock.read_exact(&mut a).await?;
            std::net::Ipv4Addr::from(a).to_string()
        }
        0x04 => {
            let mut a = [0u8; 16];
            sock.read_exact(&mut a).await?;
            std::net::Ipv6Addr::from(a).to_string()
        }
        0x03 => {
            let mut len = [0u8; 1];
            sock.read_exact(&mut len).await?;
            let mut d = vec![0u8; len[0] as usize];
            sock.read_exact(&mut d).await?;
            String::from_utf8_lossy(&d).into_owned()
        }
        _ => {
            let r = fail(0x08); // address type not supported
            return reject(sock, Some(&r)).await;
        }
    };
    let mut port = [0u8; 2];
    sock.read_exact(&mut port).await?;
    let port = u16::from_be_bytes(port);

    let opened = {
        let h = handle.lock().await;
        h.channel_open_direct_tcpip(host, port as u32, "127.0.0.1", 0)
            .await
    };
    match opened {
        Ok(channel) => {
            // success, BND.ADDR=0.0.0.0:0 (clients ignore it for CONNECT)
            sock.write_all(&[0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
                .await?;
            pump(sock, channel).await;
        }
        Err(_) => {
            let r = fail(0x01); // general SOCKS server failure
            return reject(sock, Some(&r)).await;
        }
    }
    Ok(())
}

/// A live remote (forwarded-tcpip) forward. The server listens on `bound_port`
/// and routes inbound connections back to a device-local target; `close()`
/// cancels the server-side listener and unregisters the route.
#[derive(uniffi::Object)]
pub struct RemoteForward {
    bound_port: u16,
    bind_host: String,
    handle: Arc<Mutex<Handle>>,
    forwards: ForwardMap,
}

#[uniffi::export(async_runtime = "tokio")]
impl RemoteForward {
    pub fn bound_port(&self) -> u16 {
        self.bound_port
    }

    /// Cancel the server-side listener and stop routing.
    pub async fn close(&self) -> Result<(), ConnectError> {
        {
            let h = self.handle.lock().await;
            h.cancel_tcpip_forward(self.bind_host.clone(), self.bound_port as u32)
                .await?;
        }
        self.forwards
            .lock()
            .unwrap()
            .remove(&(self.bound_port as u32));
        Ok(())
    }
}

impl Drop for RemoteForward {
    fn drop(&mut self) {
        self.forwards
            .lock()
            .unwrap()
            .remove(&(self.bound_port as u32));
        if let Ok(rt) = tokio::runtime::Handle::try_current() {
            let handle = Arc::clone(&self.handle);
            let bind_host = self.bind_host.clone();
            let port = self.bound_port as u32;
            rt.spawn(async move {
                let h = handle.lock().await;
                let _ = h.cancel_tcpip_forward(bind_host, port).await;
            });
        }
    }
}

pub(crate) async fn open_remote(
    handle: Arc<Mutex<Handle>>,
    forwards: ForwardMap,
    remote_bind_host: String,
    remote_bind_port: u16,
    local_host: String,
    local_port: u16,
) -> Result<RemoteForward, ConnectError> {
    let assigned = {
        let h = handle.lock().await;
        h.tcpip_forward(remote_bind_host.clone(), remote_bind_port as u32)
            .await?
    };
    // For a fixed (non-zero) request the server listens on exactly that port and
    // the reply carries no port; for port 0 the server returns the chosen port.
    let bound_port: u16 = if remote_bind_port == 0 {
        assigned as u16
    } else {
        remote_bind_port
    };
    forwards
        .lock()
        .unwrap()
        .insert(bound_port as u32, (local_host, local_port));
    Ok(RemoteForward {
        bound_port,
        bind_host: remote_bind_host,
        handle,
        forwards,
    })
}

async fn local_accept_loop(
    listener: tokio::net::TcpListener,
    handle: Arc<Mutex<Handle>>,
    remote_host: String,
    remote_port: u16,
) {
    let mut tunnels = tokio::task::JoinSet::new();
    loop {
        let Ok((sock, _peer)) = listener.accept().await else {
            break;
        };
        let handle = Arc::clone(&handle);
        let rhost = remote_host.clone();
        tunnels.spawn(async move {
            let opened = {
                let h = handle.lock().await;
                h.channel_open_direct_tcpip(rhost, remote_port as u32, "127.0.0.1", 0)
                    .await
            };
            if let Ok(channel) = opened {
                pump(sock, channel).await;
            }
        });
        // Reap finished tunnels so the set doesn't grow unbounded.
        while tunnels.try_join_next().is_some() {}
    }
    // Returning (or being aborted) drops `tunnels`, aborting all live pumps.
}
