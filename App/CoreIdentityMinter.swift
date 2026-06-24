// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import NeotildeKit
import NeotildeSSHCoreFFI

/// Thrown when the Rust core returns an algorithm string NeotildeKit's `KeyAlgorithm`
/// doesn't model. Unreachable in practice (Rust rejects unsupported algorithms first);
/// kept as a guard for future algorithm additions.
private struct UnmodeledAlgorithm: Error, CustomStringConvertible {
    let algorithm: String
    var description: String { "unsupported algorithm: \(algorithm)" }
}

/// `IdentityMinter` backed by the Rust SSH core. Translates the UniFFI
/// `KeyMaterial`/`KeyError` into NeotildeKit's pure value types. Errors propagate
/// as-is; `IdentityService` wraps them in `IdentityServiceError.minting`.
///
/// Generated Swift field names (confirmed from `uniffi-bindgen` output):
///   `fingerprintSha256`, `privateKeyOpenssh`, `publicKeyOpenssh` (lower-camel).
/// NeotildeKit's `KeyMaterial` uses `fingerprintSHA256`, `privateKeyOpenSSH`,
/// `publicKeyOpenSSH` (acronyms uppercased per Swift API guidelines).
struct CoreIdentityMinter: IdentityMinter {
    func mintEd25519() throws -> NeotildeKit.KeyMaterial {
        try map(NeotildeSSHCoreFFI.mintEd25519Identity())
    }

    func importPrivateKey(_ openssh: String, passphrase: String?) throws -> NeotildeKit.KeyMaterial {
        try map(NeotildeSSHCoreFFI.importPrivateKey(openssh: openssh, passphrase: passphrase))
    }

    /// Maps a UniFFI `KeyMaterial` record to a `NeotildeKit.KeyMaterial` value.
    ///
    /// An unmodeled algorithm string is surfaced as `IdentityServiceError.minting`
    /// rather than a crash — Rust already rejects unsupported algorithms via
    /// `KeyError.UnsupportedAlgorithm`, so this branch is a belt-and-suspenders
    /// guard for future algorithm additions that Rust models but Swift hasn't
    /// added to `KeyAlgorithm` yet.
    private func map(_ m: NeotildeSSHCoreFFI.KeyMaterial) throws -> NeotildeKit.KeyMaterial {
        guard let alg = KeyAlgorithm(rawValue: m.algorithm) else {
            throw UnmodeledAlgorithm(algorithm: m.algorithm)
        }
        return NeotildeKit.KeyMaterial(
            privateKeyOpenSSH: m.privateKeyOpenssh,
            publicKeyOpenSSH: m.publicKeyOpenssh,
            fingerprintSHA256: m.fingerprintSha256,
            algorithm: alg
        )
    }
}
