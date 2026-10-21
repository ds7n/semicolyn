// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import SemicolynKit

final class HostDeletionTests: XCTestCase {
    private func makeStore() -> HostStore {
        HostStore(records: EncryptedRecordStore(backend: InMemoryBlobStore(),
                                                key: SymmetricKey(size: .bits256)))
    }
    private func host(_ label: String, jump: [JumpHop] = []) -> SemicolynKit.Host {
        SemicolynKit.Host(id: UUID(), label: label, hostName: "h",
                          proxyJump: jump.isEmpty ? .inherit : .explicit(jump))
    }
    private func key(_ fp: String) -> HostKey {
        HostKey(algorithm: "ssh-ed25519", fingerprint: fp,
                addedAt: Date(timeIntervalSince1970: 0), source: .trustOnFirstUse)
    }

    func testDeleteRemovesHostKeysAndPasswordOfThatHostOnly() throws {
        let hosts = makeStore(), secrets = InMemorySecretStore()
        let keys = HostKeyStore(secrets: secrets)
        let gone = host("gone"), kept = host("kept")
        try hosts.saveHost(gone); try hosts.saveHost(kept)
        try keys.add(key("SHA256:AAA"), forHost: gone.id)
        try keys.add(key("SHA256:BBB"), forHost: gone.id)
        try keys.add(key("SHA256:KEEP"), forHost: kept.id)
        try secrets.setSecret(Data("pw-gone".utf8), for: .password(id: gone.id))
        try secrets.setSecret(Data("pw-kept".utf8), for: .password(id: kept.id))

        try deleteHostAndSecrets(id: gone.id, hosts: hosts, secrets: secrets)

        XCTAssertNil(try hosts.host(id: gone.id))
        XCTAssertNil(try secrets.getSecret(.hostKeys(hostID: gone.id)))
        XCTAssertEqual(try keys.entries(forHost: gone.id), [])
        XCTAssertNil(try secrets.getSecret(.password(id: gone.id)))
        // The other host is untouched.
        XCTAssertEqual(try hosts.host(id: kept.id), kept)
        XCTAssertEqual(try keys.entries(forHost: kept.id).map(\.fingerprint), ["SHA256:KEEP"])
        XCTAssertEqual(try secrets.getSecret(.password(id: kept.id)), Data("pw-kept".utf8))
    }

    func testRefusedDeleteKeepsHostKeysAndPassword() throws {
        let hosts = makeStore(), secrets = InMemorySecretStore()
        let keys = HostKeyStore(secrets: secrets)
        let jump = host("jump")
        try hosts.saveHost(jump)
        let user = host("prod", jump: [.ref(hostId: jump.id)])
        try hosts.saveHost(user)
        try keys.add(key("SHA256:JUMP"), forHost: jump.id)
        try secrets.setSecret(Data("pw".utf8), for: .password(id: jump.id))

        XCTAssertThrowsError(try deleteHostAndSecrets(id: jump.id, hosts: hosts, secrets: secrets)) {
            XCTAssertEqual($0 as? StoreError, .jumpHostInUse(by: [HostRef(id: user.id, label: "prod")]))
        }
        XCTAssertEqual(try hosts.host(id: jump.id), jump)
        XCTAssertEqual(try keys.entries(forHost: jump.id).map(\.fingerprint), ["SHA256:JUMP"])
        XCTAssertEqual(try secrets.getSecret(.password(id: jump.id)), Data("pw".utf8))
    }

    func testDeleteHostWithNoSecretsSucceeds() throws {
        let hosts = makeStore(), secrets = InMemorySecretStore()
        let h = host("bare")
        try hosts.saveHost(h)
        try deleteHostAndSecrets(id: h.id, hosts: hosts, secrets: secrets)
        XCTAssertNil(try hosts.host(id: h.id))
    }

    func testRemoveAllClearsEveryEntryForTheHost() throws {
        let keys = HostKeyStore(secrets: InMemorySecretStore())
        let h = UUID(), other = UUID()
        try keys.add(key("SHA256:AAA"), forHost: h)
        try keys.add(key("SHA256:BBB"), forHost: h)
        try keys.add(key("SHA256:OTHER"), forHost: other)
        try keys.removeAll(forHost: h)
        XCTAssertEqual(try keys.entries(forHost: h), [])
        XCTAssertEqual(try keys.entries(forHost: other).map(\.fingerprint), ["SHA256:OTHER"])
        try keys.removeAll(forHost: h)                              // idempotent
        XCTAssertEqual(try keys.entries(forHost: h), [])
    }
}
