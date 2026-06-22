// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import GlymrKit

final class HostKeyTrustEvaluatorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 0)
    private func evaluator() -> (HostKeyTrustEvaluator, HostKeyStore) {
        let store = HostKeyStore(secrets: InMemorySecretStore())
        return (HostKeyTrustEvaluator(store: store), store)
    }

    func testEmptyHostIsFirstTrust() throws {
        let (ev, _) = evaluator()
        XCTAssertEqual(try ev.evaluate(hostID: UUID(), algorithm: "ssh-ed25519",
                                       fingerprint: "SHA256:AAA"), .firstTrust)
    }

    func testTrustThenSameKeyReadsTrusted() throws {
        let (ev, _) = evaluator()
        let h = UUID()
        try ev.trust(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:AAA", at: t0)
        XCTAssertEqual(try ev.evaluate(hostID: h, algorithm: "ssh-ed25519",
                                       fingerprint: "SHA256:AAA"), .trusted)
    }

    func testDifferentFingerprintSameAlgorithmIsMismatchNotTrusted() throws {
        let (ev, _) = evaluator()
        let h = UUID()
        try ev.trust(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:AAA", at: t0)
        let decision = try ev.evaluate(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:BBB")
        guard case let .mismatch(stored) = decision else {
            return XCTFail("expected mismatch, got \(decision)")
        }
        XCTAssertEqual(stored.map(\.fingerprint), ["SHA256:AAA"])   // surfaces the stored key for the modal
    }

    func testNewAlgorithmIsFirstTrustEvenWhenAnotherAlgorithmTrusted() throws {
        let (ev, _) = evaluator()
        let h = UUID()
        try ev.trust(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:AAA", at: t0)
        // A different key type negotiated → independent first-trust, not a mismatch.
        XCTAssertEqual(try ev.evaluate(hostID: h, algorithm: "rsa-sha2-512",
                                       fingerprint: "SHA256:CCC"), .firstTrust)
    }

    func testRotationWindowBothKeysTrusted() throws {
        let (ev, _) = evaluator()
        let h = UUID()
        try ev.trust(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:AAA", at: t0)
        try ev.trust(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:BBB", at: t0)
        XCTAssertEqual(try ev.evaluate(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:AAA"), .trusted)
        XCTAssertEqual(try ev.evaluate(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:BBB"), .trusted)
    }

    func testReplaceDropsOldKeyAndKeepsOtherAlgorithms() throws {
        let (ev, store) = evaluator()
        let h = UUID()
        try ev.trust(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:AAA", at: t0)
        try ev.trust(hostID: h, algorithm: "rsa-sha2-512", fingerprint: "SHA256:RRR", at: t0)
        try ev.replace(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:NEW", at: t0)
        XCTAssertEqual(try ev.evaluate(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:NEW"), .trusted)
        // The old ed25519 key is gone…
        guard case .mismatch = try ev.evaluate(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:AAA") else {
            return XCTFail("old key should no longer be trusted")
        }
        // …and the untouched rsa key remains.
        XCTAssertEqual(try ev.evaluate(hostID: h, algorithm: "rsa-sha2-512", fingerprint: "SHA256:RRR"), .trusted)
        XCTAssertEqual(Set(try store.entries(forHost: h).map(\.fingerprint)), ["SHA256:NEW", "SHA256:RRR"])
    }

    func testReplaceWithNoExistingEntriesJustAddsTheKey() throws {
        let (ev, store) = evaluator()
        let h = UUID()
        // No prior entry for this algorithm — replace degenerates to a plain add.
        try ev.replace(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:NEW", at: t0)
        XCTAssertEqual(try ev.evaluate(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:NEW"), .trusted)
        XCTAssertEqual(try store.entries(forHost: h).map(\.fingerprint), ["SHA256:NEW"])
    }
}
