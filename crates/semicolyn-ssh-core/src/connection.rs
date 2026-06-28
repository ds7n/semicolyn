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
    /// prompt in order (typically a single password). Each `InfoRequest` round
    /// is answered with exactly `prompts.len()` replies taken from `responses`
    /// in order — a zero-prompt round (e.g. PAM's final confirmation) gets an
    /// empty reply, never a stray password. SSH requires the reply count to
    /// match the prompt count; mismatched counts make the server drop the
    /// connection. The loop is bounded to avoid a misbehaving server spinning
    /// forever.
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
        verifier: Arc<dyn HostKeyVerifier>,
    ) -> Result<Arc<Connection>, ConnectError> {
        let host_label = format!("{target_host}:{target_port}");
        let (config, handler, tier3_in_use, rejected, forwards) =
            prepare(host_label, allow_legacy, allow_deprecated, verifier);

        // Open a direct-tcpip channel to the next hop on the current transport,
        // then run the target's SSH handshake over that channel's byte stream.
        // The handle lock is released at the block's end, before connect_stream.
        let stream = {
            let h = self.handle.lock().await;
            h.channel_open_direct_tcpip(target_host, target_port as u32, "127.0.0.1", 0)
                .await?
        }
        .into_stream();

        let handle = map_handshake(
            client::connect_stream(config, stream, handler).await,
            &rejected,
        )?;

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

/// Builds the russh client config and event handler shared by direct
/// (`connect_core`) and jumped (`connect_jump`) connections.
fn prepare(
    host_label: String,
    allow_legacy: bool,
    allow_deprecated: bool,
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

    let config = Arc::new(client::Config {
        preferred,
        inactivity_timeout: Some(std::time::Duration::from_secs(20)),
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
    verifier: Arc<dyn HostKeyVerifier>,
) -> Result<Connection, ConnectError> {
    let (config, handler, tier3_in_use, rejected, forwards) =
        prepare(addr.clone(), allow_legacy, allow_deprecated, verifier);

    let handle = map_handshake(client::connect(config, addr, handler).await, &rejected)?;

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
    verifier: Arc<dyn HostKeyVerifier>,
) -> Result<Arc<Connection>, ConnectError> {
    connect_core(addr, allow_legacy, allow_deprecated, verifier)
        .await
        .map(Arc::new)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    struct AlwaysTrust;
    #[async_trait::async_trait]
    impl HostKeyVerifier for AlwaysTrust {
        async fn verify(&self, _info: HostKeyInfo) -> bool {
            true
        }
    }

    #[tokio::test]
    async fn verifier_double_is_callable_through_trait_object() {
        let v: Arc<dyn HostKeyVerifier> = Arc::new(AlwaysTrust);
        let info = HostKeyInfo {
            host_label: "build-01".into(),
            key_type: "ssh-ed25519".into(),
            fingerprint: "SHA256:abc".into(),
        };
        assert!(v.verify(info).await);
    }
}
