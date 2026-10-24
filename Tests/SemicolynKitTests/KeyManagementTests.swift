// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import SemicolynKit

private struct FixedMinter: IdentityMinter {
    let material: KeyMaterial
    func mintEd25519() throws -> KeyMaterial { material }
    func importPrivateKey(_ openssh: String, passphrase: String?) throws -> KeyMaterial { material }
}

/// M-70: the SSH Keys screen's rename, delete cascade and public-key text.
final class KeyManagementTests: XCTestCase {
    private let privateMarker = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----\n"
    private let publicLine = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHdjdNaZLZK183o6Pa7qySNDPXxGuHmDtFflqfOqtEod"

    private func makeStack() -> (HostStore, InMemorySecretStore, IdentityService) {
        let store = HostStore(records: EncryptedRecordStore(backend: InMemoryBlobStore(),
                                                            key: SymmetricKey(size: .bits256)))
        let secrets = InMemorySecretStore()
        let material = KeyMaterial(privateKeyOpenSSH: privateMarker, publicKeyOpenSSH: publicLine,
                                   fingerprintSHA256: "SHA256:PtkDvL4UyR3eqdGREgOkWeVVVVs4HqzNN3IRI/pohX8",
                                   algorithm: .ed25519)
        return (store, secrets, IdentityService(store: store, secrets: secrets,
                                                minter: FixedMinter(material: material)))
    }

    private func mint(_ svc: IdentityService, _ name: String) throws -> Identity {
        try svc.createGenerated(displayName: name, biometricPolicy: .never,
                                now: Date(timeIntervalSince1970: 0))
    }

    // MARK: Delete cascade

    func testDeletingAKeyInUseRemovesItFromEveryHostAndDefaults() throws {
        let (store, secrets, svc) = makeStack()
        let doomed = try mint(svc, "laptop")
        let kept = try mint(svc, "work")
        let onlyKey = SemicolynKit.Host(id: UUID(), label: "web", hostName: "w",
                                        identities: .explicit([doomed.id]))
        let twoKeys = SemicolynKit.Host(id: UUID(), label: "db", hostName: "d",
                                        identities: .explicit([doomed.id, kept.id]))
        let viaJump = SemicolynKit.Host(id: UUID(), label: "inner", hostName: "i",
                                        proxyJump: .explicit([.inline(hostName: "bastion", port: 22, user: "u",
                                                                      identities: [doomed.id])]))
        let unrelated = SemicolynKit.Host(id: UUID(), label: "other", hostName: "o",
                                          identities: .explicit([kept.id]))
        for h in [onlyKey, twoKeys, viaJump, unrelated] { try store.saveHost(h) }
        try store.saveDefaults(Defaults(identities: .explicit([doomed.id])))

        let usage = try svc.deleteIdentity(id: doomed.id)

        XCTAssertEqual(Set(usage.hosts.map(\.label)), ["web", "db", "inner"])
        XCTAssertTrue(usage.isDefaultKey)
        // No host and not the Defaults still point at the deleted key.
        XCTAssertEqual(try store.hostsUsing(identityID: doomed.id), [])
        XCTAssertEqual(try store.host(id: onlyKey.id)?.identities, .inherit)       // falls back to Defaults
        XCTAssertEqual(try store.host(id: twoKeys.id)?.identities, .explicit([kept.id]))
        XCTAssertEqual(try store.host(id: viaJump.id)?.proxyJump,
                       .explicit([.inline(hostName: "bastion", port: 22, user: "u", identities: nil)]))
        XCTAssertEqual(try store.host(id: unrelated.id), unrelated)
        XCTAssertEqual(try store.defaults().identities, .inherit)
        // The record and its secrets are gone; the other key is untouched.
        XCTAssertNil(try store.identity(id: doomed.id))
        XCTAssertNil(try secrets.getSecret(.privateKey(identityID: doomed.id)))
        XCTAssertNotNil(try store.identity(id: kept.id))
        XCTAssertNotNil(try secrets.getSecret(.privateKey(identityID: kept.id)))
    }

    func testDeletingAnUnusedKeyReportsNoUsage() throws {
        let (store, secrets, svc) = makeStack()
        let key = try mint(svc, "spare")
        try secrets.setSecret(Data("pass".utf8), for: .passphrase(identityID: key.id))

        XCTAssertEqual(try svc.deleteIdentity(id: key.id), IdentityUsage(hosts: [], isDefaultKey: false))
        XCTAssertEqual(try store.allIdentities(), [])
        XCTAssertNil(try secrets.getSecret(.passphrase(identityID: key.id)))
    }

    func testDeletingAMissingKeyIsNotFound() throws {
        let (_, _, svc) = makeStack()
        XCTAssertThrowsError(try svc.deleteIdentity(id: UUID())) {
            XCTAssertEqual($0 as? IdentityEditError, .notFound)
        }
    }

    func testUsageListsDefaultsKeyEvenWithNoHosts() throws {
        let (store, _, svc) = makeStack()
        let key = try mint(svc, "default")
        try store.saveDefaults(Defaults(identities: .explicit([key.id])))
        XCTAssertEqual(try store.identityUsage(identityID: key.id),
                       IdentityUsage(hosts: [], isDefaultKey: true))
    }

    // MARK: Rename

    func testRenameTrimsAndKeepsKeyAndReferences() throws {
        let (store, _, svc) = makeStack()
        let key = try mint(svc, "old")
        let host = SemicolynKit.Host(id: UUID(), label: "web", hostName: "w", identities: .explicit([key.id]))
        try store.saveHost(host)

        let renamed = try svc.rename(identityID: key.id, to: "  new name \n")

        XCTAssertEqual(renamed.displayName, "new name")
        let saved = try XCTUnwrap(try store.identity(id: key.id))
        XCTAssertEqual(saved.displayName, "new name")
        XCTAssertEqual(saved.publicKey, key.publicKey)
        XCTAssertEqual(saved.fingerprint, key.fingerprint)
        XCTAssertEqual(try store.host(id: host.id)?.identities, .explicit([key.id]))
    }

    func testRenameRejectsBlankName() throws {
        let (store, _, svc) = makeStack()
        let key = try mint(svc, "old")
        XCTAssertThrowsError(try svc.rename(identityID: key.id, to: " \t ")) {
            XCTAssertEqual($0 as? IdentityEditError, .emptyName)
        }
        XCTAssertEqual(try store.identity(id: key.id)?.displayName, "old")
    }

    func testRenameMissingKeyIsNotFound() throws {
        let (_, _, svc) = makeStack()
        XCTAssertThrowsError(try svc.rename(identityID: UUID(), to: "x")) {
            XCTAssertEqual($0 as? IdentityEditError, .notFound)
        }
    }

    // MARK: Public key text

    func testShareTextIsThePublicLineWithTheNameAsComment() throws {
        let (_, _, svc) = makeStack()
        let key = try mint(svc, "My iPhone")
        XCTAssertEqual(publicKeyShareText(key), "\(publicLine) My iPhone")
    }

    func testShareTextNeverContainsPrivateKeyBytes() throws {
        let (_, secrets, svc) = makeStack()
        let key = try mint(svc, "phone")
        let stored = String(decoding: try XCTUnwrap(try secrets.getSecret(.privateKey(identityID: key.id))),
                            as: UTF8.self)
        let text = try XCTUnwrap(publicKeyShareText(key))
        XCTAssertFalse(text.contains("PRIVATE KEY"))
        XCTAssertFalse(text.contains("b3BlbnNzaC1rZXktdjEAAAAA"))
        XCTAssertFalse(text.contains(stored))
        XCTAssertFalse(identityDeleteMessage(IdentityUsage(hosts: [], isDefaultKey: false)).contains("PRIVATE"))
    }

    func testShareTextKeepsAnExistingComment() {
        XCTAssertEqual(publicKeyShareText(identity(publicKey: "\(publicLine) user@box\n", name: "ignored")),
                       "\(publicLine) user@box")
    }

    func testShareTextFoldsLineBreaksInTheName() {
        XCTAssertEqual(publicKeyShareText(identity(publicKey: publicLine, name: "a\nb\r\tc  ")),
                       "\(publicLine) a b c")
        XCTAssertEqual(publicKeyShareText(identity(publicKey: publicLine, name: " \n ")), publicLine)
    }

    func testShareTextRefusesARecordHoldingPrivateKeyMaterial() {
        XCTAssertNil(publicKeyShareText(identity(publicKey: privateMarker, name: "x")))
        XCTAssertNil(publicKeyShareText(identity(publicKey: "ssh-ed25519 AAAA PRIVATE KEY", name: "x")))
        XCTAssertNil(publicKeyShareText(identity(publicKey: "\(publicLine)\n\(publicLine)", name: "x")))
    }

    func testShareTextRefusesMalformedLines() {
        for bad in ["", "ssh-ed25519", "ssh-foo AAAAC3Nz", "ssh-ed25519 not*base64", "ssh-ed25519 é"] {
            XCTAssertNil(publicKeyShareText(identity(publicKey: bad, name: "x")), bad)
        }
        XCTAssertEqual(publicKeyShareText(identity(publicKey: "ecdsa-sha2-nistp256 AAAA c", name: "x")),
                       "ecdsa-sha2-nistp256 AAAA c")
    }

    func testAlgorithmDisplayNames() {
        XCTAssertEqual([KeyAlgorithm.ed25519, .ecdsaP256, .ecdsaP384, .rsa].map(\.displayName),
                       ["Ed25519", "ECDSA P-256", "ECDSA P-384", "RSA"])
    }

    // MARK: Delete message

    func testDeleteMessageListsHostsAndDefaults() {
        let ref = { HostRef(id: UUID(), label: $0) }
        XCTAssertEqual(identityDeleteMessage(IdentityUsage(hosts: [], isDefaultKey: false)),
                       "No hosts use this key. This can't be undone.")
        XCTAssertEqual(identityDeleteMessage(IdentityUsage(hosts: [ref("web")], isDefaultKey: false)),
                       "web uses this key and will stop using it. This can't be undone.")
        XCTAssertEqual(identityDeleteMessage(IdentityUsage(hosts: [ref("web"), ref("db")], isDefaultKey: true)),
                       "web, db and Connection Defaults use this key and will stop using it. This can't be undone.")
        XCTAssertEqual(identityDeleteMessage(IdentityUsage(hosts: [], isDefaultKey: true)),
                       "Connection Defaults uses this key and will stop using it. This can't be undone.")
    }

    private func identity(publicKey: String, name: String) -> Identity {
        Identity(id: UUID(), displayName: name, flavor: .iCloudKeychain, algorithm: .ed25519,
                 publicKey: publicKey, fingerprint: "SHA256:x", createdAt: Date(timeIntervalSince1970: 0),
                 biometricPolicy: .never)
    }
}
