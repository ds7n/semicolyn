// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The result of one SSH authentication attempt, mirroring the Rust core's
/// `AuthOutcome` so the ordering logic below can live (and be tested) here
/// without the UniFFI bridge.
public enum AuthAttemptResult: Equatable, Sendable {
    /// Authentication fully succeeded; the session is usable.
    case success
    /// The method was accepted but the server wants a further method (MFA).
    case partialSuccess
    /// The method was rejected.
    case failure
}

/// One step `authenticateInOrder` performed, in order. Returned so the caller
/// can log the sequence and tests can assert on it.
public enum AuthAttempt: Equatable, Sendable {
    /// A public-key attempt with this identity's private key.
    case publickey(IdentityRef)
    /// A password attempt.
    case password
}

/// What `authenticateInOrder` did and how it ended.
public struct AuthSequenceOutcome: Equatable, Sendable {
    /// Every attempt made, in order.
    public var attempts: [AuthAttempt]
    /// Identities skipped because their private key is not on this device.
    public var skippedWithoutKey: [IdentityRef]
    /// The final result: `.success` as soon as any attempt succeeds, otherwise
    /// the result of the last attempt made (`.failure` when nothing was tried).
    public var result: AuthAttemptResult

    public init(attempts: [AuthAttempt], skippedWithoutKey: [IdentityRef], result: AuthAttemptResult) {
        self.attempts = attempts
        self.skippedWithoutKey = skippedWithoutKey
        self.result = result
    }
}

/// Authenticate by trying each resolved identity's key in order, then the
/// password.
///
/// - Each identity whose private key is on this device (`loadKey` returns
///   non-nil) is tried with `tryKey`, in the order given. The first `.success`
///   ends the sequence. A rejected key (or a key the server only partially
///   accepts) moves on to the next identity.
/// - An identity with no stored key (`loadKey` returns nil) is skipped.
/// - After the keys, the password is tried with `tryPassword`. When at least one
///   key was attempted, an empty password is NOT sent (it cannot succeed and
///   only spends one of the server's limited auth attempts); with no key
///   attempted the password is always tried, as before, so a host with no key
///   behaves exactly as it did.
///
/// A genuine `loadKey` error (for example a Keychain read failure) or a thrown
/// attempt aborts the sequence and propagates: only a truly absent key is skipped.
public func authenticateInOrder(
    identities: [IdentityRef],
    password: String,
    loadKey: (IdentityRef) throws -> String?,
    tryKey: (IdentityRef, String) async throws -> AuthAttemptResult,
    tryPassword: (String) async throws -> AuthAttemptResult,
    isolation: isolated (any Actor)? = #isolation
) async throws -> AuthSequenceOutcome {
    var attempts: [AuthAttempt] = []
    var skipped: [IdentityRef] = []
    var last: AuthAttemptResult = .failure
    for id in identities {
        guard let key = try loadKey(id) else {
            skipped.append(id)
            continue
        }
        attempts.append(.publickey(id))
        last = try await tryKey(id, key)
        if last == .success {
            return AuthSequenceOutcome(attempts: attempts, skippedWithoutKey: skipped, result: .success)
        }
    }
    let triedKey = !attempts.isEmpty
    if triedKey && password.isEmpty {
        return AuthSequenceOutcome(attempts: attempts, skippedWithoutKey: skipped, result: last)
    }
    attempts.append(.password)
    last = try await tryPassword(password)
    return AuthSequenceOutcome(attempts: attempts, skippedWithoutKey: skipped, result: last)
}
