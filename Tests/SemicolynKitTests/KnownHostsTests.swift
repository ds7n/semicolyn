// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// M-71: the Known Hosts list, labels and removal forcing re-trust.
final class KnownHostsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let t1 = Date(timeIntervalSince1970: 2_000)

    private func host(_ label: String, _ id: UUID = UUID()) -> SemicolynKit.Host {
        SemicolynKit.Host(id: id, label: label, hostName: "\(label).example")
    }

    func testRowsSortByLabelThenAddedDate() throws {
        let store = HostKeyStore(secrets: InMemorySecretStore())
        let ev = HostKeyTrustEvaluator(store: store)
        let zeta = host("zeta"), alpha = host("Alpha"), bare = host("bare")
        try ev.trust(hostID: zeta.id, algorithm: "ssh-ed25519", fingerprint: "SHA256:Z", at: t0)
        try ev.trust(hostID: alpha.id, algorithm: "ssh-rsa", fingerprint: "SHA256:A2", at: t1)
        try ev.trust(hostID: alpha.id, algorithm: "ssh-ed25519", fingerprint: "SHA256:A1", at: t0)

        let rows = knownHostRows(hosts: [zeta, bare, alpha], entries: store.entries(forHost:))

        XCTAssertEqual(rows.map(\.hostLabel), ["Alpha", "Alpha", "zeta"])     // bare has no keys
        XCTAssertEqual(rows.map(\.fingerprint), ["SHA256:A1", "SHA256:A2", "SHA256:Z"])
        XCTAssertEqual(rows.map(\.keyType), ["Ed25519", "RSA", "Ed25519"])
        XCTAssertEqual(rows[0].hostName, "Alpha.example")
        XCTAssertEqual(rows[0].addedAt, t0)
        XCTAssertEqual(Set(rows.map(\.id)).count, 3)
    }

    func testUnreadableHostIsSkippedNotFatal() {
        struct Corrupt: Error {}
        let good = host("good"), bad = host("bad")
        let rows = knownHostRows(hosts: [good, bad]) { id in
            if id == bad.id { throw Corrupt() }
            return [HostKey(algorithm: "ssh-ed25519", fingerprint: "SHA256:G", addedAt: self.t0,
                            source: .trustOnFirstUse)]
        }
        XCTAssertEqual(rows.map(\.hostLabel), ["good"])
    }

    func testNoHostsGivesNoRows() {
        XCTAssertEqual(knownHostRows(hosts: [], entries: { _ in [] }), [])
    }

    func testRemovingAHostKeyForcesReTrust() throws {
        let store = HostKeyStore(secrets: InMemorySecretStore())
        let ev = HostKeyTrustEvaluator(store: store)
        let web = host("web"), other = host("other")
        try ev.trust(hostID: web.id, algorithm: "ssh-ed25519", fingerprint: "SHA256:W", at: t0)
        try ev.trust(hostID: other.id, algorithm: "ssh-ed25519", fingerprint: "SHA256:O", at: t0)
        XCTAssertEqual(try ev.evaluate(hostID: web.id, algorithm: "ssh-ed25519", fingerprint: "SHA256:W"), .trusted)

        let row = try XCTUnwrap(knownHostRows(hosts: [web], entries: store.entries(forHost:)).first)
        try store.remove(fingerprint: row.fingerprint, forHost: row.hostID)

        // The same key is no longer silently trusted: the next connection prompts.
        XCTAssertEqual(try ev.evaluate(hostID: web.id, algorithm: "ssh-ed25519", fingerprint: "SHA256:W"),
                       .firstTrust)
        XCTAssertEqual(knownHostRows(hosts: [web, other], entries: store.entries(forHost:)).map(\.hostLabel),
                       ["other"])
        XCTAssertEqual(try ev.evaluate(hostID: other.id, algorithm: "ssh-ed25519", fingerprint: "SHA256:O"),
                       .trusted)
    }

    func testRemovingOneOfTwoAlgorithmsKeepsTheOther() throws {
        let store = HostKeyStore(secrets: InMemorySecretStore())
        let ev = HostKeyTrustEvaluator(store: store)
        let web = host("web")
        try ev.trust(hostID: web.id, algorithm: "ssh-ed25519", fingerprint: "SHA256:E", at: t0)
        try ev.trust(hostID: web.id, algorithm: "ssh-rsa", fingerprint: "SHA256:R", at: t1)

        try store.remove(fingerprint: "SHA256:E", forHost: web.id)

        XCTAssertEqual(try ev.evaluate(hostID: web.id, algorithm: "ssh-ed25519", fingerprint: "SHA256:E"), .firstTrust)
        XCTAssertEqual(try ev.evaluate(hostID: web.id, algorithm: "ssh-rsa", fingerprint: "SHA256:R"), .trusted)
    }

    func testKeyTypeLabels() {
        XCTAssertEqual(hostKeyTypeLabel("ssh-ed25519"), "Ed25519")
        XCTAssertEqual(hostKeyTypeLabel("ecdsa-sha2-nistp256"), "ECDSA P-256")
        XCTAssertEqual(hostKeyTypeLabel("ecdsa-sha2-nistp384"), "ECDSA P-384")
        XCTAssertEqual(hostKeyTypeLabel("ecdsa-sha2-nistp521"), "ECDSA P-521")
        XCTAssertEqual(hostKeyTypeLabel("rsa-sha2-512"), "RSA")
        XCTAssertEqual(hostKeyTypeLabel("ssh-rsa"), "RSA")
        XCTAssertEqual(hostKeyTypeLabel("sk-ssh-ed25519@openssh.com"), "Ed25519 (security key)")
        XCTAssertEqual(hostKeyTypeLabel("x-unknown"), "x-unknown")
    }

    func testFingerprintDisplayAlwaysHasSHA256Prefix() {
        XCTAssertEqual(Fingerprint("SHA256:abc").sha256Display, "SHA256:abc")
        XCTAssertEqual(Fingerprint("abc/def+").sha256Display, "SHA256:abc/def+")
        XCTAssertEqual(Fingerprint("").sha256Display, "")
        let row = KnownHostRow(hostID: UUID(), hostLabel: "h", hostName: "h", algorithm: "ssh-ed25519",
                               fingerprint: "bare", addedAt: t0)
        XCTAssertEqual(row.displayFingerprint, "SHA256:bare")
        XCTAssertEqual(row.fingerprint, "bare")   // removal still matches the stored value
    }

    func testRemoveMessageIsVerbatim() {
        XCTAssertEqual(knownHostRemoveMessage, "The next connection will ask you to trust this host again.")
    }
}
