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
}

impl From<russh::Error> for ConnectError {
    fn from(e: russh::Error) -> Self {
        ConnectError::Transport { message: e.to_string() }
    }
}

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use russh::client;
use russh::keys::ssh_key::HashAlg;

use crate::algorithms::build_preferred;

/// russh client event handler. Trust decisions go to the injected delegate;
/// `kex_done` records negotiated algorithm names for Tier-3 detection (Task 3).
struct ClientHandler {
    host_label: String,
    verifier: Arc<dyn HostKeyVerifier>,
    /// Set when the delegate rejects the key, so `connect_core` can distinguish
    /// "delegate said no" from a generic transport failure.
    rejected: Arc<AtomicBool>,
    tier3_in_use: Arc<Mutex<Vec<String>>>,
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
    #[allow(dead_code)] // consumed by Phase 1c (auth) and 1d (channels)
    handle: tokio::sync::Mutex<client::Handle<ClientHandler>>,
    tier3_in_use: Arc<Mutex<Vec<String>>>,
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

/// Opens a TCP+SSH transport connection to `addr` (host:port), negotiating with
/// the Phase-1a allowlist and routing the host-key decision to `verifier`.
pub async fn connect_core(
    addr: String,
    allow_legacy: bool,
    allow_deprecated: bool,
    verifier: Arc<dyn HostKeyVerifier>,
) -> Result<Connection, ConnectError> {
    let host_label = addr.clone();
    let tier3_in_use = Arc::new(Mutex::new(Vec::new()));
    let rejected = Arc::new(AtomicBool::new(false));

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
    };

    let handle = match client::connect(config, addr, handler).await {
        Ok(h) => h,
        Err(e) => {
            if rejected.load(Ordering::SeqCst) {
                return Err(ConnectError::HostKeyRejected);
            }
            return Err(e.into());
        }
    };

    Ok(Connection {
        handle: tokio::sync::Mutex::new(handle),
        tier3_in_use,
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
