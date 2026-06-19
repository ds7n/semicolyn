// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

//! SSH port forwarding: local (direct-tcpip), dynamic (SOCKS5), and remote
//! (forwarded-tcpip). The russh `Handle` is not `Clone`, so listener tasks
//! share `Arc<Mutex<Handle>>` and lock it only to open a channel; bytes then
//! flow on the channel's `ChannelStream`, off-lock.

use std::sync::Arc;
use tokio::sync::Mutex;

use crate::connection::ClientHandler;

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
) -> Result<LocalForward, crate::connection::ConnectError> {
    use crate::connection::ConnectError;
    let listener = tokio::net::TcpListener::bind((local_host.as_str(), local_port))
        .await
        .map_err(|e| ConnectError::Transport {
            message: format!("failed to bind local forward {local_host}:{local_port}: {e}"),
        })?;
    let bound_port = listener
        .local_addr()
        .map_err(|e| ConnectError::Transport { message: format!("local_addr: {e}") })?
        .port();
    let task = tokio::spawn(local_accept_loop(listener, handle, remote_host, remote_port));
    Ok(LocalForward { bound_port, abort: task.abort_handle() })
}

async fn local_accept_loop(
    listener: tokio::net::TcpListener,
    handle: Arc<Mutex<Handle>>,
    remote_host: String,
    remote_port: u16,
) {
    let mut tunnels = tokio::task::JoinSet::new();
    loop {
        let Ok((sock, _peer)) = listener.accept().await else { break };
        let handle = Arc::clone(&handle);
        let rhost = remote_host.clone();
        tunnels.spawn(async move {
            let opened = {
                let h = handle.lock().await;
                h.channel_open_direct_tcpip(rhost, remote_port as u32, "127.0.0.1", 0).await
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
