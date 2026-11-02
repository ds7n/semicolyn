// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// `KeyAccessGate` (security audit H1): when an identity's key needs a fresh
/// Face ID / passcode check.
final class KeyAccessGateTests: XCTestCase {
    // EP: one representative per policy on a fresh gate (app just launched).
    func testFreshGatePerPolicy() {
        let gate = KeyAccessGate()
        XCTAssertFalse(gate.needsCheck(.never))
        XCTAssertTrue(gate.needsCheck(.afterUnlock))
        XCTAssertTrue(gate.needsCheck(.anyUse))
    }

    // Adversarial: missing identity metadata fails closed.
    func testUnknownPolicyAlwaysChecks() {
        var gate = KeyAccessGate()
        gate.recordVerified(period: gate.period)
        XCTAssertTrue(gate.needsCheck(nil))
    }

    // Once per unlock: a passed check covers later uses until the device locks.
    func testAfterUnlockVerifiedOnceThenFree() {
        var gate = KeyAccessGate()
        gate.recordVerified(period: gate.period)
        XCTAssertFalse(gate.needsCheck(.afterUnlock))
        XCTAssertFalse(gate.needsCheck(.afterUnlock))
    }

    // Every use: a passed check never carries over.
    func testAnyUseAlwaysChecksEvenAfterVerified() {
        var gate = KeyAccessGate()
        gate.recordVerified(period: gate.period)
        XCTAssertTrue(gate.needsCheck(.anyUse))
    }

    // Never: a lock does not start checking.
    func testNeverStaysFreeAcrossLocks() {
        var gate = KeyAccessGate()
        gate.endPeriod()
        XCTAssertFalse(gate.needsCheck(.never))
    }

    // A device lock ends the verified period.
    func testDeviceLockRequiresCheckAgain() {
        var gate = KeyAccessGate()
        gate.recordVerified(period: gate.period)
        gate.endPeriod()
        XCTAssertTrue(gate.needsCheck(.afterUnlock))
        XCTAssertEqual(gate.period, 1)
    }

    // Re-verifying after a lock covers the new unlock period.
    func testReverifyAfterLock() {
        var gate = KeyAccessGate()
        gate.recordVerified(period: gate.period)
        gate.endPeriod()
        gate.recordVerified(period: gate.period)
        XCTAssertFalse(gate.needsCheck(.afterUnlock))
    }

    // Adversarial (replay of a stale check): a check that began before a lock and passed
    // after it does not verify the new unlock period.
    func testStaleCheckAcrossLockIsIgnored() {
        var gate = KeyAccessGate()
        let started = gate.period
        gate.endPeriod()
        gate.recordVerified(period: started)
        XCTAssertTrue(gate.needsCheck(.afterUnlock))
    }

    // EP + BVA over every (old, new) pair: only weakening needs a check.
    func testPolicyChangeNeedsCheckOnlyWhenWeakening() {
        let all: [BiometricPolicy] = [.never, .afterUnlock, .anyUse]
        var needing: [String] = []
        for old in all {
            for new in all where biometricPolicyChangeNeedsCheck(from: old, to: new) {
                needing.append("\(old)->\(new)")
            }
        }
        XCTAssertEqual(needing, ["afterUnlock->never", "anyUse->never", "anyUse->afterUnlock"])
    }

    // Each refusal reads as its own message naming the key.
    func testErrorMessagesNameTheKey() {
        XCTAssertEqual(KeyAccessError.cancelled(identityName: "work").errorDescription,
                       "Authentication cancelled for key \u{201C}work\u{201D}.")
        XCTAssertEqual(KeyAccessError.failed(identityName: "work").errorDescription,
                       "Couldn't verify it's you, so key \u{201C}work\u{201D} wasn't used.")
        XCTAssertEqual(KeyAccessError.unavailable(identityName: "work").errorDescription,
                       "Key \u{201C}work\u{201D} requires Face ID, Touch ID or a passcode, "
                       + "and none is set up on this device. Change the key's setting under Identities & Keys.")
    }
}
