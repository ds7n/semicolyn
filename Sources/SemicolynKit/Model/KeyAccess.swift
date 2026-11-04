// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Decides when using an identity's private key needs a fresh Face ID / Touch ID /
/// passcode check (the identity's `BiometricPolicy`). The App owns one instance, asks
/// `needsCheck` before each key use, reports a passed check with `recordVerified`, and
/// calls `endPeriod` when the device locks or the app leaves the foreground.
///
/// `afterUnlock` ("Once per Unlock"): one passed check covers every `afterUnlock` identity
/// until the period ends (or the app restarts, which starts unverified). iOS does not
/// tell a suspended app that the device locked, so besides a lock seen while running,
/// the period also ends when the app returns from `backgroundGrace` or more in the
/// background. A shorter absence can only hide a lock the owner then undid with Face ID
/// or the passcode. `anyUse` ("Every Use") checks every time. `never` never checks.
public struct KeyAccessGate: Equatable, Sendable {
    /// Counts ended periods. A check records against the period it STARTED in, so a lock
    /// that lands while the prompt is up never leaves the next period verified.
    public private(set) var period = 0
    private var verifiedPeriod: Int?

    public init() {}

    /// Whether a key with `policy` needs a check now. A nil policy (the identity's
    /// metadata is missing) fails closed: it always checks.
    public func needsCheck(_ policy: BiometricPolicy?) -> Bool {
        switch policy {
        case .never: return false
        case .afterUnlock: return verifiedPeriod != period
        case .anyUse, nil: return true
        }
    }

    /// A check that began in `period` passed.
    public mutating func recordVerified(period started: Int) {
        guard started == period else { return }
        verifiedPeriod = started
    }

    /// Background time after which a return to the foreground ends the period (5 min).
    public static let backgroundGrace: Double = 300

    /// The device locked: the next `afterUnlock` key use checks again.
    public mutating func endPeriod() {
        period += 1
    }

    /// The app is back in the foreground after `awaySeconds` in the background. Ends the
    /// period at `backgroundGrace` or more, or for a negative span (the clock moved back:
    /// fail closed).
    public mutating func returnedToForeground(awaySeconds: Double) {
        guard awaySeconds >= Self.backgroundGrace || awaySeconds < 0 else { return }
        endPeriod()
    }
}

/// Of `identities`, the one whose policy is strictest (`anyUse` over `afterUnlock`; the
/// first on a tie), or nil when none needs a check. Gates a Mosh resume, which reattaches
/// without SSH auth and so never reaches the per-key check.
public func strictestProtectedIdentity(_ identities: [Identity]) -> Identity? {
    var best: Identity?
    for identity in identities where identity.biometricPolicy != .never {
        if identity.biometricPolicy.strength > (best?.biometricPolicy.strength ?? 0) { best = identity }
    }
    return best
}

extension BiometricPolicy {
    /// Stronger policies check more often: `never` < `afterUnlock` < `anyUse`.
    var strength: Int {
        switch self {
        case .never: return 0
        case .afterUnlock: return 1
        case .anyUse: return 2
        }
    }
}

/// Whether changing a key's policy from `old` to `new` needs the owner verified first.
/// Weakening does (otherwise anyone holding the unlocked phone could switch "Every Use"
/// off and connect); keeping or strengthening does not.
public func biometricPolicyChangeNeedsCheck(from old: BiometricPolicy, to new: BiometricPolicy) -> Bool {
    new.strength < old.strength
}

/// A key the identity's policy protects could not be used. Thrown from the auth
/// sequence's `loadKey`; unlike a Keychain read error it ENDS the sequence (no later key
/// or password is tried), because the user said no or the device can't ask.
public enum KeyAccessError: Error, Equatable, Sendable, LocalizedError {
    /// The user cancelled the Face ID / passcode prompt.
    case cancelled(identityName: String)
    /// The device has no passcode (so no Face ID / Touch ID either): the check can't run.
    case unavailable(identityName: String)
    /// The check ran and did not pass (for example biometry locked out).
    case failed(identityName: String)

    public var errorDescription: String? {
        switch self {
        case let .cancelled(name):
            return "Authentication cancelled for key \u{201C}\(name)\u{201D}."
        case let .unavailable(name):
            return "Key \u{201C}\(name)\u{201D} requires Face ID, Touch ID or a passcode, "
                + "and none is set up on this device. Change the key's setting under Identities & Keys."
        case let .failed(name):
            return "Couldn't verify it's you, so key \u{201C}\(name)\u{201D} wasn't used."
        }
    }
}
