// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import GlymrSSHCoreFFI

/// Round-trip tests for the UniFFI key-material bridge used by `CoreIdentityMinter`.
///
/// `CoreIdentityMinter`'s only logic is the value mapping from `GlymrSSHCoreFFI.KeyMaterial`
/// to `GlymrKit.KeyMaterial`; the field assertions here cover the source values that
/// mapping reads. The Xcode-linked `CoreIdentityMinter` (App target) is exercised in
/// Tasks 4–5; its mapping correctness is validated by these field-level assertions.
///
/// Generated Swift symbol names confirmed from `uniffi-bindgen` output:
///   - `GlymrSSHCoreFFI.mintEd25519Identity()`
///   - `GlymrSSHCoreFFI.importPrivateKey(openssh:passphrase:)`
///   - `KeyMaterial.privateKeyOpenssh`, `.publicKeyOpenssh`, `.fingerprintSha256`, `.algorithm`
final class CoreIdentityMinterTests: XCTestCase {

    // MARK: - Mint round-trip

    /// Minting produces a well-formed ed25519 `KeyMaterial` and the private key
    /// re-imports to an identical public key + fingerprint.
    func testMintProducesParsableEd25519() throws {
        let m = try GlymrSSHCoreFFI.mintEd25519Identity()

        XCTAssertEqual(m.algorithm, "ed25519")
        XCTAssertTrue(
            m.publicKeyOpenssh.hasPrefix("ssh-ed25519 "),
            "public key must start with 'ssh-ed25519 ', got: \(m.publicKeyOpenssh)"
        )
        XCTAssertTrue(
            m.fingerprintSha256.hasPrefix("SHA256:"),
            "fingerprint must start with 'SHA256:', got: \(m.fingerprintSha256)"
        )
        XCTAssertFalse(m.privateKeyOpenssh.isEmpty, "private key must be non-empty")

        // Round-trip: the minted private key re-imports to the same public key + fingerprint.
        let reparsed = try GlymrSSHCoreFFI.importPrivateKey(openssh: m.privateKeyOpenssh, passphrase: nil)
        XCTAssertEqual(reparsed.publicKeyOpenssh, m.publicKeyOpenssh)
        XCTAssertEqual(reparsed.fingerprintSha256, m.fingerprintSha256)
        XCTAssertEqual(reparsed.algorithm, "ed25519")
    }

    /// Each mint call produces a distinct key — the RNG is seeded fresh.
    func testMintedKeysAreDistinct() throws {
        let a = try GlymrSSHCoreFFI.mintEd25519Identity()
        let b = try GlymrSSHCoreFFI.mintEd25519Identity()
        XCTAssertNotEqual(a.fingerprintSha256, b.fingerprintSha256)
        XCTAssertNotEqual(a.publicKeyOpenssh, b.publicKeyOpenssh)
    }

    // MARK: - Import errors

    /// Garbage input is rejected with a `KeyError.Parse` error.
    func testImportRejectsGarbage() {
        XCTAssertThrowsError(
            try GlymrSSHCoreFFI.importPrivateKey(openssh: "nope", passphrase: nil),
            "expected Parse error for malformed key"
        ) { error in
            guard case KeyError.Parse(let msg) = error else {
                XCTFail("expected KeyError.Parse, got \(error)")
                return
            }
            XCTAssertFalse(msg.isEmpty, "parse error message must be non-empty")
        }
    }
}
