// Tests/NeotildeKitTests/TmuxLaunchTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class TmuxLaunchTests: XCTestCase {
    func testParseVersionVariants() {
        XCTAssertEqual(parseTmuxVersion("tmux 3.3a"), TmuxVersion(major: 3, minor: 3))
        XCTAssertEqual(parseTmuxVersion("tmux 3.4\n"), TmuxVersion(major: 3, minor: 4))
        XCTAssertEqual(parseTmuxVersion("tmux 2.9"), TmuxVersion(major: 2, minor: 9))
        XCTAssertEqual(parseTmuxVersion("tmux next-3.5"), TmuxVersion(major: 3, minor: 5))
        XCTAssertNil(parseTmuxVersion("bash: tmux: command not found"))
        XCTAssertNil(parseTmuxVersion(""))
    }

    func testSupportsControlModeBoundary() {
        XCTAssertFalse(tmuxSupportsControlMode(TmuxVersion(major: 2, minor: 9)))  // max-1 below floor
        XCTAssertTrue(tmuxSupportsControlMode(TmuxVersion(major: 3, minor: 0)))   // exact floor
        XCTAssertTrue(tmuxSupportsControlMode(TmuxVersion(major: 3, minor: 1)))
        XCTAssertFalse(tmuxSupportsControlMode(TmuxVersion(major: 1, minor: 9)))
    }

    func testLaunchDecisionPartitions() {
        XCTAssertEqual(tmuxLaunchDecision(attemptControlMode: false, versionProbe: "tmux 3.3a"), .degrade(.optedOut))
        XCTAssertEqual(tmuxLaunchDecision(attemptControlMode: true, versionProbe: nil), .degrade(.tmuxNotFound))
        XCTAssertEqual(tmuxLaunchDecision(attemptControlMode: true, versionProbe: "command not found"), .degrade(.tmuxNotFound))
        XCTAssertEqual(tmuxLaunchDecision(attemptControlMode: true, versionProbe: "tmux 2.9"),
                       .degrade(.tooOld(TmuxVersion(major: 2, minor: 9))))
        XCTAssertEqual(tmuxLaunchDecision(attemptControlMode: true, versionProbe: "tmux 3.0"), .attach)
    }

    func testSessionNameIsStableHexSlug() {
        let name = tmuxSessionName(seed: "device-abc")
        XCTAssertTrue(name.hasPrefix("neotilde-"))
        let hex = name.dropFirst("neotilde-".count)
        XCTAssertEqual(hex.count, 8)
        XCTAssertTrue(hex.allSatisfy { "0123456789abcdef".contains($0) })
        // Pin the exact digest so an algorithm swap (SHA-1/MD5) would fail:
        // SHA-256("device-abc") first 8 hex chars.
        XCTAssertEqual(name, "neotilde-068c3bfd")
        XCTAssertEqual(tmuxSessionName(seed: "device-abc"), name)             // deterministic
        XCTAssertNotEqual(tmuxSessionName(seed: "device-xyz"), name)          // seed-sensitive
    }
}
