// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class PaneContextMachineTests: XCTestCase {
    private func machine() -> PaneContextMachine {
        PaneContextMachine(knownProcesses: ["vim", "python", "less"])
    }

    // MARK: engage dwell (250ms) — boundary values
    func testEngageFiresAtThresholdNotBefore() {
        var m = machine()
        XCTAssertFalse(m.observe("vim", at: 0.0))     // candidate starts
        XCTAssertNil(m.engagedContext)
        XCTAssertFalse(m.observe("vim", at: 0.24))    // 0.24 < 0.25 → not yet
        XCTAssertNil(m.engagedContext)
        XCTAssertTrue(m.observe("vim", at: 0.25))     // 0.25 >= 0.25 → engage, change=true
        XCTAssertEqual(m.engagedContext, "vim")
    }

    func testCandidateChangeRestartsEngageTimer() {
        var m = machine()
        _ = m.observe("vim", at: 0.0)
        _ = m.observe("python", at: 1.0)              // restart with new candidate at t=1.0
        XCTAssertFalse(m.observe("python", at: 1.24)) // 0.24 since restart (also proves it did NOT
        XCTAssertNil(m.engagedContext)                //   engage off the original 0.0 vim start)
        XCTAssertTrue(m.observe("python", at: 1.25))  // exactly 0.25 since restart → engage python
        XCTAssertEqual(m.engagedContext, "python")
    }

    func testUnknownProcessNeverEngages() {
        var m = machine()
        XCTAssertFalse(m.observe("awk", at: 0.0))
        XCTAssertFalse(m.observe("awk", at: 10.0))
        XCTAssertNil(m.engagedContext)
        XCTAssertEqual(m.currentProcess, "awk")
    }

    // MARK: disengage dwell (1500ms) — boundary values
    func testDisengageFiresAtThresholdNotBefore() {
        var m = machine()
        _ = m.observe("vim", at: 0.0); _ = m.observe("vim", at: 0.25)   // engaged
        XCTAssertFalse(m.observe("zsh", at: 10.0))  // away from vim → disengage timer starts
        XCTAssertEqual(m.engagedContext, "vim")
        XCTAssertFalse(m.observe("zsh", at: 11.49)) // 1.49 < 1.5 → still engaged
        XCTAssertEqual(m.engagedContext, "vim")
        XCTAssertTrue(m.observe("zsh", at: 11.5))   // 1.5 >= 1.5 → disengage, change=true
        XCTAssertNil(m.engagedContext)
    }

    func testTransientExcursionCancelsDisengage() {
        var m = machine()
        _ = m.observe("vim", at: 0.0); _ = m.observe("vim", at: 0.25)
        XCTAssertFalse(m.observe("bash", at: 10.0))  // :!ls excursion
        XCTAssertFalse(m.observe("vim", at: 10.5))   // back before 1.5s → cancel, no change
        XCTAssertEqual(m.engagedContext, "vim")
        XCTAssertFalse(m.observe("vim", at: 30.0))   // stays engaged
        XCTAssertEqual(m.engagedContext, "vim")
    }

    func testUnavailableSignalDecaysToNil() {
        var m = machine()
        _ = m.observe("vim", at: 0.0); _ = m.observe("vim", at: 0.25)
        XCTAssertFalse(m.observe(nil, at: 10.0))     // signal lost → disengage timer
        XCTAssertTrue(m.observe(nil, at: 11.6))      // > 1.5s later → decays to nil
        XCTAssertNil(m.engagedContext)
    }

    func testSwitchToNewKnownAppSupersedesViaFasterEngage() {
        var m = machine()
        _ = m.observe("vim", at: 0.0); _ = m.observe("vim", at: 0.25)   // engaged vim
        XCTAssertFalse(m.observe("python", at: 10.0)) // away from vim AND python candidate
        XCTAssertTrue(m.observe("python", at: 10.26)) // engage (0.25) beats disengage (1.5)
        XCTAssertEqual(m.engagedContext, "python")
    }

    func testUnknownProcessWhileEngagedDecaysAfterDisengageDwell() {
        var m = machine()
        _ = m.observe("vim", at: 0.0); _ = m.observe("vim", at: 0.25)  // engaged vim
        XCTAssertFalse(m.observe("awk", at: 10.0))   // unknown → disengage timer starts, still engaged
        XCTAssertEqual(m.engagedContext, "vim")
        XCTAssertFalse(m.observe("awk", at: 11.4))   // 1.4 < 1.5 → still engaged
        XCTAssertEqual(m.engagedContext, "vim")
        XCTAssertTrue(m.observe("awk", at: 11.5))    // exactly 1.5 → disengage to nil
        XCTAssertNil(m.engagedContext)
    }
}
