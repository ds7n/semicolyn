// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import LocalAuthentication
import UIKit
import SemicolynKit

/// Enforces each identity's "Require Face ID" policy (security audit H1) with a
/// LocalAuthentication check (Face ID / Touch ID, falling back to the device passcode)
/// before its private key is used. The decision is Kit's `KeyAccessGate`; this class runs
/// the system prompt and ends the "Once per Unlock" period when the device locks or the
/// app leaves the foreground.
///
/// App-level rather than a Keychain `SecAccessControl`: keys sync through iCloud Keychain
/// (a locked decision), and synchronizable items can't carry a biometric access control.
@MainActor
final class KeyAccessAuthorizer {
    static let shared = KeyAccessAuthorizer()

    private var gate = KeyAccessGate()
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        for name in [UIApplication.protectedDataWillBecomeUnavailableNotification,
                     UIApplication.didEnterBackgroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.endPeriod(reason: note.name.rawValue) }
            })
        }
    }

    /// Check the owner if `identityID`'s policy needs it now. Returns normally when the
    /// key may be used.
    ///
    /// - Throws: `KeyAccessError` when the check is cancelled, fails or can't run.
    func authorizeKeyUse(identityID: UUID) async throws {
        let identity = try? AppStores.shared.hosts.identity(id: identityID)
        let policy = identity?.biometricPolicy
        let needed = gate.needsCheck(policy)
        DebugLog.shared.log(.connect, decisionLine(
            "keyAccess",
            inputs: [("identity", "\(identityID)"), ("policy", policy.map { "\($0)" } ?? "unknown")],
            outputs: [("check", "\(needed)")],
            reason: nil))
        guard needed else { return }
        let started = gate.period
        try await verifyOwner(identityName: identity?.displayName ?? "SSH key",
                              reason: "Sign in with \u{201C}\(identity?.displayName ?? "SSH key")\u{201D}")
        gate.recordVerified(period: started)
    }

    /// Run the Face ID / Touch ID / passcode prompt once.
    ///
    /// - Throws: `KeyAccessError.cancelled` (user or system cancelled), `.unavailable`
    ///   (no passcode on this device) or `.failed` (anything else, e.g. lockout).
    func verifyOwner(identityName: String, reason: String) async throws {
        let context = LAContext()
        var canError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &canError) else {
            let code = canError.flatMap { LAError.Code(rawValue: $0.code) }
            DebugLog.shared.log(.connect, "keyAccess: cannot evaluate code=\(canError?.code ?? 0)")
            throw code == .passcodeNotSet ? KeyAccessError.unavailable(identityName: identityName)
                                          : KeyAccessError.failed(identityName: identityName)
        }
        let result = await Self.evaluate(context, reason: reason, identityName: identityName)
        DebugLog.shared.log(.connect, "keyAccess: prompt -> \(result)")
        try result.get()
    }

    private func endPeriod(reason: String) {
        gate.endPeriod()
        DebugLog.shared.log(.connect, "keyAccess: period ended reason=\(reason)")
    }

    /// Nonisolated so the reply closure is not main-actor isolated: LocalAuthentication
    /// calls it on a private queue (the @MainActor callback trap).
    nonisolated private static func evaluate(_ context: LAContext, reason: String,
                                             identityName: String) async -> Result<Void, KeyAccessError> {
        await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, error in
                if ok { return continuation.resume(returning: .success(())) }
                continuation.resume(returning: .failure(keyAccessError(error, identityName: identityName)))
            }
        }
    }

    nonisolated private static func keyAccessError(_ error: (any Error)?, identityName: String) -> KeyAccessError {
        switch (error as? LAError)?.code {
        case .userCancel, .appCancel, .systemCancel, .userFallback:
            return .cancelled(identityName: identityName)
        case .passcodeNotSet:
            return .unavailable(identityName: identityName)
        default:
            return .failed(identityName: identityName)
        }
    }
}
