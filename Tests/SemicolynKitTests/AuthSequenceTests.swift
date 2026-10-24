// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// `authenticateInOrder`: each resolved identity is tried in order, then the password.
final class AuthSequenceTests: XCTestCase {
    private let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let c = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!

    /// Runs the sequence with per-identity key availability and server verdicts,
    /// recording which keys and passwords actually reached the "server".
    private func run(
        identities: [UUID],
        password: String,
        keys: [UUID: String],
        keyVerdicts: [UUID: AuthAttemptResult],
        passwordVerdict: AuthAttemptResult = .success,
        sentKeys: inout [String],
        sentPasswords: inout [String]
    ) async throws -> AuthSequenceOutcome {
        var keysSent: [String] = []
        var passwordsSent: [String] = []
        let out = try await authenticateInOrder(
            identities: identities,
            password: password,
            loadKey: { keys[$0] },
            tryKey: { id, key in
                keysSent.append(key)
                return keyVerdicts[id] ?? .failure
            },
            tryPassword: { pw in
                passwordsSent.append(pw)
                return passwordVerdict
            })
        sentKeys = keysSent
        sentPasswords = passwordsSent
        return out
    }

    func testFirstKeySucceedsStopsImmediately() async throws {
        var k: [String] = [], p: [String] = []
        let out = try await run(identities: [a, b], password: "pw",
                                keys: [a: "KEY-A", b: "KEY-B"],
                                keyVerdicts: [a: .success, b: .success],
                                sentKeys: &k, sentPasswords: &p)
        XCTAssertEqual(out, AuthSequenceOutcome(attempts: [.publickey(a)], skippedWithoutKey: [], result: .success))
        XCTAssertEqual(k, ["KEY-A"])
        XCTAssertEqual(p, [])
    }

    func testFirstFailsSecondSucceedsInOrder() async throws {
        var k: [String] = [], p: [String] = []
        let out = try await run(identities: [a, b, c], password: "pw",
                                keys: [a: "KEY-A", b: "KEY-B", c: "KEY-C"],
                                keyVerdicts: [a: .failure, b: .success, c: .success],
                                sentKeys: &k, sentPasswords: &p)
        XCTAssertEqual(out.attempts, [.publickey(a), .publickey(b)])
        XCTAssertEqual(out.result, .success)
        XCTAssertEqual(k, ["KEY-A", "KEY-B"])
        XCTAssertEqual(p, [])
    }

    func testOrderFollowsIdentityListNotKeyMap() async throws {
        var k: [String] = [], p: [String] = []
        let out = try await run(identities: [c, a], password: "",
                                keys: [a: "KEY-A", c: "KEY-C"],
                                keyVerdicts: [:],
                                sentKeys: &k, sentPasswords: &p)
        XCTAssertEqual(out.attempts, [.publickey(c), .publickey(a)])
        XCTAssertEqual(k, ["KEY-C", "KEY-A"])
    }

    func testAllKeysFailThenPasswordSucceeds() async throws {
        var k: [String] = [], p: [String] = []
        let out = try await run(identities: [a, b], password: "hunter2",
                                keys: [a: "KEY-A", b: "KEY-B"],
                                keyVerdicts: [a: .failure, b: .failure],
                                passwordVerdict: .success,
                                sentKeys: &k, sentPasswords: &p)
        XCTAssertEqual(out, AuthSequenceOutcome(attempts: [.publickey(a), .publickey(b), .password],
                                                skippedWithoutKey: [], result: .success))
        XCTAssertEqual(p, ["hunter2"])
    }

    func testAllKeysFailThenPasswordFailsReportsFailure() async throws {
        var k: [String] = [], p: [String] = []
        let out = try await run(identities: [a], password: "wrong",
                                keys: [a: "KEY-A"], keyVerdicts: [a: .failure],
                                passwordVerdict: .failure,
                                sentKeys: &k, sentPasswords: &p)
        XCTAssertEqual(out.attempts, [.publickey(a), .password])
        XCTAssertEqual(out.result, .failure)
    }

    func testPartialSuccessKeyMovesOnToPassword() async throws {
        // publickey + password MFA: the key is accepted partially, then the password finishes.
        var k: [String] = [], p: [String] = []
        let out = try await run(identities: [a], password: "pw",
                                keys: [a: "KEY-A"], keyVerdicts: [a: .partialSuccess],
                                passwordVerdict: .success,
                                sentKeys: &k, sentPasswords: &p)
        XCTAssertEqual(out.attempts, [.publickey(a), .password])
        XCTAssertEqual(out.result, .success)
    }

    func testKeysFailAndNoPasswordDoesNotSendEmptyPassword() async throws {
        var k: [String] = [], p: [String] = []
        let out = try await run(identities: [a, b], password: "",
                                keys: [a: "KEY-A", b: "KEY-B"],
                                keyVerdicts: [a: .failure, b: .partialSuccess],
                                sentKeys: &k, sentPasswords: &p)
        XCTAssertEqual(out.attempts, [.publickey(a), .publickey(b)])
        // The last attempt's result is reported, not a synthetic failure.
        XCTAssertEqual(out.result, .partialSuccess)
        XCTAssertEqual(p, [])
    }

    func testZeroIdentitiesGoesStraightToPassword() async throws {
        var k: [String] = [], p: [String] = []
        let out = try await run(identities: [], password: "pw", keys: [:], keyVerdicts: [:],
                                passwordVerdict: .success, sentKeys: &k, sentPasswords: &p)
        XCTAssertEqual(out, AuthSequenceOutcome(attempts: [.password], skippedWithoutKey: [], result: .success))
        XCTAssertEqual(k, [])
        XCTAssertEqual(p, ["pw"])
    }

    func testZeroIdentitiesEmptyPasswordStillTriesPasswordAsBefore() async throws {
        var k: [String] = [], p: [String] = []
        let out = try await run(identities: [], password: "", keys: [:], keyVerdicts: [:],
                                passwordVerdict: .failure, sentKeys: &k, sentPasswords: &p)
        XCTAssertEqual(out.attempts, [.password])
        XCTAssertEqual(out.result, .failure)
        XCTAssertEqual(p, [""])
    }

    func testIdentitiesWithoutStoredKeysAreSkippedThenPassword() async throws {
        var k: [String] = [], p: [String] = []
        let out = try await run(identities: [a, b], password: "", keys: [b: "KEY-B"],
                                keyVerdicts: [b: .failure],
                                sentKeys: &k, sentPasswords: &p)
        XCTAssertEqual(out.attempts, [.publickey(b)])
        XCTAssertEqual(out.skippedWithoutKey, [a])
        XCTAssertEqual(k, ["KEY-B"])
    }

    func testNoKeyOnDeviceForAnyIdentityTriesPasswordEvenIfEmpty() async throws {
        var k: [String] = [], p: [String] = []
        let out = try await run(identities: [a, b], password: "", keys: [:], keyVerdicts: [:],
                                passwordVerdict: .failure, sentKeys: &k, sentPasswords: &p)
        XCTAssertEqual(out, AuthSequenceOutcome(attempts: [.password], skippedWithoutKey: [a, b], result: .failure))
    }

    // Review fix: one bad key never aborts the sequence.

    func testKeychainErrorSkipsThatKeyAndTriesTheNext() async throws {
        var keysSent: [String] = []
        var reported: [UUID] = []
        let out = try await authenticateInOrder(
            identities: [a, b], password: "pw",
            loadKey: { id in
                if id == self.a { throw KeychainBroken.instance }
                return "KEY-B"
            },
            tryKey: { _, key in keysSent.append(key); return .success },
            tryPassword: { _ in XCTFail("password must not be needed"); return .failure },
            onKeyError: { id, error in
                reported.append(id)
                XCTAssertEqual(error as? KeychainBroken, .instance)
            })
        XCTAssertEqual(out, AuthSequenceOutcome(attempts: [.publickey(b)], skippedWithoutKey: [],
                                                keyErrors: [a], result: .success))
        XCTAssertEqual(keysSent, ["KEY-B"])
        XCTAssertEqual(reported, [a])
    }

    func testCorruptKeyThatThrowsOnUseFallsBackToPassword() async throws {
        var passwords: [String] = []
        let out = try await authenticateInOrder(
            identities: [a], password: "pw",
            loadKey: { _ in "GARBAGE" },
            tryKey: { _, _ in throw KeychainBroken.instance },   // e.g. "invalid private key"
            tryPassword: { pw in passwords.append(pw); return .success })
        XCTAssertEqual(out, AuthSequenceOutcome(attempts: [.publickey(a), .password], skippedWithoutKey: [],
                                                keyErrors: [a], result: .success))
        XCTAssertEqual(passwords, ["pw"])
    }

    func testEveryKeyErrorThenPasswordStillRuns() async throws {
        var passwords: [String] = []
        let out = try await authenticateInOrder(
            identities: [a, b], password: "pw",
            loadKey: { id in
                if id == self.a { throw KeychainBroken.instance }
                return "KEY-B"
            },
            tryKey: { _, _ in throw KeychainBroken.instance },
            tryPassword: { pw in passwords.append(pw); return .failure })
        XCTAssertEqual(out, AuthSequenceOutcome(attempts: [.publickey(b), .password], skippedWithoutKey: [],
                                                keyErrors: [a, b], result: .failure))
        XCTAssertEqual(passwords, ["pw"])
    }

    func testOnlyKeyErrorsAndNoPasswordRethrowsTheLastError() async {
        do {
            _ = try await authenticateInOrder(
                identities: [a], password: "",
                loadKey: { _ in "KEY" },
                tryKey: { _, _ in throw KeychainBroken.instance },
                tryPassword: { _ in XCTFail("no empty password after a key"); return .failure })
            XCTFail("expected the key error to propagate")
        } catch let e as KeychainBroken {
            XCTAssertEqual(e, .instance)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testKeyErrorThenRejectedKeyAndNoPasswordIsAPlainFailure() async throws {
        let out = try await authenticateInOrder(
            identities: [a, b], password: "",
            loadKey: { _ in "KEY" },
            tryKey: { id, _ in
                if id == self.a { throw KeychainBroken.instance }
                return .failure
            },
            tryPassword: { _ in XCTFail("no empty password after a key"); return .failure })
        XCTAssertEqual(out, AuthSequenceOutcome(attempts: [.publickey(a), .publickey(b)], skippedWithoutKey: [],
                                                keyErrors: [a], result: .failure))
    }

    func testPasswordErrorPropagates() async {
        do {
            _ = try await authenticateInOrder(
                identities: [], password: "pw",
                loadKey: { _ in nil },
                tryKey: { _, _ in .success },
                tryPassword: { _ in throw KeychainBroken.instance })
            XCTFail("expected the password error to propagate")
        } catch let e as KeychainBroken {
            XCTAssertEqual(e, .instance)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    private enum KeychainBroken: Error, Equatable { case instance }
}
