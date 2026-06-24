// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class HostKeyStoreTests: XCTestCase {
    private func key(_ fp: String) -> HostKey {
        HostKey(algorithm: "ssh-ed25519", fingerprint: fp,
                addedAt: Date(timeIntervalSince1970: 0), source: .trustOnFirstUse)
    }

    func testRotationKeepsMultipleEntriesPerHost() throws {
        let store = HostKeyStore(secrets: InMemorySecretStore())
        let h = UUID()
        XCTAssertEqual(try store.entries(forHost: h), [])
        try store.add(key("SHA256:AAA"), forHost: h)
        try store.add(key("SHA256:BBB"), forHost: h)               // rotation window: both valid
        XCTAssertEqual(try store.entries(forHost: h).map(\.fingerprint), ["SHA256:AAA", "SHA256:BBB"])
    }

    func testEntriesAreScopedPerHost() throws {
        let store = HostKeyStore(secrets: InMemorySecretStore())
        let h1 = UUID(), h2 = UUID()
        try store.add(key("SHA256:AAA"), forHost: h1)
        XCTAssertEqual(try store.entries(forHost: h2), [])         // other host unaffected
    }

    func testRemoveByFingerprint() throws {
        let store = HostKeyStore(secrets: InMemorySecretStore())
        let h = UUID()
        try store.add(key("SHA256:AAA"), forHost: h)
        try store.add(key("SHA256:BBB"), forHost: h)
        try store.remove(fingerprint: "SHA256:AAA", forHost: h)
        XCTAssertEqual(try store.entries(forHost: h).map(\.fingerprint), ["SHA256:BBB"])
        try store.remove(fingerprint: "SHA256:BBB", forHost: h)
        XCTAssertEqual(try store.entries(forHost: h), [])           // last removed → empty
    }
}
