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
