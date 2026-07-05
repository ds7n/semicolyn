// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Critical-tier: L6 is the format-agnostic backstop — a token that graduates too
/// early could persist a once-typed secret. Tests pin the exact N boundary
/// (N−1 defers, N graduates), distinct-context counting, and the backfill.
final class GraduationTierTests: XCTestCase {

    func testBelowThresholdDefers() {
        var t = GraduationTier(threshold: 3)
        // Two distinct contexts (< 3) → nothing graduates yet.
        XCTAssertEqual(t.admit(token: "deploy", previous: "git", count: 1, confidence: .high), [])
        XCTAssertEqual(t.admit(token: "deploy", previous: "make", count: 1, confidence: .high), [])
    }

    func testGraduatesOnNthDistinctContextWithBackfill() {
        var t = GraduationTier(threshold: 3)
        _ = t.admit(token: "deploy", previous: "git", count: 1, confidence: .high)     // ctx 1
        _ = t.admit(token: "deploy", previous: "make", count: 2, confidence: .high)    // ctx 2
        // ctx 3 → graduate; backfill ALL accumulated occurrences (incl. this one).
        let flushed = t.admit(token: "deploy", previous: "npm", count: 1, confidence: .high)
        // Order-independent: assert the SET of occurrences.
        XCTAssertEqual(
            Set(flushed),
            Set([
                GraduatedOccurrence(token: "deploy", previous: "git", count: 1, confidence: .high),
                GraduatedOccurrence(token: "deploy", previous: "make", count: 2, confidence: .high),
                GraduatedOccurrence(token: "deploy", previous: "npm", count: 1, confidence: .high),
            ]))
    }

    func testCountAccumulatesOnRepeatedNonNilContext() {
        // A distinct non-nil context repeated accumulates its count (same code path
        // as the nil accumulation, exercised here on the non-nil branch): "deploy"
        // after "git" twice (5+3) then two more distinct contexts to graduate → the
        // "git" backfill entry must carry the accumulated count 8.
        var t = GraduationTier(threshold: 3)
        _ = t.admit(token: "deploy", previous: "git", count: 5, confidence: .high)
        _ = t.admit(token: "deploy", previous: "git", count: 3, confidence: .high)   // same ctx → count 8, still 1 distinct
        _ = t.admit(token: "deploy", previous: "make", count: 1, confidence: .high)  // ctx 2
        let flushed = t.admit(token: "deploy", previous: "npm", count: 1, confidence: .high)   // ctx 3 → graduate
        XCTAssertTrue(flushed.contains(GraduatedOccurrence(token: "deploy", previous: "git", count: 8, confidence: .high)))
    }

    func testSameNonNilContextReplayedDoesNotGraduate() {
        var t = GraduationTier(threshold: 3)
        // The SAME (token, NON-nil previous) three times = ONE distinct context and
        // nilCount stays 0 → defer. A password re-typed at the same `sudo` prompt
        // never graduates — the core secret-protection guarantee of L6.
        XCTAssertEqual(t.admit(token: "pw", previous: "sudo", count: 1, confidence: .high), [])
        XCTAssertEqual(t.admit(token: "pw", previous: "sudo", count: 1, confidence: .high), [])
        XCTAssertEqual(t.admit(token: "pw", previous: "sudo", count: 1, confidence: .high), [])
    }

    func testRepeatedStartOfLineGraduatesViaNilCount() {
        var t = GraduationTier(threshold: 3)
        // A bare command typed repeatedly at the prompt (all previous=nil): the
        // nilCount reaches N on the 3rd → graduate (utility for reused commands).
        XCTAssertEqual(t.admit(token: "ls", previous: nil, count: 1, confidence: .high), [])   // nilCount 1
        XCTAssertEqual(t.admit(token: "ls", previous: nil, count: 1, confidence: .high), [])   // nilCount 2
        let flushed = t.admit(token: "ls", previous: nil, count: 1, confidence: .high)         // nilCount 3 → graduate
        // Backfill is the single accumulated nil context with count 3.
        XCTAssertEqual(flushed, [GraduatedOccurrence(token: "ls", previous: nil, count: 3, confidence: .high)])
    }

    func testTwoStartOfLineOccurrencesDoNotGraduate() {
        var t = GraduationTier(threshold: 3)
        // Boundary N−1: two nil occurrences is below the nilCount threshold.
        XCTAssertEqual(t.admit(token: "ls", previous: nil, count: 1, confidence: .high), [])
        XCTAssertEqual(t.admit(token: "ls", previous: nil, count: 1, confidence: .high), [])   // nilCount 2 < 3
    }

    func testNilPreviousIsOneDistinctContext() {
        var t = GraduationTier(threshold: 3)
        _ = t.admit(token: "ls", previous: nil, count: 1, confidence: .high)           // ctx nil
        _ = t.admit(token: "ls", previous: "then", count: 1, confidence: .high)        // ctx "then"
        let flushed = t.admit(token: "ls", previous: "also", count: 1, confidence: .high)   // ctx "also" → graduate
        XCTAssertEqual(flushed.count, 3)
        XCTAssertTrue(flushed.contains(GraduatedOccurrence(token: "ls", previous: nil, count: 1, confidence: .high)))
    }

    func testAlreadyGraduatedRecordsDirectly() {
        var t = GraduationTier(threshold: 3)
        _ = t.admit(token: "deploy", previous: "git", count: 1, confidence: .high)
        _ = t.admit(token: "deploy", previous: "make", count: 1, confidence: .high)
        _ = t.admit(token: "deploy", previous: "npm", count: 1, confidence: .high)     // graduates
        // Post-graduation: each occurrence passes straight through, no backfill.
        XCTAssertEqual(
            t.admit(token: "deploy", previous: "yarn", count: 5, confidence: .high),
            [GraduatedOccurrence(token: "deploy", previous: "yarn", count: 5, confidence: .high)])
    }

    func testResetClearsEphemeralState() {
        var t = GraduationTier(threshold: 3)
        _ = t.admit(token: "deploy", previous: "git", count: 1, confidence: .high)
        _ = t.admit(token: "deploy", previous: "make", count: 1, confidence: .high)
        t.reset()
        // After reset, prior contexts are gone — the third distinct context alone
        // does NOT graduate (count restarts).
        XCTAssertEqual(t.admit(token: "deploy", previous: "npm", count: 1, confidence: .high), [])
    }

    func testBoundEvictsOldestPendingToken() {
        var t = GraduationTier(threshold: 3, maxTracked: 2)
        _ = t.admit(token: "a", previous: "x", count: 1, confidence: .high)   // pending {a}
        _ = t.admit(token: "b", previous: "x", count: 1, confidence: .high)   // pending {a,b}
        _ = t.admit(token: "c", previous: "x", count: 1, confidence: .high)   // inserts c → evicts a (oldest)
        // "a" was evicted: its single prior context is gone, so re-admitting two more
        // distinct contexts for "a" is only 2 → still defers (proves eviction happened).
        _ = t.admit(token: "a", previous: "y", count: 1, confidence: .high)   // a: {y}
        XCTAssertEqual(t.admit(token: "a", previous: "z", count: 1, confidence: .high), [])  // a: {y,z} = 2 < 3
    }

    func testAdmitStampsConfidenceOnGraduation() {
        var tier = GraduationTier(threshold: 3)
        // Three distinct contexts → graduates; every backfilled occurrence carries .low.
        _ = tier.admit(token: "deploy", previous: "run", count: 1, confidence: .low)
        _ = tier.admit(token: "deploy", previous: "make", count: 1, confidence: .low)
        let flushed = tier.admit(token: "deploy", previous: "just", count: 1, confidence: .low)
        XCTAssertEqual(flushed.count, 3)
        XCTAssertTrue(flushed.allSatisfy { $0.confidence == .low })
        XCTAssertEqual(Set(flushed.map(\.previous)), ["run", "make", "just"])
    }

    func testAdmitPostGraduationPassesThroughConfidence() {
        var tier = GraduationTier(threshold: 1)
        _ = tier.admit(token: "ls", previous: nil, count: 1, confidence: .high)  // graduates now
        let after = tier.admit(token: "ls", previous: "sudo", count: 1, confidence: .high)
        XCTAssertEqual(after, [GraduatedOccurrence(token: "ls", previous: "sudo", count: 1, confidence: .high)])
    }

    // MARK: - forget-last-line (Task 6)

    func testForgetLastLineReversesPendingContribution() {
        var tier = GraduationTier(threshold: 3)
        tier.beginLine()
        _ = tier.admit(token: "passw0rd", previous: "sudo", count: 1, confidence: .low)
        _ = tier.admit(token: "passw0rd", previous: "sudo", count: 1, confidence: .low)
        tier.forgetLastLine()   // reverse this line's pending increments
        // The token's pending count is gone → it must start from scratch to graduate.
        tier.beginLine()
        let a = tier.admit(token: "passw0rd", previous: "a", count: 1, confidence: .low)
        let b = tier.admit(token: "passw0rd", previous: "b", count: 1, confidence: .low)
        let c = tier.admit(token: "passw0rd", previous: "c", count: 1, confidence: .low)
        XCTAssertTrue(a.isEmpty && b.isEmpty)
        XCTAssertEqual(c.count, 3, "3 fresh distinct contexts graduate; the forgotten ones did not persist")
    }

    func testForgetLastLineDoesNotTouchGraduatedToken() {
        var tier = GraduationTier(threshold: 1)
        tier.beginLine()
        let flushed = tier.admit(token: "ls", previous: nil, count: 1, confidence: .high)  // graduates now
        XCTAssertEqual(flushed.count, 1)
        tier.forgetLastLine()
        // Already graduated → still graduated; a further admit passes straight through.
        let after = tier.admit(token: "ls", previous: "x", count: 1, confidence: .high)
        XCTAssertEqual(after, [GraduatedOccurrence(token: "ls", previous: "x", count: 1, confidence: .high)])
    }
}
