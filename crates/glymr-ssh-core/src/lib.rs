// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
uniffi::setup_scaffolding!();

mod algorithms;
pub mod connection;

/// Returns the version string of the Glymr SSH core crate.
///
/// Phase 0 uses this purely to prove the Rust→UniFFI→Swift toolchain end to end.
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn core_version_is_the_crate_version() {
        assert_eq!(core_version(), "0.1.0");
    }
}
