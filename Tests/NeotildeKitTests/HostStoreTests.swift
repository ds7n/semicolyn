// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import NeotildeKit

final class HostStoreTests: XCTestCase {
    private func makeStore() -> HostStore {
        HostStore(records: EncryptedRecordStore(backend: InMemoryBlobStore(),
                                                key: SymmetricKey(size: .bits256)))
    }
    private func host(_ label: String, _ id: UUID = UUID(),
                      jump: [JumpHop] = [], ids: [IdentityRef] = []) -> NeotildeKit.Host {
        NeotildeKit.Host(id: id, label: label, hostName: "h",
                      identities: ids.isEmpty ? .inherit : .explicit(ids),
                      proxyJump: jump.isEmpty ? .inherit : .explicit(jump))
    }

    func testSaveHostRoundTripAndDuplicateLabelWarning() throws {
        let s = makeStore()
        let a = host("prod")
        XCTAssertEqual(try s.saveHost(a).duplicateLabels, [])           // first "prod": no dup
        XCTAssertEqual(try s.host(id: a.id), a)
        let outcome = try s.saveHost(host("prod"))                      // second "prod": warn, still saved
        XCTAssertEqual(outcome.duplicateLabels.map(\.id), [a.id])
        XCTAssertEqual(try s.allHosts().count, 2)
    }

    func testSaveHostRejectsDirectCycle() throws {
        let s = makeStore()
        let id = UUID()
        XCTAssertThrowsError(try s.saveHost(host("self", id, jump: [.ref(hostId: id)]))) {
            XCTAssertEqual($0 as? StoreError, .jumpChainCycle)
        }
    }

    func testDeleteHostRefusedWhenUsedAsJumpHost() throws {
        let s = makeStore()
        let jump = host("jump")
        try s.saveHost(jump)
        let user = host("prod", jump: [.ref(hostId: jump.id)])
        try s.saveHost(user)
        XCTAssertThrowsError(try s.deleteHost(id: jump.id)) {
            XCTAssertEqual($0 as? StoreError, .jumpHostInUse(by: [HostRef(id: user.id, label: "prod")]))
        }
        try s.deleteHost(id: user.id)                                   // remove the referrer first
        try s.deleteHost(id: jump.id)                                   // now allowed
        XCTAssertNil(try s.host(id: jump.id))
    }

    func testDefaultsSingletonRoundTrip() throws {
        let s = makeStore()
        XCTAssertEqual(try s.defaults(), Defaults())                    // unset → empty
        try s.saveDefaults(Defaults(user: .explicit("root")))
        XCTAssertEqual(try s.defaults().user, .explicit("root"))
    }

    func testIdentityUsedByScanAndRefusedDelete() throws {
        let s = makeStore()
        let kid = UUID()
        let ident = Identity(id: kid, displayName: "gh", flavor: .iCloudKeychain,
                             algorithm: .ed25519, publicKey: "ssh-ed25519 AAAA",
                             fingerprint: "SHA256:x", createdAt: Date(timeIntervalSince1970: 0),
                             biometricPolicy: .afterUnlock)
        try s.saveIdentity(ident)
        let user = host("prod", ids: [kid])
        try s.saveHost(user)
        XCTAssertEqual(try s.hostsUsing(identityID: kid), [HostRef(id: user.id, label: "prod")])
        XCTAssertThrowsError(try s.deleteIdentity(id: kid)) {
            XCTAssertEqual($0 as? StoreError, .identityInUse(by: [HostRef(id: user.id, label: "prod")]))
        }
        try s.deleteHost(id: user.id)
        XCTAssertEqual(try s.hostsUsing(identityID: kid), [])
        try s.deleteIdentity(id: kid)                                   // now allowed
        XCTAssertNil(try s.identity(id: kid))
    }

    func testIdentityUsedByInlineJumpHop() throws {
        let s = makeStore()
        let kid = UUID()
        let user = host("prod", jump: [.inline(hostName: "j", port: nil, user: nil, identities: [kid])])
        try s.saveHost(user)
        XCTAssertEqual(try s.hostsUsing(identityID: kid), [HostRef(id: user.id, label: "prod")])
    }
}
