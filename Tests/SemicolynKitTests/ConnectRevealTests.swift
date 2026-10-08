// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ConnectRevealTests: XCTestCase {
    /// The "nothing has happened yet" input: launch just typed, no signal of any kind.
    private func base(sentinelSeen: Bool = false,
                      secondsSinceLastOutput: Double? = nil,
                      mouseModeOn: Bool = false,
                      tmuxMissing: Bool = false,
                      sessionEnded: Bool = false,
                      secondsSinceLaunch: Double = 0.5) -> ConnectRevealInput {
        ConnectRevealInput(sentinelSeen: sentinelSeen,
                           secondsSinceLastOutput: secondsSinceLastOutput,
                           mouseModeOn: mouseModeOn,
                           tmuxMissing: tmuxMissing,
                           sessionEnded: sessionEnded,
                           secondsSinceLaunch: secondsSinceLaunch)
    }

    // MARK: - Constants

    func testConstantsAreTheApprovedValues() {
        XCTAssertEqual(connectRevealQuietSeconds, 0.15)
        XCTAssertEqual(connectRevealTimeoutSeconds, 3.0)
    }

    // MARK: - Keep covering (nil)

    func testNoSignalKeepsCovering() {
        XCTAssertNil(connectRevealDecision(base()))
    }

    func testLaunchInstantKeepsCovering() {
        XCTAssertNil(connectRevealDecision(base(secondsSinceLaunch: 0)))
    }

    func testSentinelSeenButOutputStillArrivingKeepsCovering() {
        XCTAssertNil(connectRevealDecision(base(sentinelSeen: true, secondsSinceLastOutput: 0.01)))
    }

    func testQuietWithoutSentinelKeepsCovering() {
        // Long quiet but the launch never ran (no sentinel): the shell is still showing.
        XCTAssertNil(connectRevealDecision(base(sentinelSeen: false, secondsSinceLastOutput: 2.0)))
    }

    /// Documented choice: sentinel seen but NO output after it (nil) keeps covering. The
    /// silence right after the sentinel is the launch script's tmux spawns (the stall the
    /// overlay exists to hide), so it must not count as "tmux painted and went quiet".
    /// The timeout is the backstop.
    func testSentinelSeenWithNoOutputAfterItKeepsCovering() {
        XCTAssertNil(connectRevealDecision(base(sentinelSeen: true, secondsSinceLastOutput: nil,
                                                secondsSinceLaunch: 2.9)))
    }

    func testSentinelSeenWithNoOutputAfterItRevealsOnlyAtTimeout() {
        XCTAssertEqual(connectRevealDecision(base(sentinelSeen: true, secondsSinceLastOutput: nil,
                                                  secondsSinceLaunch: 3.0)), .timeout)
    }

    // MARK: - Each reason alone

    func testSessionEndedAlone() {
        XCTAssertEqual(connectRevealDecision(base(sessionEnded: true)), .sessionEnded)
    }

    func testTmuxMissingAlone() {
        XCTAssertEqual(connectRevealDecision(base(tmuxMissing: true)), .tmuxMissing)
    }

    func testMouseModeAlone() {
        XCTAssertEqual(connectRevealDecision(base(mouseModeOn: true)), .mouseMode)
    }

    func testSentinelQuietAlone() {
        XCTAssertEqual(connectRevealDecision(base(sentinelSeen: true, secondsSinceLastOutput: 0.2)),
                       .sentinelQuiet)
    }

    func testTimeoutAlone() {
        XCTAssertEqual(connectRevealDecision(base(secondsSinceLaunch: 3.5)), .timeout)
    }

    // MARK: - Boundaries

    func testQuietJustBelowThresholdKeepsCovering() {
        XCTAssertNil(connectRevealDecision(base(sentinelSeen: true, secondsSinceLastOutput: 0.149)))
    }

    func testQuietAtThresholdReveals() {
        XCTAssertEqual(connectRevealDecision(base(sentinelSeen: true, secondsSinceLastOutput: 0.15)),
                       .sentinelQuiet)
    }

    func testTimeoutJustBelowThresholdKeepsCovering() {
        XCTAssertNil(connectRevealDecision(base(secondsSinceLaunch: 2.999)))
    }

    func testTimeoutAtThresholdReveals() {
        XCTAssertEqual(connectRevealDecision(base(secondsSinceLaunch: 3.0)), .timeout)
    }

    // MARK: - Precedence (sessionEnded > tmuxMissing > mouseMode > sentinelQuiet > timeout)

    func testSessionEndedBeatsEverything() {
        XCTAssertEqual(connectRevealDecision(base(sentinelSeen: true, secondsSinceLastOutput: 1.0,
                                                  mouseModeOn: true, tmuxMissing: true,
                                                  sessionEnded: true, secondsSinceLaunch: 5.0)),
                       .sessionEnded)
    }

    func testTmuxMissingBeatsMouseQuietAndTimeout() {
        XCTAssertEqual(connectRevealDecision(base(sentinelSeen: true, secondsSinceLastOutput: 1.0,
                                                  mouseModeOn: true, tmuxMissing: true,
                                                  secondsSinceLaunch: 5.0)),
                       .tmuxMissing)
    }

    func testMouseModeBeatsQuietAndTimeout() {
        XCTAssertEqual(connectRevealDecision(base(sentinelSeen: true, secondsSinceLastOutput: 1.0,
                                                  mouseModeOn: true, secondsSinceLaunch: 5.0)),
                       .mouseMode)
    }

    func testSentinelQuietBeatsTimeout() {
        XCTAssertEqual(connectRevealDecision(base(sentinelSeen: true, secondsSinceLastOutput: 1.0,
                                                  secondsSinceLaunch: 5.0)),
                       .sentinelQuiet)
    }

    // MARK: - Reason raw values (they appear verbatim in device logs)

    func testReasonRawValues() {
        XCTAssertEqual(ConnectRevealReason.mouseMode.rawValue, "mouseMode")
        XCTAssertEqual(ConnectRevealReason.sentinelQuiet.rawValue, "sentinelQuiet")
        XCTAssertEqual(ConnectRevealReason.tmuxMissing.rawValue, "tmuxMissing")
        XCTAssertEqual(ConnectRevealReason.sessionEnded.rawValue, "sessionEnded")
        XCTAssertEqual(ConnectRevealReason.timeout.rawValue, "timeout")
    }

    // MARK: - Log line

    func testLogLineWithQuietMeasurement() {
        let input = base(sentinelSeen: true, secondsSinceLastOutput: 0.2, secondsSinceLaunch: 0.934)
        XCTAssertEqual(connectRevealLogLine(input, reason: .sentinelQuiet),
                       "connect:reveal sentinel=true quiet=0.20 mouse=false missing=false ended=false"
                       + " → after=0.93s reason=sentinelQuiet")
    }

    func testLogLineWithNilQuietPrintsNil() {
        let input = base(mouseModeOn: true, secondsSinceLaunch: 1.5)
        XCTAssertEqual(connectRevealLogLine(input, reason: .mouseMode),
                       "connect:reveal sentinel=false quiet=nil mouse=true missing=false ended=false"
                       + " → after=1.50s reason=mouseMode")
    }
}
