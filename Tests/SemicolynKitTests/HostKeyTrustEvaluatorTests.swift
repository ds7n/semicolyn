// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

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

    // Adversarial (security audit H3): a known host offering a key type it never offered
    // before is NOT a plain first trust; the stored keys come back so the prompt can warn.
    func testNewAlgorithmOnKnownHostIsNewKeyType() throws {
        let (ev, _) = evaluator()
        let h = UUID()
        try ev.trust(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:AAA", at: t0)
        let decision = try ev.evaluate(hostID: h, algorithm: "ssh-rsa", fingerprint: "SHA256:CCC")
        guard case let .newKeyType(known) = decision else {
            return XCTFail("expected newKeyType, got \(decision)")
        }
        XCTAssertEqual(known.map(\.algorithm), ["ssh-ed25519"])
        XCTAssertEqual(known.map(\.fingerprint), ["SHA256:AAA"])
    }

    // EP: every stored key of every other type is surfaced, in stored order.
    func testNewKeyTypeListsAllKnownKeys() throws {
        let (ev, _) = evaluator()
        let h = UUID()
        try ev.trust(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:AAA", at: t0)
        try ev.trust(hostID: h, algorithm: "ecdsa-sha2-nistp256", fingerprint: "SHA256:EEE", at: t0)
        let decision = try ev.evaluate(hostID: h, algorithm: "ssh-rsa", fingerprint: "SHA256:CCC")
        guard case let .newKeyType(known) = decision else {
            return XCTFail("expected newKeyType, got \(decision)")
        }
        XCTAssertEqual(known.map(\.fingerprint), ["SHA256:AAA", "SHA256:EEE"])
    }

    // Precedence: a changed key of an already-stored type is a mismatch, even when other
    // types are stored too (never downgraded to the milder new-key-type warning).
    func testSameTypeChangeIsMismatchEvenWithOtherTypesStored() throws {
        let (ev, _) = evaluator()
        let h = UUID()
        try ev.trust(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:AAA", at: t0)
        try ev.trust(hostID: h, algorithm: "ssh-rsa", fingerprint: "SHA256:RRR", at: t0)
        let decision = try ev.evaluate(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:BBB")
        guard case let .mismatch(stored) = decision else {
            return XCTFail("expected mismatch, got \(decision)")
        }
        XCTAssertEqual(stored.map(\.fingerprint), ["SHA256:AAA"])
    }

    // Another host's keys never make this host "known".
    func testOtherHostsKeysDoNotMakeHostKnown() throws {
        let (ev, _) = evaluator()
        try ev.trust(hostID: UUID(), algorithm: "ssh-ed25519", fingerprint: "SHA256:AAA", at: t0)
        XCTAssertEqual(try ev.evaluate(hostID: UUID(), algorithm: "ssh-rsa",
                                       fingerprint: "SHA256:CCC"), .firstTrust)
    }

    // Accepting a new key type adds it beside the old keys (nothing is replaced).
    func testTrustAfterNewKeyTypeKeepsOldKeys() throws {
        let (ev, store) = evaluator()
        let h = UUID()
        try ev.trust(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:AAA", at: t0)
        try ev.trust(hostID: h, algorithm: "ssh-rsa", fingerprint: "SHA256:CCC", at: t0)
        XCTAssertEqual(try ev.evaluate(hostID: h, algorithm: "ssh-rsa", fingerprint: "SHA256:CCC"), .trusted)
        XCTAssertEqual(try ev.evaluate(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:AAA"), .trusted)
        XCTAssertEqual(try store.entries(forHost: h).map(\.fingerprint), ["SHA256:AAA", "SHA256:CCC"])
    }

    // The same key (same SHA256 fingerprint) reported under a different algorithm name
    // (e.g. an RSA signature-algorithm alias) is the same key: trusted, no warning.
    func testSameFingerprintUnderOtherAlgorithmNameIsTrusted() throws {
        let (ev, _) = evaluator()
        let h = UUID()
        try ev.trust(hostID: h, algorithm: "ssh-rsa", fingerprint: "SHA256:RRR", at: t0)
        XCTAssertEqual(try ev.evaluate(hostID: h, algorithm: "rsa-sha2-512",
                                       fingerprint: "SHA256:RRR"), .trusted)
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
        // No prior entry for this algorithm, replace degenerates to a plain add.
        try ev.replace(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:NEW", at: t0)
        XCTAssertEqual(try ev.evaluate(hostID: h, algorithm: "ssh-ed25519", fingerprint: "SHA256:NEW"), .trusted)
        XCTAssertEqual(try store.entries(forHost: h).map(\.fingerprint), ["SHA256:NEW"])
    }

    // Adversarial (security audit M2): an unreadable store must surface as an error the
    // caller fails closed on, never as an empty store that reads as a first connection.
    func testStoreReadErrorPropagatesInsteadOfFirstTrust() {
        let ev = HostKeyTrustEvaluator(store: HostKeyStore(secrets: FailingSecretStore()))
        XCTAssertThrowsError(try ev.evaluate(hostID: UUID(), algorithm: "ssh-ed25519",
                                             fingerprint: "SHA256:AAA")) { error in
            XCTAssertEqual(error as? FailingSecretStore.Failure, .readFailed)
        }
    }

    // Adversarial (M2): corrupt stored data is an error too, not "nothing stored".
    func testCorruptStoredKeysThrowInsteadOfFirstTrust() throws {
        let secrets = InMemorySecretStore()
        let h = UUID()
        try secrets.setSecret(Data("not json".utf8), for: .hostKeys(hostID: h))
        let ev = HostKeyTrustEvaluator(store: HostKeyStore(secrets: secrets))
        XCTAssertThrowsError(try ev.evaluate(hostID: h, algorithm: "ssh-ed25519",
                                             fingerprint: "SHA256:AAA")) { error in
            XCTAssertTrue(error is DecodingError, "expected DecodingError, got \(error)")
        }
    }
}

/// A store whose every read fails, standing in for a Keychain error.
private final class FailingSecretStore: SecretStore {
    enum Failure: Error, Equatable { case readFailed }
    func setSecret(_ data: Data, for ref: SecretRef) throws {}
    func getSecret(_ ref: SecretRef) throws -> Data? { throw Failure.readFailed }
    func deleteSecret(_ ref: SecretRef) throws {}
}
