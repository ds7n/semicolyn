// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

//! SSH connection: TCP + transport handshake using the Phase-1a allowlist,
//! host-key trust via an injected delegate, and Tier-3 negotiated-algorithm
//! detection. See docs/superpowers/specs/2026-06-17-host-key-trust-design.md
//! and 2026-06-17-ssh-algorithms-design.md.

/// What the host-key trust delegate is shown when deciding whether to trust a
/// server's offered host key. Mirrors the first-trust modal's content.
#[derive(uniffi::Record, Clone, Debug)]
pub struct HostKeyInfo {
    /// The host's human label (for the modal title).
    pub host_label: String,
    /// The offered host-key algorithm, e.g. "ssh-ed25519".
    pub key_type: String,
    /// SHA256 fingerprint, formatted "SHA256:<base64>".
    pub fingerprint: String,
}

/// The host-key trust delegate. Swift implements this (shows the first-trust /
/// mismatch modal, consults the iCloud-Keychain known_hosts); Linux tests use a
/// Rust double. Returns true to trust the offered key and proceed.
#[uniffi::export(with_foreign)]
#[async_trait::async_trait]
pub trait HostKeyVerifier: Send + Sync {
    async fn verify(&self, info: HostKeyInfo) -> bool;
}

/// Errors surfaced from a connection attempt.
#[derive(uniffi::Error, thiserror::Error, Debug)]
pub enum ConnectError {
    #[error("host key rejected by the trust delegate")]
    HostKeyRejected,
    #[error("transport error: {message}")]
    Transport { message: String },
    /// The supplied certificate is unusable on the client side: malformed,
    /// not matching the private key, or outside its validity window. Never a
    /// silent fallback to bare-key auth.
    #[error("certificate invalid: {message}")]
    CertificateInvalid { message: String },
    /// The initial SSH handshake did not complete within the connect deadline —
    /// e.g. a host that accepts the TCP connection but never sends its banner.
    /// Distinct from `Transport` so the caller can report "couldn't reach host"
    /// rather than a raw protocol error, and distinct from the post-handshake
    /// keepalive/inactivity teardown (which surfaces as a normal session close).
    #[error("connection timed out")]
    Timeout,
}

impl From<russh::Error> for ConnectError {
    fn from(e: russh::Error) -> Self {
        ConnectError::Transport {
            message: e.to_string(),
        }
    }
}

/// The result of an authentication attempt. A failed auth is a normal outcome,
/// not a `ConnectError` — the caller decides what to do (retry, try another
/// method, surface the connect-failed banner).
#[derive(uniffi::Enum, Debug, PartialEq, Eq)]
pub enum AuthOutcome {
    /// Authentication fully succeeded; the session is usable.
    Success,
    /// The method was accepted but the server requires another method too
    /// (multi-factor). Caller should authenticate again with a further method.
    PartialSuccess,
    /// Authentication failed.
    Failure,
}

fn outcome(result: russh::client::AuthResult) -> AuthOutcome {
    match result {
        russh::client::AuthResult::Success => AuthOutcome::Success,
        russh::client::AuthResult::Failure {
            partial_success: true,
            ..
        } => AuthOutcome::PartialSuccess,
        russh::client::AuthResult::Failure { .. } => AuthOutcome::Failure,
    }
}

/// Sink for shell output and lifecycle. Swift implements it (forwarding into an
/// AsyncStream); Linux tests use a Rust double. Methods are synchronous and MUST
/// be fast/non-blocking — they run on the pump task.
#[uniffi::export(with_foreign)]
pub trait ShellOutput: Send + Sync {
    /// A chunk of merged stdout+stderr from the PTY. May be called many times.
    fn on_output(&self, data: Vec<u8>);
    /// The session ended. Fired exactly once; no callbacks follow.
    fn on_closed(&self, exit: ShellExit);
}

/// How a shell session ended. On a clean teardown at most one of
/// `exit_status` / `signal` is set; `error` is set instead on transport failure.
#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq, Default)]
pub struct ShellExit {
    /// Clean exit code, from the server's `exit-status`.
    pub exit_status: Option<u32>,
    /// Signal name, when the remote process was killed by a signal.
    pub signal: Option<String>,
    /// Transport/protocol error message, when the channel failed.
    pub error: Option<String>,
}

/// Commands the `ShellSession` sends to its owning pump task.
enum ShellCommand {
    Write(Vec<u8>),
    Resize(u32, u32),
    Close,
}

/// A live PTY shell channel. Drives one background pump task that owns the russh
/// channel; this handle only sends it commands.
#[derive(uniffi::Object)]
pub struct ShellSession {
    cmd_tx: tokio::sync::mpsc::Sender<ShellCommand>,
}

use russh::client;
use russh::keys::ssh_key::HashAlg;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use crate::algorithms::build_preferred;

/// Server-listen-port → device-local target (host, port) for active remote
/// (forwarded-tcpip) forwards. Shared between `Connection` and `ClientHandler`.
pub(crate) type ForwardMap =
    std::sync::Arc<std::sync::Mutex<std::collections::HashMap<u32, (String, u16)>>>;

/// russh client event handler. Trust decisions go to the injected delegate;
/// `kex_done` records negotiated algorithm names for Tier-3 detection (Task 3).
pub(crate) struct ClientHandler {
    host_label: String,
    verifier: Arc<dyn HostKeyVerifier>,
    /// Set when the delegate rejects the key, so `connect_core` can distinguish
    /// "delegate said no" from a generic transport failure.
    rejected: Arc<AtomicBool>,
    tier3_in_use: Arc<Mutex<Vec<String>>>,
    forwards: ForwardMap,
}

impl client::Handler for ClientHandler {
    type Error = ConnectError;

    async fn check_server_key(
        &mut self,
        server_public_key: &russh::keys::ssh_key::PublicKey,
    ) -> Result<bool, Self::Error> {
        let info = HostKeyInfo {
            host_label: self.host_label.clone(),
            key_type: server_public_key.algorithm().as_str().to_string(),
            fingerprint: server_public_key.fingerprint(HashAlg::Sha256).to_string(),
        };
        let trusted = self.verifier.verify(info).await;
        if !trusted {
            self.rejected.store(true, Ordering::SeqCst);
        }
        Ok(trusted)
    }

    async fn server_channel_open_forwarded_tcpip(
        &mut self,
        channel: russh::Channel<russh::client::Msg>,
        _connected_address: &str,
        connected_port: u32,
        _originator_address: &str,
        _originator_port: u32,
        _session: &mut russh::client::Session,
    ) -> Result<(), Self::Error> {
        // Route an inbound (server-initiated) forwarded connection to the
        // device-local target registered for this server listen port.
        let target = self.forwards.lock().unwrap().get(&connected_port).cloned();
        if let Some((host, port)) = target {
            tokio::spawn(async move {
                if let Ok(sock) = tokio::net::TcpStream::connect((host.as_str(), port)).await {
                    let mut sock = sock;
                    let mut stream = channel.into_stream();
                    let _ = tokio::io::copy_bidirectional(&mut sock, &mut stream).await;
                }
            });
        }
        // No registered target → channel is dropped (closed).
        Ok(())
    }

    async fn kex_done(
        &mut self,
        _shared_secret: Option<&[u8]>,
        names: &russh::Names,
        _session: &mut russh::client::Session,
    ) -> Result<(), Self::Error> {
        // Collect every negotiated algorithm's wire name and keep the Tier-3
        // ones for the outdated-cryptography warning.
        let negotiated = [
            names.kex.as_ref(),
            names.key.as_str(),
            names.cipher.as_ref(),
            names.client_mac.as_ref(),
            names.server_mac.as_ref(),
        ];
        let mut flagged = self.tier3_in_use.lock().unwrap();
        for name in negotiated {
            if crate::algorithms::is_tier3(name) && !flagged.iter().any(|n| n == name) {
                flagged.push(name.to_string());
            }
        }
        Ok(())
    }
}

/// A live SSH transport connection. Phase 1c+ adds auth and channels; Phase 1b
/// exposes only the Tier-3 warning list.
#[derive(uniffi::Object)]
pub struct Connection {
    handle: std::sync::Arc<tokio::sync::Mutex<client::Handle<ClientHandler>>>,
    tier3_in_use: Arc<Mutex<Vec<String>>>,
    forwards: ForwardMap,
    /// Handles of every hop closer to the device, for a connection reached
    /// through one or more jump hosts (`proxyJump`). Their transports carry
    /// ours, so they must stay alive as long as this connection does. Dropping
    /// this connection releases its references; once nothing in the chain
    /// references a hop, that hop's transport closes. Empty for a direct
    /// connection.
    parents: Vec<std::sync::Arc<tokio::sync::Mutex<client::Handle<ClientHandler>>>>,
}

impl std::fmt::Debug for Connection {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Connection")
            .field("tier3_in_use", &*self.tier3_in_use.lock().unwrap())
            .finish_non_exhaustive()
    }
}

#[uniffi::export]
impl Connection {
    /// Wire names of any Tier-3 algorithms negotiated for this session (empty
    /// when the session is fully modern). Drives the outdated-cryptography
    /// warning per ssh-algorithms-design §"Tier 3 warning UX".
    pub fn tier3_in_use(&self) -> Vec<String> {
        self.tier3_in_use.lock().unwrap().clone()
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl Connection {
    /// Password authentication. Returns the typed outcome; a wrong password is
    /// `Failure`, not an error.
    pub async fn authenticate_password(
        &self,
        user: String,
        password: String,
    ) -> Result<AuthOutcome, ConnectError> {
        let mut handle = self.handle.lock().await;
        Ok(outcome(handle.authenticate_password(user, password).await?))
    }

    /// Public-key authentication from an in-memory OpenSSH private key. (The
    /// Secure-Enclave / Keychain-backed signing path is Phase 2 + macOS.)
    pub async fn authenticate_publickey(
        &self,
        user: String,
        private_key_openssh: String,
    ) -> Result<AuthOutcome, ConnectError> {
        let key =
            russh::keys::PrivateKey::from_openssh(private_key_openssh.as_bytes()).map_err(|e| {
                ConnectError::Transport {
                    message: format!("invalid private key: {e}"),
                }
            })?;
        let mut handle = self.handle.lock().await;
        // For RSA keys, advertise the strongest server-supported SHA-2 hash;
        // ignored for ed25519/ecdsa.
        let hash = handle.best_supported_rsa_hash().await?.flatten();
        let key = russh::keys::PrivateKeyWithHashAlg::new(std::sync::Arc::new(key), hash);
        Ok(outcome(handle.authenticate_publickey(user, key).await?))
    }

    /// OpenSSH certificate authentication: present `<cert> + <private key>`.
    /// Performs the three client-side checks from the cert-auth design (parse,
    /// key↔cert pair match, validity window) then lets the server decide CA
    /// trust. An unusable cert is `CertificateInvalid` — never a fallback to
    /// the bare key.
    pub async fn authenticate_openssh_cert(
        &self,
        user: String,
        private_key_openssh: String,
        cert_openssh: String,
    ) -> Result<AuthOutcome, ConnectError> {
        let key =
            russh::keys::PrivateKey::from_openssh(private_key_openssh.as_bytes()).map_err(|e| {
                ConnectError::Transport {
                    message: format!("invalid private key: {e}"),
                }
            })?;
        let cert = cert_openssh
            .parse::<russh::keys::ssh_key::Certificate>()
            .map_err(|e| ConnectError::CertificateInvalid {
                message: format!("malformed certificate: {e}"),
            })?;
        // Pair sanity: the cert must certify this private key.
        if key.public_key().key_data() != cert.public_key() {
            return Err(ConnectError::CertificateInvalid {
                message: "certificate does not match the private key".into(),
            });
        }
        // Validity window: validAfter <= now <= validBefore (unix seconds).
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        if now < cert.valid_after() {
            return Err(ConnectError::CertificateInvalid {
                message: "certificate is not yet valid".into(),
            });
        }
        if now > cert.valid_before() {
            return Err(ConnectError::CertificateInvalid {
                message: "certificate has expired".into(),
            });
        }
        let mut handle = self.handle.lock().await;
        Ok(outcome(
            handle
                .authenticate_openssh_cert(user, std::sync::Arc::new(key), cert)
                .await?,
        ))
    }

    /// Keyboard-interactive authentication. `responses` answers each server
    /// prompt in order (typically a single password).
    ///
    /// Each `InfoRequest` round is answered with exactly `prompts.len()` replies
    /// so the reply count always matches the prompt count (SSH drops the
    /// connection on a mismatch). Two cases keep that invariant:
    /// - **Zero-prompt round** (e.g. PAM's final confirmation banner): answered
    ///   with an empty batch — never a stray password.
    /// - **Prompts remain but `responses` is exhausted** (the server is
    ///   re-prompting after a wrong password): we have no answer to give, so we
    ///   return a typed `AuthOutcome::Failure` rather than send blank replies
    ///   (which would just burn the server's retry counter) or a short batch
    ///   (which would trip the count mismatch → a transport drop instead of the
    ///   `Failure` the API contract promises).
    ///
    /// The loop is bounded to avoid a misbehaving server spinning forever.
    pub async fn authenticate_keyboard_interactive(
        &self,
        user: String,
        responses: Vec<String>,
    ) -> Result<AuthOutcome, ConnectError> {
        use russh::client::KeyboardInteractiveAuthResponse as Kir;
        let mut handle = self.handle.lock().await;
        let mut reply = handle
            .authenticate_keyboard_interactive_start(user, None)
            .await?;
        let mut sent = 0usize;
        for _ in 0..10 {
            match reply {
                Kir::Success => return Ok(AuthOutcome::Success),
                Kir::Failure {
                    partial_success, ..
                } => {
                    return Ok(if partial_success {
                        AuthOutcome::PartialSuccess
                    } else {
                        AuthOutcome::Failure
                    });
                }
                Kir::InfoRequest { prompts, .. } => {
                    // Out of answers for a real (non-empty) prompt round → auth
                    // has failed; stop cleanly with a typed Failure. A zero-prompt
                    // round is NOT exhaustion — answer it with an empty batch.
                    if !prompts.is_empty() && sent >= responses.len() {
                        return Ok(AuthOutcome::Failure);
                    }
                    let batch: Vec<String> = responses
                        .iter()
                        .skip(sent)
                        .take(prompts.len())
                        .cloned()
                        .collect();
                    sent += prompts.len();
                    reply = handle
                        .authenticate_keyboard_interactive_respond(batch)
                        .await?;
                }
            }
        }
        Ok(AuthOutcome::Failure)
    }

    /// Open a local (direct-tcpip) port forward: bind `local_host:local_port`
    /// on the device and tunnel each accepted connection to
    /// `remote_host:remote_port` through the SSH session. Pass `local_port` 0
    /// for an OS-assigned port (read it back via `bound_port()`).
    pub async fn open_local_forward(
        &self,
        local_host: String,
        local_port: u16,
        remote_host: String,
        remote_port: u16,
    ) -> Result<std::sync::Arc<crate::forward::LocalForward>, ConnectError> {
        crate::forward::open_local(
            std::sync::Arc::clone(&self.handle),
            local_host,
            local_port,
            remote_host,
            remote_port,
        )
        .await
        .map(std::sync::Arc::new)
    }

    /// Open a remote (forwarded-tcpip) port forward: ask the server to listen on
    /// `remote_bind_host:remote_bind_port` and route each inbound connection
    /// back to the device-local `local_host:local_port` through the SSH session.
    /// Pass `remote_bind_port` 0 for a server-assigned port (read via
    /// `bound_port()`).
    pub async fn open_remote_forward(
        &self,
        remote_bind_host: String,
        remote_bind_port: u16,
        local_host: String,
        local_port: u16,
    ) -> Result<std::sync::Arc<crate::forward::RemoteForward>, ConnectError> {
        crate::forward::open_remote(
            std::sync::Arc::clone(&self.handle),
            self.forwards.clone(),
            remote_bind_host,
            remote_bind_port,
            local_host,
            local_port,
        )
        .await
        .map(std::sync::Arc::new)
    }

    /// Open a dynamic (SOCKS5) forward: run a device-local SOCKS5 proxy on
    /// `local_host:local_port`; each CONNECT opens a direct-tcpip channel to the
    /// requested target. Pass `local_port` 0 for an OS-assigned port.
    pub async fn open_dynamic_forward(
        &self,
        local_host: String,
        local_port: u16,
    ) -> Result<std::sync::Arc<crate::forward::DynamicForward>, ConnectError> {
        crate::forward::open_dynamic(std::sync::Arc::clone(&self.handle), local_host, local_port)
            .await
            .map(std::sync::Arc::new)
    }

    /// Open a PTY-backed login shell. Requests a PTY (`term`/`cols`/`rows`,
    /// pixel dims 0, no extra modes) then a shell, and starts pumping output to
    /// `output`. Returns once the shell starts; output and the close event
    /// arrive asynchronously via the delegate.
    pub async fn open_shell(
        &self,
        term: String,
        cols: u32,
        rows: u32,
        output: Arc<dyn ShellOutput>,
    ) -> Result<Arc<ShellSession>, ConnectError> {
        let channel = {
            let handle = self.handle.lock().await;
            handle.channel_open_session().await?
        };
        channel
            .request_pty(true, &term, cols, rows, 0, 0, &[])
            .await?;
        channel.request_shell(true).await?;
        let (cmd_tx, cmd_rx) = tokio::sync::mpsc::channel(32);
        tokio::spawn(pump(channel, cmd_rx, output));
        Ok(Arc::new(ShellSession { cmd_tx }))
    }

    /// Exec `command` on a PTY-backed session channel and pump its stdio to
    /// `output`. This is the transport for tmux control mode: the caller passes
    /// `TmuxSessionController.start()`'s `tmux -CC new-session -A -s <name>`
    /// string and drives the resulting control-mode stream (and it serves any
    /// other run-a-remote-command need, e.g. the future mosh bootstrap).
    ///
    /// A PTY **is** requested: `tmux -CC` calls `tcgetattr` on startup and exits
    /// without a controlling terminal, then disables echo itself (the second
    /// `C`), so the control-mode protocol rides a PTY cleanly. `cols`/`rows` set
    /// the initial control-client size; `ShellSession::resize` (a `window_change`)
    /// works as for a shell. Returns once the channel is open; output and the
    /// close event arrive asynchronously via the delegate.
    pub async fn open_exec(
        &self,
        command: String,
        term: String,
        cols: u32,
        rows: u32,
        output: Arc<dyn ShellOutput>,
    ) -> Result<Arc<ShellSession>, ConnectError> {
        let channel = {
            let handle = self.handle.lock().await;
            handle.channel_open_session().await?
        };
        channel
            .request_pty(true, &term, cols, rows, 0, 0, &[])
            .await?;
        channel.exec(true, command.into_bytes()).await?;
        let (cmd_tx, cmd_rx) = tokio::sync::mpsc::channel(32);
        tokio::spawn(pump(channel, cmd_rx, output));
        Ok(Arc::new(ShellSession { cmd_tx }))
    }

    /// Open a jump-host hop: tunnel a `direct-tcpip` channel from this connection
    /// to `target_host:target_port` and run a fresh SSH handshake over it,
    /// returning the target as a new `Connection`. The caller authenticates the
    /// returned connection with the usual `authenticate_*` methods, exactly as
    /// for a direct connection — a `proxyJump` chain is built one hop at a time
    /// by calling `connect_jump` then authenticating, repeatedly. `allow_legacy`,
    /// `allow_deprecated`, and `verifier` apply to the *target* hop only; each
    /// hop verifies its own host key independently. The returned connection keeps
    /// this one (and any hops before it) alive for its whole lifetime; dropping
    /// it tears the chain down.
    pub async fn connect_jump(
        &self,
        target_host: String,
        target_port: u16,
        allow_legacy: bool,
        allow_deprecated: bool,
        keepalive: KeepaliveConfig,
        verifier: Arc<dyn HostKeyVerifier>,
    ) -> Result<Arc<Connection>, ConnectError> {
        let host_label = format!("{target_host}:{target_port}");
        let (config, handler, tier3_in_use, rejected, forwards) = prepare(
            host_label,
            allow_legacy,
            allow_deprecated,
            keepalive,
            verifier,
        );

        // Open a direct-tcpip channel to the next hop on the current transport,
        // then run the target's SSH handshake over that channel's byte stream.
        // The handle lock is released at the block's end, before connect_stream.
        let stream = {
            let h = self.handle.lock().await;
            h.channel_open_direct_tcpip(target_host, target_port as u32, "127.0.0.1", 0)
                .await?
        }
        .into_stream();

        // Same handshake bound as the direct path (see `connect_core`).
        let connect_fut = client::connect_stream(config, stream, handler);
        let handle = match tokio::time::timeout(HANDSHAKE_TIMEOUT, connect_fut).await {
            Ok(result) => map_handshake(result, &rejected)?,
            Err(_elapsed) => return Err(ConnectError::Timeout),
        };

        // Keep every hop closer to the device alive: their transports carry ours.
        let mut parents = self.parents.clone();
        parents.push(std::sync::Arc::clone(&self.handle));

        Ok(Arc::new(Connection {
            handle: std::sync::Arc::new(tokio::sync::Mutex::new(handle)),
            tier3_in_use,
            forwards,
            parents,
        }))
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl ShellSession {
    /// Write bytes to the shell's stdin.
    pub async fn write(&self, data: Vec<u8>) -> Result<(), ConnectError> {
        self.cmd_tx
            .send(ShellCommand::Write(data))
            .await
            .map_err(|_| ConnectError::Transport {
                message: "shell session closed".into(),
            })
    }

    /// Tell the remote of a new terminal size (pixel dims 0).
    pub async fn resize(&self, cols: u32, rows: u32) -> Result<(), ConnectError> {
        self.cmd_tx
            .send(ShellCommand::Resize(cols, rows))
            .await
            .map_err(|_| ConnectError::Transport {
                message: "shell session closed".into(),
            })
    }

    /// End the session: EOF + close. After the shell has already exited this
    /// returns the "shell session closed" error.
    pub async fn close(&self) -> Result<(), ConnectError> {
        self.cmd_tx
            .send(ShellCommand::Close)
            .await
            .map_err(|_| ConnectError::Transport {
                message: "shell session closed".into(),
            })
    }
}

/// Sole owner of the russh channel for a shell session. Multiplexes channel
/// reads and `ShellSession` commands; pushes output to `output` and fires
/// `on_closed` exactly once on exit.
async fn pump(
    mut channel: russh::Channel<russh::client::Msg>,
    mut cmd_rx: tokio::sync::mpsc::Receiver<ShellCommand>,
    output: Arc<dyn ShellOutput>,
) {
    use russh::ChannelMsg as M;
    let mut exit = ShellExit::default();
    loop {
        tokio::select! {
            // `wait()` is cancel-safe (it awaits an mpsc recv): if the cmd arm
            // wins this select, dropping this future loses no buffered message —
            // the next `wait()` re-reads it.
            msg = channel.wait() => match msg {
                Some(M::Data { data }) | Some(M::ExtendedData { data, .. }) => {
                    output.on_output(data.to_vec());
                }
                Some(M::ExitStatus { exit_status }) => exit.exit_status = Some(exit_status),
                Some(M::ExitSignal { signal_name, .. }) => {
                    exit.signal = Some(format!("{signal_name:?}"));
                }
                Some(M::Eof) | Some(M::Close) | None => {
                    // Drain any messages already buffered alongside or just
                    // before the terminator (e.g. ExitStatus). Safe to loop
                    // without a timeout: we already observed a terminating
                    // message, so russh will yield any remaining buffered
                    // messages and then another Eof/Close/None, guaranteeing
                    // termination.
                    while let Some(msg) = channel.wait().await {
                        match msg {
                            M::ExitStatus { exit_status } => {
                                exit.exit_status = Some(exit_status);
                            }
                            M::ExitSignal { signal_name, .. } => {
                                exit.signal = Some(format!("{signal_name:?}"));
                            }
                            M::Data { data } | M::ExtendedData { data, .. } => {
                                output.on_output(data.to_vec());
                            }
                            M::Eof | M::Close => break,
                            _ => {}
                        }
                    }
                    break;
                }
                Some(_) => {} // WindowAdjusted / Success / Failure / etc.
            },
            cmd = cmd_rx.recv() => match cmd {
                Some(ShellCommand::Write(bytes)) => {
                    if let Err(e) = channel.data_bytes(bytes).await {
                        exit.error = Some(e.to_string());
                        break;
                    }
                }
                Some(ShellCommand::Resize(cols, rows)) => {
                    if let Err(e) = channel.window_change(cols, rows, 0, 0).await {
                        exit.error = Some(e.to_string());
                        break;
                    }
                }
                // Explicit close, or all senders dropped: tear down and drain.
                Some(ShellCommand::Close) | None => {
                    let _ = channel.eof().await;
                    let _ = channel.close().await;
                    while let Some(msg) = channel.wait().await {
                        match msg {
                            M::Data { data } | M::ExtendedData { data, .. } => {
                                output.on_output(data.to_vec());
                            }
                            M::ExitStatus { exit_status } => exit.exit_status = Some(exit_status),
                            M::ExitSignal { signal_name, .. } => {
                                exit.signal = Some(format!("{signal_name:?}"));
                            }
                            M::Eof | M::Close => break,
                            _ => {}
                        }
                    }
                    break;
                }
            },
        }
    }
    output.on_closed(exit);
}

/// The pieces `prepare` hands back: the client config and event handler, plus
/// the shared state the caller needs to assemble a `Connection` and to tell a
/// host-key rejection apart from a transport error.
type Prepared = (
    Arc<client::Config>,
    ClientHandler,
    Arc<Mutex<Vec<String>>>,
    Arc<AtomicBool>,
    ForwardMap,
);

/// SSH keepalive policy, mirroring OpenSSH's `ServerAliveInterval` /
/// `ServerAliveCountMax`. Crosses the FFI so the app's per-host settings drive
/// the live-session liveness check instead of a hardcoded default.
#[derive(uniffi::Record, Debug, Clone, Copy)]
pub struct KeepaliveConfig {
    /// Seconds of quiet before a keepalive probe is sent. `0` disables
    /// keepalives entirely (OpenSSH `ServerAliveInterval 0`).
    pub interval_secs: u32,
    /// Unanswered probes tolerated before the connection is declared dead.
    pub count_max: u32,
}

impl Default for KeepaliveConfig {
    fn default() -> Self {
        // Matches the app's resolve fallbacks (interval 30, countMax 3) and
        // OpenSSH's own defaults, so a caller that can't resolve a saved host
        // still gets a sane liveness policy.
        KeepaliveConfig {
            interval_secs: 30,
            count_max: 3,
        }
    }
}

/// The bounded wall-clock a connection attempt (TCP + SSH handshake) may take
/// before it is abandoned as unreachable. Separate from the post-handshake
/// session timers so a black-hole host fails fast instead of waiting out the
/// (much longer) session inactivity backstop.
const HANDSHAKE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(20);

/// Session inactivity backstop used when keepalives are disabled (interval 0):
/// there is no keepalive window to derive a bound from, so fall back to a fixed
/// generous "no traffic at all for this long" safety net rather than `None`.
const NO_KEEPALIVE_INACTIVITY: std::time::Duration = std::time::Duration::from_secs(180);

/// Derives the russh session timers from a [`KeepaliveConfig`].
///
/// Returns `(keepalive_interval, keepalive_max, inactivity_timeout)`.
///
/// The load-bearing invariant: when keepalives are enabled, the inactivity
/// timeout MUST sit strictly above the keepalive-failure window so keepalive's
/// own retry logic — not the inactivity timer — declares a dead connection.
/// russh disconnects when `alive_timeouts > keepalive_max`, i.e. on the
/// `(count_max + 1)`-th probe tick, so the keepalive death point is
/// `interval × (count_max + 1)`. We set the inactivity backstop two intervals
/// higher (`interval × (count_max + 3)`), leaving keepalive to make the call in
/// the normal case and reserving the inactivity timer as a true backstop for a
/// stalled keepalive path. (A too-tight inactivity timeout is exactly the
/// pre-fix bug: a hardcoded 20 s fired before any keepalive could, killing
/// every idle session.)
fn derive_timers(
    cfg: KeepaliveConfig,
) -> (Option<std::time::Duration>, usize, std::time::Duration) {
    if cfg.interval_secs == 0 {
        return (None, cfg.count_max as usize, NO_KEEPALIVE_INACTIVITY);
    }
    let interval = std::time::Duration::from_secs(cfg.interval_secs as u64);
    // (count_max + 3) × interval: death point (count_max + 1) plus a 2-interval
    // cushion. u64 math on u32 inputs cannot overflow.
    let inactivity =
        std::time::Duration::from_secs(cfg.interval_secs as u64 * (cfg.count_max as u64 + 3));
    (Some(interval), cfg.count_max as usize, inactivity)
}

/// Builds the russh client config and event handler shared by direct
/// (`connect_core`) and jumped (`connect_jump`) connections.
fn prepare(
    host_label: String,
    allow_legacy: bool,
    allow_deprecated: bool,
    keepalive: KeepaliveConfig,
    verifier: Arc<dyn HostKeyVerifier>,
) -> Prepared {
    let tier3_in_use = Arc::new(Mutex::new(Vec::new()));
    let rejected = Arc::new(AtomicBool::new(false));
    let forwards: ForwardMap =
        std::sync::Arc::new(std::sync::Mutex::new(std::collections::HashMap::new()));

    // ext-info-c is a protocol marker, not a user-facing algorithm — appended
    // here, not in the 1a allowlist.
    let mut preferred = build_preferred(allow_legacy, allow_deprecated);
    let mut kex = preferred.kex.into_owned();
    kex.push(russh::kex::EXTENSION_SUPPORT_AS_CLIENT);
    preferred.kex = std::borrow::Cow::Owned(kex);

    let (keepalive_interval, keepalive_max, inactivity_timeout) = derive_timers(keepalive);
    let config = Arc::new(client::Config {
        preferred,
        keepalive_interval,
        keepalive_max,
        // Backstop only — keepalive (above) is the primary liveness mechanism.
        // Kept strictly above the keepalive-failure window by `derive_timers`.
        inactivity_timeout: Some(inactivity_timeout),
        ..Default::default()
    });

    let handler = ClientHandler {
        host_label,
        verifier,
        rejected: rejected.clone(),
        tier3_in_use: tier3_in_use.clone(),
        forwards: forwards.clone(),
    };

    (config, handler, tier3_in_use, rejected, forwards)
}

/// Maps a russh connect result to our error model: when the handshake failed
/// because the trust delegate rejected the host key (recorded in `rejected`),
/// report the specific `HostKeyRejected`; any other failure is the underlying
/// transport error. Shared by the direct and jumped connect paths so the
/// rejection-vs-transport policy lives in one place.
fn map_handshake(
    result: Result<client::Handle<ClientHandler>, ConnectError>,
    rejected: &AtomicBool,
) -> Result<client::Handle<ClientHandler>, ConnectError> {
    result.map_err(|e| {
        if rejected.load(Ordering::SeqCst) {
            ConnectError::HostKeyRejected
        } else {
            e
        }
    })
}

/// Opens a TCP+SSH transport connection to `addr` (host:port), negotiating with
/// the Phase-1a allowlist and routing the host-key decision to `verifier`.
pub async fn connect_core(
    addr: String,
    allow_legacy: bool,
    allow_deprecated: bool,
    keepalive: KeepaliveConfig,
    verifier: Arc<dyn HostKeyVerifier>,
) -> Result<Connection, ConnectError> {
    connect_core_with_timeout(
        addr,
        allow_legacy,
        allow_deprecated,
        keepalive,
        HANDSHAKE_TIMEOUT,
        verifier,
    )
    .await
}

/// Body of [`connect_core`], with the handshake deadline injectable so the
/// timeout→`Timeout` mapping is testable without waiting the full 20 s.
async fn connect_core_with_timeout(
    addr: String,
    allow_legacy: bool,
    allow_deprecated: bool,
    keepalive: KeepaliveConfig,
    handshake_timeout: std::time::Duration,
    verifier: Arc<dyn HostKeyVerifier>,
) -> Result<Connection, ConnectError> {
    let (config, handler, tier3_in_use, rejected, forwards) = prepare(
        addr.clone(),
        allow_legacy,
        allow_deprecated,
        keepalive,
        verifier,
    );

    // Bound the handshake so a host that accepts TCP but never speaks SSH fails
    // fast as `Timeout` instead of hanging until the session inactivity backstop.
    // Dropping the timed-out future tears down the half-open connection.
    let connect_fut = client::connect(config, addr, handler);
    let handle = match tokio::time::timeout(handshake_timeout, connect_fut).await {
        Ok(result) => map_handshake(result, &rejected)?,
        Err(_elapsed) => return Err(ConnectError::Timeout),
    };

    Ok(Connection {
        handle: std::sync::Arc::new(tokio::sync::Mutex::new(handle)),
        tier3_in_use,
        forwards,
        parents: Vec::new(),
    })
}

/// UniFFI entry point: connect to `addr` ("host:port"), delegating host-key
/// trust to the foreign `verifier`. Async over the tokio runtime.
#[uniffi::export(async_runtime = "tokio")]
pub async fn connect(
    addr: String,
    allow_legacy: bool,
    allow_deprecated: bool,
    keepalive: KeepaliveConfig,
    verifier: Arc<dyn HostKeyVerifier>,
) -> Result<Arc<Connection>, ConnectError> {
    connect_core(addr, allow_legacy, allow_deprecated, keepalive, verifier)
        .await
        .map(Arc::new)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    /// Trust double used as a fixture by the handshake-timeout test below. It is
    /// NOT exercised as a system-under-test — the real trust/reject paths are
    /// covered by `connect_integration.rs` (which asserts `HostKeyRejected` and
    /// the presented fingerprint). (The former `verifier_double_is_callable_*`
    /// test that asserted only this fake's hardcoded `true` was removed as a
    /// mock-only tautology per the testing standard.)
    struct AlwaysTrust;
    #[async_trait::async_trait]
    impl HostKeyVerifier for AlwaysTrust {
        async fn verify(&self, _info: HostKeyInfo) -> bool {
            true
        }
    }

    // --- derive_timers: the keepalive/inactivity policy (Core tier) ------------
    //
    // The bug this replaces was a hardcoded 20 s inactivity timeout that fired
    // before any keepalive could, killing every idle session. These tests pin
    // the derived values exactly and assert the load-bearing invariant
    // (inactivity strictly above the keepalive-failure window) so the race can
    // never silently return.
    use std::time::Duration;

    /// russh disconnects on the `(count_max + 1)`-th unanswered probe tick, so
    /// the keepalive death point is `interval × (count_max + 1)`. The inactivity
    /// backstop must sit strictly above it.
    fn keepalive_death_point(interval_secs: u64, count_max: u64) -> Duration {
        Duration::from_secs(interval_secs * (count_max + 1))
    }

    #[test]
    fn default_interval_derives_exact_timers_above_the_keepalive_window() {
        // EP: keepalives enabled, the shipped default (interval 30, countMax 3).
        let (keepalive, max, inactivity) = derive_timers(KeepaliveConfig {
            interval_secs: 30,
            count_max: 3,
        });
        assert_eq!(keepalive, Some(Duration::from_secs(30)));
        assert_eq!(max, 3);
        // (3 + 3) × 30 = 180: death point (120) + a 2-interval cushion.
        assert_eq!(inactivity, Duration::from_secs(180));
        assert!(
            inactivity > keepalive_death_point(30, 3),
            "inactivity {inactivity:?} must exceed the 120s keepalive death point"
        );
    }

    #[test]
    fn zero_interval_disables_keepalive_with_fixed_backstop() {
        // EP: keepalives disabled (OpenSSH `ServerAliveInterval 0`).
        let (keepalive, max, inactivity) = derive_timers(KeepaliveConfig {
            interval_secs: 0,
            count_max: 3,
        });
        assert_eq!(keepalive, None, "interval 0 must disable keepalive probes");
        assert_eq!(max, 3);
        assert_eq!(
            inactivity, NO_KEEPALIVE_INACTIVITY,
            "no keepalive window to derive from → fixed 180s backstop, not None"
        );
    }

    #[test]
    fn boundary_min_interval_and_zero_count_max_still_backstops_above_window() {
        // BVA: smallest enabling interval (1) and count_max 0.
        // russh treats keepalive_max == 0 as "unlimited retries", so the
        // inactivity backstop is the ONLY liveness bound here — it must be > 0
        // and (trivially) above the degenerate 1×1 window.
        let (keepalive, max, inactivity) = derive_timers(KeepaliveConfig {
            interval_secs: 1,
            count_max: 0,
        });
        assert_eq!(keepalive, Some(Duration::from_secs(1)));
        assert_eq!(max, 0);
        // (0 + 3) × 1 = 3.
        assert_eq!(inactivity, Duration::from_secs(3));
        assert!(inactivity > Duration::from_secs(0));
        assert!(inactivity > keepalive_death_point(1, 0));
    }

    #[test]
    fn invariant_holds_across_representative_configs() {
        // The anti-regression guard: for every enabled config, the inactivity
        // backstop stays strictly above the keepalive death point, so keepalive
        // (not the inactivity timer) declares death in the normal case.
        for (interval, max) in [(15u32, 3u32), (30, 3), (60, 5), (5, 1), (120, 10)] {
            let (_, _, inactivity) = derive_timers(KeepaliveConfig {
                interval_secs: interval,
                count_max: max,
            });
            assert!(
                inactivity > keepalive_death_point(interval as u64, max as u64),
                "config (interval={interval}, max={max}): inactivity {inactivity:?} \
                 must exceed keepalive death point {:?}",
                keepalive_death_point(interval as u64, max as u64),
            );
        }
    }

    #[test]
    fn default_keepalive_config_matches_openssh_and_app_fallbacks() {
        // The Default impl must equal the app's resolve fallbacks (30 / 3) so a
        // quick-connect (no saved Host) still gets a sane liveness policy.
        let cfg = KeepaliveConfig::default();
        assert_eq!(cfg.interval_secs, 30);
        assert_eq!(cfg.count_max, 3);
    }

    /// A host that accepts the TCP connection but never sends its SSH banner
    /// must fail as `ConnectError::Timeout` (not hang, not a `Transport` error).
    /// Uses a short injected deadline against a local black-hole listener so the
    /// assertion runs in milliseconds rather than the production 20 s.
    #[tokio::test]
    async fn handshake_timeout_on_a_silent_host_maps_to_timeout_error() {
        // Accept-and-stay-silent listener: the SSH handshake awaits the server
        // banner forever, so only the timeout wrapper can resolve the connect.
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        // Hold accepted sockets open (silent) for the test's lifetime.
        let _pump = tokio::spawn(async move {
            let mut held = Vec::new();
            while let Ok((sock, _)) = listener.accept().await {
                held.push(sock);
            }
        });

        let started = tokio::time::Instant::now();
        let err = connect_core_with_timeout(
            addr.to_string(),
            false,
            false,
            KeepaliveConfig::default(),
            Duration::from_millis(300),
            Arc::new(AlwaysTrust),
        )
        .await
        .expect_err("a silent host must not yield a live connection");

        assert!(
            matches!(err, ConnectError::Timeout),
            "expected ConnectError::Timeout, got {err:?}"
        );
        // Proves the wrapper fired (didn't hang / wasn't the 20 s production bound).
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "timeout should fire near the 300ms deadline, took {:?}",
            started.elapsed()
        );
    }
}
