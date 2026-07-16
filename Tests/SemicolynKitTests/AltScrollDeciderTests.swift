// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class AltScrollDeciderTests: XCTestCase {
    let reg = AltScrollRegistry.bundledDefault

    private func keys(_ mode: AltScrollMode, cmd: String?, title: String? = nil) -> AltScrollKeys {
        altScrollKeys(mode: mode, paneCommand: cmd, windowTitle: title, registry: reg)
    }

    // .off is always arrows, even for a registered app.
    func testOffAlwaysArrows() {
        XCTAssertEqual(keys(.off, cmd: "claude"), .arrows)
        XCTAssertEqual(keys(.off, cmd: "bash"), .arrows)
        XCTAssertEqual(keys(.off, cmd: nil), .arrows)
    }

    // .auto: page keys for a registered tmux app, arrows otherwise / when unknown.
    func testAutoUsesCommand() {
        XCTAssertEqual(keys(.auto, cmd: "claude"), .pageKeys)
        XCTAssertEqual(keys(.auto, cmd: "bash"), .arrows)
        XCTAssertEqual(keys(.auto, cmd: nil), .arrows)   // raw/mosh: no signal -> arrows
    }

    // .auto ignores the title entirely (title only matters in .autoPlusTitle).
    func testAutoIgnoresTitle() {
        XCTAssertEqual(keys(.auto, cmd: nil, title: "claude"), .arrows)
    }

    // .alwaysPageKeys: page keys regardless of app or signal.
    func testAlwaysPageKeys() {
        XCTAssertEqual(keys(.alwaysPageKeys, cmd: "claude"), .pageKeys)
        XCTAssertEqual(keys(.alwaysPageKeys, cmd: "bash"), .pageKeys)
        XCTAssertEqual(keys(.alwaysPageKeys, cmd: nil), .pageKeys)
    }

    // .autoPlusTitle: command wins when present; falls back to title when command is nil.
    func testAutoPlusTitle() {
        XCTAssertEqual(keys(.autoPlusTitle, cmd: "claude", title: nil), .pageKeys)   // command
        XCTAssertEqual(keys(.autoPlusTitle, cmd: nil, title: "myrepo - claude: x"), .pageKeys) // title
        XCTAssertEqual(keys(.autoPlusTitle, cmd: nil, title: "vim README"), .arrows) // no match
        XCTAssertEqual(keys(.autoPlusTitle, cmd: "bash", title: "claude"), .arrows)  // command wins (no match)
    }

    private func decide(_ mode: AltScrollMode, cmd: String?, title: String? = nil) -> AltScrollDecision {
        altScrollDecision(mode: mode, paneCommand: cmd, windowTitle: title, registry: reg)
    }

    // Decision carries the chosen keys AND a reason that cannot disagree with keys.
    func testDecisionOffArrowsWithReason() {
        let d = decide(.off, cmd: "claude")
        XCTAssertEqual(d.keys, .arrows)
        XCTAssertEqual(d.reason, "off")
        XCTAssertEqual(d.paneCommand, "claude")
        XCTAssertEqual(d.mode, .off)
    }

    func testDecisionAutoRegistered() {
        let d = decide(.auto, cmd: "claude")
        XCTAssertEqual(d.keys, .pageKeys)
        XCTAssertEqual(d.reason, "auto:registered")
    }

    func testDecisionAutoUnregistered() {
        let d = decide(.auto, cmd: "bash")
        XCTAssertEqual(d.keys, .arrows)
        XCTAssertEqual(d.reason, "auto:unregistered")
    }

    // Boundary: nil command in .auto vs .autoPlusTitle takes different branches.
    func testDecisionAutoNilCommandIsUnregistered() {
        let d = decide(.auto, cmd: nil, title: "claude")   // title ignored in .auto
        XCTAssertEqual(d.keys, .arrows)
        XCTAssertEqual(d.reason, "auto:unregistered")
    }

    func testDecisionAlwaysPageKeys() {
        let d = decide(.alwaysPageKeys, cmd: nil)
        XCTAssertEqual(d.keys, .pageKeys)
        XCTAssertEqual(d.reason, "alwaysPageKeys")
    }

    func testDecisionAutoPlusTitleUsesCmdBranch() {
        let d = decide(.autoPlusTitle, cmd: "claude", title: nil)
        XCTAssertEqual(d.keys, .pageKeys)
        XCTAssertEqual(d.reason, "autoPlusTitle:cmd")
    }

    func testDecisionAutoPlusTitleUsesTitleBranchWhenCmdNil() {
        let d = decide(.autoPlusTitle, cmd: nil, title: "myrepo - claude: x")
        XCTAssertEqual(d.keys, .pageKeys)
        XCTAssertEqual(d.reason, "autoPlusTitle:title")
    }

    // Negative: an unregistered command in .autoPlusTitle (cmd branch) does NOT become pageKeys.
    func testDecisionAutoPlusTitleCmdBranchNegative() {
        let d = decide(.autoPlusTitle, cmd: "bash", title: "claude")
        XCTAssertEqual(d.keys, .arrows)                 // cmd branch: bash unregistered
        XCTAssertEqual(d.reason, "autoPlusTitle:cmd")   // title NOT consulted (cmd present)
    }

    // logLine is self-contained: carries inputs + output + reason.
    func testDecisionLogLineSelfContained() {
        XCTAssertEqual(decide(.auto, cmd: "claude").logLine,
                       "mode=auto app=claude → keys=pageKeys reason=auto:registered")
    }

    func testDecisionLogLineNilCommand() {
        XCTAssertEqual(decide(.auto, cmd: nil).logLine,
                       "mode=auto app=nil → keys=arrows reason=auto:unregistered")
    }

    // Wrapper round-trip: altScrollKeys == altScrollDecision(...).keys for every mode.
    func testWrapperMatchesDecisionKeys() {
        for mode in AltScrollMode.allCases {
            for cmd in ["claude", "bash", nil] {
                XCTAssertEqual(
                    altScrollKeys(mode: mode, paneCommand: cmd, windowTitle: "claude", registry: reg),
                    altScrollDecision(mode: mode, paneCommand: cmd, windowTitle: "claude", registry: reg).keys,
                    "wrapper drifted for mode=\(mode) cmd=\(cmd ?? "nil")")
            }
        }
    }
}
