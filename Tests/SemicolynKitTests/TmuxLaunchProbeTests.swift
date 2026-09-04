// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class TmuxLaunchProbeTests: XCTestCase {
    // --- .tmuxMissing: one representative per shell family (EP) ---
    func testBashCommandNotFoundIsMissing() {
        XCTAssertEqual(classifyTmuxLaunch(output: "bash: tmux: command not found\n"), .tmuxMissing)
    }
    func testZshWordOrderIsMissing() {
        XCTAssertEqual(classifyTmuxLaunch(output: "zsh: command not found: tmux\n"), .tmuxMissing)
    }
    func testShDashNotFoundIsMissing() {
        XCTAssertEqual(classifyTmuxLaunch(output: "sh: tmux: not found\n"), .tmuxMissing)
    }
    func testBusyboxNotFoundIsMissing() {
        XCTAssertEqual(classifyTmuxLaunch(output: "/bin/sh: tmux: not found\n"), .tmuxMissing)
    }

    // --- .tmuxStarted: alt-screen enter (tmux takes the alt-screen on attach) ---
    func testAltScreenEnterIsStarted() {
        // ESC [ ? 1049 h
        XCTAssertEqual(classifyTmuxLaunch(output: "\u{1B}[?1049h\u{1B}[1;1H"), .tmuxStarted)
    }
    func testLegacyAltScreen1047IsStarted() {
        XCTAssertEqual(classifyTmuxLaunch(output: "\u{1B}[?1047h"), .tmuxStarted)
    }

    // --- .inconclusive: normal / benign output, NEVER a false .tmuxMissing (adversarial) ---
    func testNormalPromptIsInconclusive() {
        XCTAssertEqual(classifyTmuxLaunch(output: "user@host:~$ "), .inconclusive)
    }
    func testBenignTmuxMentionIsInconclusive() {
        // the word tmux appearing in unrelated text must NOT trip missing
        XCTAssertEqual(classifyTmuxLaunch(output: "starting tmux session now\n"), .inconclusive)
    }
    func testFilenameContainingNotFoundIsInconclusive() {
        // "command not found" as data, not a shell diagnostic naming tmux
        XCTAssertEqual(classifyTmuxLaunch(output: "cat: command-not-found.log: No such file\n"), .inconclusive)
    }
    func testHyphenatedNotFoundWithTmuxIsInconclusive() {
        // tmux: command-not-found.log missing; contains "tmux:" but NOT "tmux: command not found"
        XCTAssertEqual(classifyTmuxLaunch(output: "tmux: command-not-found.log missing\n"), .inconclusive)
    }
    func testTmuxConfNotFoundWarningIsInconclusive() {
        // tmux's own benign warning when .tmux.conf is missing; NOT a shell diagnostic
        XCTAssertEqual(classifyTmuxLaunch(output: "tmux.conf not found, using defaults\n"), .inconclusive)
    }
    func testDotTmuxConfNotFoundIsInconclusive() {
        // full path to missing config file; benign warning, not shell diagnostic
        XCTAssertEqual(classifyTmuxLaunch(output: "/home/u/.tmux.conf not found\n"), .inconclusive)
    }
    func testTmuxConfigNotFoundPhraseIsInconclusive() {
        // generic phrase about tmux config; not the shell diagnostic shape
        XCTAssertEqual(classifyTmuxLaunch(output: "tmux config not found\n"), .inconclusive)
    }
    func testEmptyOutputIsInconclusive() {
        XCTAssertEqual(classifyTmuxLaunch(output: ""), .inconclusive)
    }

    // --- BVA: the error line split across chunks, then accumulated by the App ---
    func testAccumulatedSplitErrorLineIsMissing() {
        // App concatenates the window; the unit sees the whole accumulation.
        let chunk1 = "bash: tmux: comm"
        let chunk2 = "and not found\n"
        XCTAssertEqual(classifyTmuxLaunch(output: chunk1 + chunk2), .tmuxMissing)
    }
    // A partial first chunk alone is not yet a diagnostic -> inconclusive (keep watching).
    func testPartialErrorChunkAloneIsInconclusive() {
        XCTAssertEqual(classifyTmuxLaunch(output: "bash: tmux: comm"), .inconclusive)
    }

    // --- precedence: missing present alongside noise still degrades ---
    func testMissingWinsOverPrompt() {
        XCTAssertEqual(classifyTmuxLaunch(output: "user@host:~$ tmux\nbash: tmux: command not found\n"), .tmuxMissing)
    }
}
