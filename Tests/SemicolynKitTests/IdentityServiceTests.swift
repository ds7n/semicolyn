// Tests/SemicolynKitTests/IdentityServiceTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Wraps an in-memory secret store, counting writes/deletes so tests can assert
/// the "no secret without a matching identity" invariant.
private final class SpySecretStore: SecretStore {
    private let inner = InMemorySecretStore()
    private(set) var setCount = 0
    private(set) var deleteCount = 0
    func setSecret(_ data: Data, for ref: SecretRef) throws { setCount += 1; try inner.setSecret(data, for: ref) }
    func getSecret(_ ref: SecretRef) throws -> Data? { try inner.getSecret(ref) }
    func deleteSecret(_ ref: SecretRef) throws { deleteCount += 1; try inner.deleteSecret(ref) }
    /// True when no live secret remains (sets fully compensated by deletes for the same ref).
    func hasNoLiveSecret(for ref: SecretRef) throws -> Bool { try inner.getSecret(ref) == nil }
}

private struct ThrowingBlobStore: BlobStore {
    struct Boom: Error {}
    func putBlob(_ data: Data, type: String, id: UUID) throws { throw Boom() }
    func getBlob(type: String, id: UUID) throws -> Data? { nil }
    func deleteBlob(type: String, id: UUID) throws {}
    func listBlobs(type: String) throws -> [(id: UUID, data: Data)] { [] }
}

private struct FakeMinter: IdentityMinter {
    var minted: KeyMaterial
    var imported: KeyMaterial
    var importError: Error?
    func mintEd25519() throws -> KeyMaterial { minted }
    func importPrivateKey(_ openssh: String, passphrase: String?) throws -> KeyMaterial {
        if let importError { throw importError }
        return imported
    }
}

final class IdentityServiceTests: XCTestCase {
    private func makeStore() -> HostStore {
        HostStore(records: EncryptedRecordStore(backend: InMemoryBlobStore(),
                                                key: SymmetricKey(size: .bits256)))
    }

    private let sampleMinted = KeyMaterial(
        privateKeyOpenSSH: "PRIVATE-MINTED", publicKeyOpenSSH: "ssh-ed25519 AAAAMINTED c",
        fingerprintSHA256: "SHA256:mintedfp", algorithm: .ed25519)
    private let sampleImported = KeyMaterial(
        privateKeyOpenSSH: "PRIVATE-IMPORTED", publicKeyOpenSSH: "ssh-rsa AAAAIMPORTED c",
        fingerprintSHA256: "SHA256:importedfp", algorithm: .rsa)

    func testCreateGeneratedPersistsKeyAndMetadata() throws {
        let store = makeStore()
        let secrets = InMemorySecretStore()
        let svc = IdentityService(store: store, secrets: secrets,
                                  minter: FakeMinter(minted: sampleMinted, imported: sampleImported))
        let when = Date(timeIntervalSince1970: 1_700_000_000)

        let id = try svc.createGenerated(displayName: "personal", biometricPolicy: .afterUnlock, now: when)

        // Metadata saved with exactly the minted material.
        let saved = try XCTUnwrap(try store.identity(id: id.id))
        XCTAssertEqual(saved.displayName, "personal")
        XCTAssertEqual(saved.flavor, .iCloudKeychain)
        XCTAssertEqual(saved.algorithm, .ed25519)
        XCTAssertEqual(saved.publicKey, "ssh-ed25519 AAAAMINTED c")
        XCTAssertEqual(saved.fingerprint, "SHA256:mintedfp")
        XCTAssertEqual(saved.biometricPolicy, .afterUnlock)
        XCTAssertEqual(saved.createdAt, when)

        // Private key stored ONLY in the secret store, under the identity's id.
        let stored = try XCTUnwrap(try secrets.getSecret(.privateKey(identityID: id.id)))
        XCTAssertEqual(String(decoding: stored, as: UTF8.self), "PRIVATE-MINTED")
    }

    func testPrivateKeyOpenSSHRoundTrips() throws {
        let store = makeStore(); let secrets = InMemorySecretStore()
        let svc = IdentityService(store: store, secrets: secrets,
                                  minter: FakeMinter(minted: sampleMinted, imported: sampleImported))
        let id = try svc.createGenerated(displayName: "p", biometricPolicy: .afterUnlock, now: Date())
        XCTAssertEqual(try svc.privateKeyOpenSSH(for: id.id), "PRIVATE-MINTED")
    }

    func testPrivateKeyOpenSSHNilForUnknownIdentity() throws {
        let store = makeStore(); let secrets = InMemorySecretStore()
        let svc = IdentityService(store: store, secrets: secrets,
                                  minter: FakeMinter(minted: sampleMinted, imported: sampleImported))
        XCTAssertNil(try svc.privateKeyOpenSSH(for: UUID()))
    }

    func testImportPersistsParsedMaterial() throws {
        let store = makeStore(); let secrets = InMemorySecretStore()
        let svc = IdentityService(store: store, secrets: secrets,
                                  minter: FakeMinter(minted: sampleMinted, imported: sampleImported))
        let id = try svc.importIdentity(displayName: "work", openssh: "ignored-by-fake",
                                        passphrase: nil, biometricPolicy: .anyUse, now: Date())
        let saved = try XCTUnwrap(try store.identity(id: id.id))
        XCTAssertEqual(saved.flavor, .iCloudKeychain)
        XCTAssertEqual(saved.algorithm, .rsa)
        XCTAssertEqual(saved.publicKey, "ssh-rsa AAAAIMPORTED c")
        XCTAssertEqual(saved.biometricPolicy, .anyUse)
        XCTAssertEqual(String(decoding: try XCTUnwrap(try secrets.getSecret(.privateKey(identityID: id.id))),
                              as: UTF8.self), "PRIVATE-IMPORTED")
    }

    func testImportSurfacesMinterFailureAsTypedError() throws {
        struct Boom: Error {}
        let store = makeStore(); let spy = SpySecretStore()
        let svc = IdentityService(store: store, secrets: spy,
                                  minter: FakeMinter(minted: sampleMinted, imported: sampleImported,
                                                     importError: Boom()))
        XCTAssertThrowsError(try svc.importIdentity(displayName: "x", openssh: "bad",
                                                    passphrase: nil, biometricPolicy: .afterUnlock, now: Date())) {
            XCTAssertEqual($0 as? IdentityServiceError, .minting("\(Boom())"))
        }
        // No partial write: neither metadata nor a secret was persisted.
        XCTAssertTrue(try store.allIdentities().isEmpty)
        XCTAssertEqual(spy.setCount, 0)
    }

    func testMetadataSaveFailureRollsBackTheSecret() throws {
        let throwingStore = HostStore(records: EncryptedRecordStore(backend: ThrowingBlobStore(),
                                                                    key: SymmetricKey(size: .bits256)))
        let spy = SpySecretStore()
        let svc = IdentityService(store: throwingStore, secrets: spy,
                                  minter: FakeMinter(minted: sampleMinted, imported: sampleImported))
        XCTAssertThrowsError(try svc.createGenerated(displayName: "x", biometricPolicy: .afterUnlock, now: Date()))
        XCTAssertEqual(spy.setCount, 1, "secret was written once before the metadata save")
        XCTAssertEqual(spy.deleteCount, 1, "secret was rolled back after metadata save failed")
        // setCount == deleteCount proves no net secret survives (UUID not observable from outside persist).
        XCTAssertEqual(spy.setCount, spy.deleteCount)
    }
}
